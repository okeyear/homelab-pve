#!/bin/bash
# vmware-clone-prep.sh —— 克隆出来的机器第一次启动时跑一次。
#
# 背景:vmware-k8s 走的是"装好一张模板盘 -> vmrun full clone"。克隆
# 出来的是模板的完整副本,于是三台机器会带着同一份身份信息:
#
#   /etc/machine-id            k8s 用它当节点唯一标识。三台一样的话
#                              kubelet 会认为它们是同一台,集群起不来。
#   /etc/ssh/ssh_host_*        host key 一样的话,从宿主机 ssh 过去
#                              第二台就会报 REMOTE HOST IDENTIFICATION
#                              HAS CHANGED。
#   /var/lib/cloud/instance    cloud-init 会认为这机器已经初始化过了,
#                              不会再跑一遍。
#
# PVE 那边是用 --ciupgrade 1 达到同样效果的(克隆后重跑 cloud-init),
# VMware 没有对应的开关,所以自己在系统里埋一个开机服务。
#
# 怎么区分"模板自己"和"克隆出来的"?模板里留着标记文件
# /var/lib/vmware-template-sealed(packer 装的)。模板自己开机时
# 标记不在,什么都不做;克隆出来的机器带着标记,做一次重置然后把
# 标记删掉 —— 删掉之后这台机器以后每次开机都不会再重置。

set -uo pipefail

MARKER=/var/lib/vmware-template-sealed
LOG=/var/log/vmware-clone-prep.log

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

if [ ! -f "$MARKER" ]; then
    # 不是第一次克隆:已经重置过了,什么都不用做。
    exit 0
fi

log "检测到克隆标记,开始重置机器身份"
rm -f "$MARKER"

# --- 唯一 machine-id -----------------------------------------------------
# 删掉之后由 systemd-machine-id-setup 重新生成。顺序有讲究:
# 先停 dbus,再删 machine-id,否则 dbus 会把旧 id 又写回去。
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
log "machine-id = $(cat /etc/machine-id 2>/dev/null || echo '(读取失败)')"

# --- 唯一 SSH host key ---------------------------------------------------
# 删掉旧的,重新生成一套新的。不加 -A 的话 ssh-keygen 会因为文件还在
# 而拒绝覆盖,所以先删后生成。
rm -f /etc/ssh/ssh_host_*
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh.service 2>/dev/null || \
    systemctl restart sshd.service 2>/dev/null || true
fi
log "SSH host key 已重新生成"

# --- cloud-init 状态 -----------------------------------------------------
# 只清 instance-id,让 cloud-init 知道自己面对的是一台"新"机器。
# 不清整个 cloud 目录,免得它把已经装好的网卡配置也抹了。
rm -f /var/lib/cloud/instance/instance-id 2>/dev/null || true

# --- hostname ------------------------------------------------------------
# 模板叫 k8s-template,克隆出来要改掉,否则三台机器同名。
# 新名字由宿主机写进 .vmx 的 guestinfo,这里用 open-vm-tools 的
# rpctool 读回来。VMware 不会给 guest 传环境变量,guestinfo 是
# 唯一可靠的通道。
#
# 读不到就退回用本机 MAC 推导,宿主机那边用的是同一套规则,两边能对上。
new_host=""
if command -v vmware-rpctool >/dev/null 2>&1; then
    new_host=$(vmware-rpctool "info-get guestinfo.hostname" 2>/dev/null || true)
    new_host=$(printf '%s' "$new_host" | tr -d '\r\n')
fi
if [ -z "$new_host" ] && [ -n "${VMWARE_CLONE_HOSTNAME:-}" ]; then
    new_host="$VMWARE_CLONE_HOSTNAME"
fi

if [ -n "$new_host" ]; then
    echo "$new_host" >/etc/hostname
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$new_host" >/dev/null 2>&1 || true
    fi
    log "hostname = $new_host"
else
    # 兜底:MAC 末位 -> 主机名。
    mac=$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00' | head -1)
    if [ -n "$mac" ]; then
        # strtonum 是 GNU awk 的扩展,Ubuntu 默认的 mawk 没有。
        # 用 printf "%d" "0x.." 这个 POSIX 办法转换。
        last=$(printf '%s' "$mac" | awk -F: '{print $NF}' | xargs -I{} printf '%d' "0x{}")
        hn="k8s-node${last}"
        echo "$hn" >/etc/hostname
        command -v hostnamectl >/dev/null 2>&1 && \
            hostnamectl set-hostname "$hn" >/dev/null 2>&1 || true
        log "hostname(由 MAC 推导) = $hn"
    fi
fi

# --- 等待网络拿到地址 ---------------------------------------------------
# 宿主机那边是按"这个 IP 通了"来判定节点起来的,这里先把网络拉起来。
for _ in $(seq 1 60); do
    if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then
        break
    fi
    sleep 2
done

ip -4 addr show scope global 2>/dev/null | grep 'inet ' | sed 's/^/    /' >>"$LOG"

log "克隆首启自检完成"
exit 0
