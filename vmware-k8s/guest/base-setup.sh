#!/bin/bash
# vmware-k8s — 把模板变成 k8s 基础镜像(base-setup.sh)
#
# 这个脚本在**克隆出来的** k8s-base 上跑,不在 packer 装系统的过程中跑。
#
# 分工:
#   packer 出的模板   —— 只装了个最小 Ubuntu,能 SSH 进来就完事
#   k8s-base(本脚本)  —— 换源、确认 cloud-init、装 clone-prep、
#                         配免密 sudo、打封存标记
#   三个 k8s 节点      —— 从 k8s-base 克隆,首启时 clone-prep 配 IP、
#                         重置 machine-id / SSH host key
#
# 基础包、containerd、k8s 组件由宿主机那边推 setup-k8s/scripts 过来跑
# (见 lib/base.ps1),仓库里那些脚本一个字都没改。
#
# 跑法:bash /tmp/vmware-k8s-guest/base-setup.sh <要免密的那个用户名>
set -euo pipefail

LOG=/var/log/vmware-base-setup.log
MIRROR=${VMWARE_APT_MIRROR:-https://mirrors.ustc.edu.cn/ubuntu}
GUEST_DIR=/tmp/vmware-k8s-guest
# 要配免密的那个用户。本脚本是**用 sudo 跑的**,所以 `id -un` 拿到的是
# root —— 给 root 配免密 sudo 等于什么都没配。用户名由宿主机传进来
# (第一个参数),拿不到就退回 vagrant(autoinstall 里建的那个)。
SUDO_USER_NAME=${1:-vagrant}

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

log "开始配置 k8s 基础镜像"

# ---------------------------------------------------------------- 1
# 换 apt 源
#
# Ubuntu 22.04 起用的是 deb822 格式(一个文件里若干个 stanza),
# 位置 /etc/apt/sources.list.d/ubuntu.sources。老式的 /etc/apt/sources.list
# 也可能还在,两个都换。
#
# 不整个重写文件,而是只把 URIs 那一行换掉 —— Suites / Components /
# Signed-By 这些字段各版本不一样,重写容易写错。
log "换 apt 源 -> $MIRROR"

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i -E "s|^(URIs:\s*)https?://[^ ]+|\1$MIRROR|g" \
        /etc/apt/sources.list.d/ubuntu.sources
    log "  已改 /etc/apt/sources.list.d/ubuntu.sources"
fi

if [ -f /etc/apt/sources.list ]; then
    # 分隔符用 **#**,不能用 | ——
    # 这个正则里有或运算 (archive|security|...),而 sed 只把**第一个**
    # 出现的分隔符当成结束标记,于是 pattern 在第一个 | 就被截断,
    # 后面的 |security|... 全被当成选项,报出来的是
    #   sed: -e expression #1, char 30: unknown option to `s'
    # 这种完全指不到真因的错。# 在 apt 源里不会出现(那是注释符)。
    sed -i -E "s#https?://(archive|security|us\.archive|[\w.-]*archive)\.ubuntu\.com/ubuntu#$MIRROR#g" \
        /etc/apt/sources.list
    log "  已改 /etc/apt/sources.list"
fi

apt-get update
log "apt-get update 完成"

# ---------------------------------------------------------------- 2
# 免密 sudo
#
# 为什么需要:宿主机那边跑 base 阶段是**非交互**的(ssh 跑一条命令,
# 没有 tty)。sudo 一旦要弹密码提示,直接就失败了 ——
# "sudo: a terminal is required to read the password"。
#
# 之前这步是靠 autoinstall 的 late-commands 做的,踩过两个坑:
# curtin 没有 curt-installer 这个子命令,而且 late-commands 失败
# **不重试、直接中止整场安装**。挪到这里之后,失败能看见、能重跑。
#
# 写完必须验一下语法 —— sudoers 写坏了的话 sudo 整个不可用,
# 后面每一步都会莫名其妙地失败。
log "配置免密 sudo (用户 $SUDO_USER_NAME)"
SUDOERS_FILE=/etc/sudoers.d/99-vagrant
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SUDO_USER_NAME" >"$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if ! visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    rm -f "$SUDOERS_FILE"
    log "  免密 sudo 写出来不合法,已经撤掉(visudo 校验没过)"
    exit 1
fi
log "  免密 sudo 已生效 ($SUDOERS_FILE)"

# ---------------------------------------------------------------- 3
# cloud-init
#
# autoinstall 装出来的系统本来就带 cloud-init(subiquity 自己就用它),
# 这里只做两件事:确认它在、确认它跑完了。
# 三台节点首启时靠它做"每台机器只初始化一次"的事。
log "确认 cloud-init"
if ! command -v cloud-init >/dev/null 2>&1; then
    log "  没装,补装"
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-init cloud-init-watcher
fi
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service \
    cloud-final.service 2>/dev/null || true
cloud-init status --long 2>/dev/null || log "  cloud-init 状态还没到 done(不碍事)"

# ---------------------------------------------------------------- 4
# open-vm-tools
#
# 克隆出来的机器靠它跟宿主机的 vmrun 通话(拿 IP、关机)。
# 模板里已经装了,这里补一道保险 —— 没有它,vmrun getGuestIPAddress
# 拿不到地址,base 阶段就没法等机器就绪。
log "确认 open-vm-tools"
if ! command -v vmware-rpctool >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y open-vm-tools
fi
systemctl enable --now open-vm-tools 2>/dev/null || true

# ---------------------------------------------------------------- 5
# 装 clone-prep
#
# 它是"克隆首启时重置机器身份"的开机服务:重置 machine-id 和
# SSH host key、按 MAC 写静态 IP、改主机名。
# 三台节点必须各自有唯一的 machine-id 和 host key,不然 k8s
# 集群根本起不来。
log "装 clone-prep"
# Windows 上 checkout 出来的 .sh 是 CRLF,直接 install 过去的话
# 每行末尾都多个 \r,脚本会莫名其妙地报 "command not found"。
if [ -f "$GUEST_DIR/clone-prep.sh" ]; then
    sed -i 's/\r$//' "$GUEST_DIR/clone-prep.sh"
    install -m 0755 "$GUEST_DIR/clone-prep.sh" /usr/local/sbin/vmware-clone-prep.sh
    install -m 0644 "$GUEST_DIR/clone-prep.service" /etc/systemd/system/vmware-clone-prep.service
    systemctl daemon-reload
    systemctl enable vmware-clone-prep.service
    log "  vmware-clone-prep.service 已 enable"
else
    log "  错误:$GUEST_DIR/clone-prep.sh 不存在,不能装 clone-prep"
    exit 1
fi

# ---------------------------------------------------------------- 6
# netplan:静态地址换成 DHCP
#
# 模板的 netplan(subiquity 写的 00-installer-config.yaml)里配的是
# **模板自己的固定地址**。三个节点是从本机克隆出来的,首启时如果
# 还带着那个地址,三台机器会抢同一个 IP —— 表现是宿主机 SSH 上去
# 的机器不对、或者干脆连不上。
#
# 所以这里把 netplan 换成"按接口名匹配 + DHCP":克隆体首启时各自
# 拿到一个唯一的地址,clone-prep 随后再写死各自的静态 IP。
#
# 只改磁盘上的文件,不动当前运行中的网络(当前这台 base 用的还是
# 模板给的固定地址,base 阶段全程不变,宿主机那边好找)。
log "改 netplan:静态地址 -> DHCP"
rm -f /etc/netplan/00-installer-config.yaml
cat >/etc/netplan/00-k8s-base.yaml <<'EOF'
# 由 vmware-k8s 的 base-setup.sh 生成。
#
# 模板里那个固定地址是给"模板自己"用的,不能带到克隆体上 ——
# 三台节点会抢同一个 IP。这里改成 DHCP,克隆体首启时各自拿一个
# 唯一地址,clone-prep 再写死各自的静态 IP。
network:
  version: 2
  ethernets:
    k8s0:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF
chmod 600 /etc/netplan/00-k8s-base.yaml
if command -v netplan >/dev/null 2>&1; then
    netplan generate >>"$LOG" 2>&1 || log "  netplan generate 报错(不影响当前运行中的网络)"
fi

# ---------------------------------------------------------------- 7
# 封存标记
#
# 打了这个标记,机器就知道"**我的克隆体**需要重置身份"。
# 三个节点是从本机克隆出来的,带着这个标记,首启时 clone-prep 会重置
# machine-id / SSH host key / 静态 IP,然后把标记删掉。
#
# base 机器**自己**也带这个标记 —— 它就是"源",标记是给克隆体看的。
# base 自己不会再开机(装完就关机、拿去做克隆源了),所以它自己
# 带不带标记无所谓。
MARKER=/var/lib/vmware-k8s-base
mkdir -p /var/lib
touch "$MARKER"
log "已打封存标记 $MARKER(克隆体首启时靠它判断要不要重置身份)"

# ---------------------------------------------------------------- 8
# 重置机器身份
#
# base 是从模板克隆出来的,带着模板的 machine-id。三个节点又是从
# base 克隆的,于是三台节点的 machine-id 会一模一样 —— kubelet 认为
# 它们是同一台,集群根本起不来。
#
# 这里给 base 自己生成一个全新的 machine-id;每个克隆体首启时
# clone-prep.sh 还会再各自生成一个,保证三台各不相同。
#
# 删之前要先停 dbus,否则 dbus 会把旧的 id 又写回去。
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop dbus.service 2>/dev/null || true
    systemctl stop systemd-machine-id-dbus.socket 2>/dev/null || true
fi
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
if command -v systemd-machine-id-setup >/dev/null 2>&1; then
    systemd-machine-id-setup >/dev/null 2>&1 || true
fi
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
log "base 自己的 machine-id = $(cat /etc/machine-id 2>/dev/null || echo '(读取失败)')"

# cloud-init 的 instance-id 也清掉,免得克隆体首启时 cloud-init
# 认为"这台机器我已经初始化过了",什么都不做。
rm -f /var/lib/cloud/instance/instance-id 2>/dev/null || true

log "k8s 基础镜像配置完成"
exit 0
