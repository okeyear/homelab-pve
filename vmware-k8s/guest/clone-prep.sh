#!/bin/bash
# vmware-clone-prep.sh —— 克隆出来的机器第一次启动时跑一次。
#
# 背景:vmware-k8s 走的是"装好一张 base 盘 -> vmrun full clone"。克隆
# 出来的是源盘的完整副本,于是三台机器会带着同一份身份信息:
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
# 怎么区分"源"和"克隆出来的"?源(k8s-base)里留着标记文件
# /var/lib/vmware-k8s-base(base-setup.sh 打的)。克隆出来的机器带着
# 标记,做一次重置然后把标记删掉 —— 删掉之后这台机器以后每次开机
# 都不会再重置。
#
# 这一版还多干一件事:**按宿主机注入的信息配静态 IP**。
# 节点 IP 不靠宿主机的静态 DHCP 租约,而是这台机器自己写 netplan。
# 宿主机在 clone 的时候把 IP / 网关 / DNS 写进 .vmx 的 guestinfo,
# 这里读回来。
#
# 跑法:bash /usr/local/sbin/vmware-clone-prep.sh
set -uo pipefail

MARKER=/var/lib/vmware-k8s-base
LOG=/var/log/vmware-clone-prep.log
GUESTINFO="vmware-rpctool"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

if [ ! -f "$MARKER" ]; then
    # 不是第一次克隆:已经重置过了,什么都不用做。
    exit 0
fi

log "检测到克隆标记,开始重置机器身份"
rm -f "$MARKER"

# --- 从 guestinfo 读宿主机注入的信息 --------------------------------
# guestinfo 是 VMware 往 guest 里传值的唯一可靠通道(VMware 不会
# 传环境变量)。读不到就退回到"按 MAC 末位推 IP"的老办法。
guestinfo_get() {
    $GUESTINFO "info-get guestinfo.$1" 2>/dev/null | tr -d '\r\n'
}

new_ip=$(guestinfo_get ip)
new_host=$(guestinfo_get hostname)
new_gw=$(guestinfo_get gateway)
new_dns=$(guestinfo_get nameserver)

mac=$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00' | head -1)
mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')

# MAC 末位(十六进制)当十进制用,就是 IP 的末位:
#   00:50:56:0a:0a:c9 -> 0xc9 = 201 -> 10.10.10.201
# strtonum 是 GNU awk 的扩展,Ubuntu 默认的 mawk 没有。
# 用 printf "%d" "0x.." 这个 POSIX 办法转换。
mac_last=""
if [ -n "$mac" ]; then
    mac_last=$(printf '%s' "$mac" | awk -F: '{print $NF}' | xargs -I{} printf '%d' "0x{}")
fi

if [ -z "$new_ip" ] && [ -n "$mac_last" ]; then
    new_ip="10.10.10.$mac_last"
    log "guestinfo 里没有 ip,按 MAC 末位推导出 $new_ip"
fi
[ -z "$new_gw" ] && new_gw="10.10.10.2"
[ -z "$new_dns" ] && new_dns="$new_gw,223.5.5.5"

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
#
# 这一步必须在**静态 IP 生效之前**做完:宿主机那边是按"这个 IP 上的
# sshd 能用"来判定节点起来的。host key 要是等到节点已经能连上之后
# 才换,宿主机记住的旧 key 就和新的对不上,下次连接直接报
# REMOTE HOST IDENTIFICATION HAS CHANGED。
rm -f /etc/ssh/ssh_host_*
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A >/dev/null 2>&1 || true
fi
log "SSH host key 已重新生成"

# --- 静态 IP ---------------------------------------------------------
#
# 用 netplan 的 match:macaddress 来定位网卡 —— 不认接口名。
# 接口名在不同机器/不同内核上是 ens33 / ens160 / enp0s3 都有可能,
# 写死名字是最容易翻车的地方。
#
# base-setup.sh 留下的那个 DHCP 配置要**删掉**:两个 netplan 段
# 描述同一块网卡,netplan 合并的时候 match 会被并成
# {name: "en*", macaddress: "..."},多一个约束,少一分确定性。
if [ -n "$new_ip" ] && [ -n "$mac" ]; then
    log "配置静态 IP: $new_ip/$new_gw (MAC $mac)"
    mkdir -p /etc/netplan
    chmod 700 /etc/netplan
    rm -f /etc/netplan/00-installer-config.yaml /etc/netplan/00-k8s-base.yaml
    # 纯 shell 拼 YAML —— 最小化安装里不一定有 python3。
    {
        echo "# 由 vmware-clone-prep.sh 自动生成 —— 宿主机在 .vmx 的 guestinfo 里"
        echo "# 注入了 IP / 网关 / DNS,这里原样落地。"
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    k8s0:"
        echo "      match:"
        echo "        macaddress: \"$mac\""
        echo "      dhcp4: false"
        echo "      dhcp6: false"
        echo "      addresses:"
        echo "        - $new_ip/24"
        echo "      routes:"
        echo "        - to: default"
        echo "          via: $new_gw"
        echo "      nameservers:"
        echo "        addresses:"
        IFS=',' read -r -a dnslist <<<"$new_dns"
        for d in "${dnslist[@]}"; do
            [ -n "$d" ] && echo "          - $d"
        done
    } >/etc/netplan/99-k8s-node.yaml
    chmod 600 /etc/netplan/99-k8s-node.yaml
    if command -v netplan >/dev/null 2>&1; then
        if netplan generate >>"$LOG" 2>&1; then
            netplan apply >>"$LOG" 2>&1
            log "netplan apply 完成"
        else
            log "netplan generate 失败,静态 IP 没生效(见本日志)"
        fi
    else
        log "没有 netplan,跳过静态 IP"
    fi
    # 改完 IP,顺手把 DHCP 留下的租约清掉,免得 cloud-init 拿它当
    # "本机的地址"写进配置。
    rm -f /var/lib/dhcp/* 2>/dev/null || true
fi

# --- cloud-init 状态 -----------------------------------------------------
# 只清 instance-id,让 cloud-init 知道自己面对的是一台"新"机器。
# 不清整个 cloud 目录,免得它把已经装好的网卡配置也抹了。
rm -f /var/lib/cloud/instance/instance-id 2>/dev/null || true

# --- hostname ------------------------------------------------------------
# 名字由宿主机写进 .vmx 的 guestinfo。VMware 不会给 guest 传环境变量,
# guestinfo 是唯一可靠的通道。
if [ -z "$new_host" ] && [ -n "$mac_last" ]; then
    new_host="k8s-node${mac_last}"
fi
if [ -n "$new_host" ]; then
    echo "$new_host" >/etc/hostname
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$new_host" >/dev/null 2>&1 || true
    fi
    log "hostname = $new_host"
fi

# --- ssh 服务 ----------------------------------------------------------
# host key 换过了,sshd 得重起一次才用新的 key。
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh.service 2>/dev/null || \
    systemctl restart sshd.service 2>/dev/null || true
fi

# --- 等静态地址真的挂上来 ---------------------------------------------
# 宿主机那边是按"这个 IP 通了"来判定节点起来的,这里先把网络拉起来。
for _ in $(seq 1 60); do
    if ip -4 addr show scope global 2>/dev/null | grep -q "inet $new_ip"; then
        break
    fi
    sleep 2
done

ip -4 addr show scope global 2>/dev/null | grep 'inet ' | sed 's/^/    /' >>"$LOG"

log "克隆首启自检完成"
exit 0
