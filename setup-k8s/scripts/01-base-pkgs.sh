#!/bin/bash
export PATH=/snap/bin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:~/.local/bin:$PATH
export LANG=en_US.UTF8

# install base packages

source /etc/os-release

deb_pkgs="chrony conntrack libseccomp2 apt-transport-https lsb-release ca-certificates gnupg curl wget vim git jq"
rpm_pkgs="chrony conntrack libseccomp curl wget vim git jq"

if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    sudo apt-get update
    sudo apt-get install -yq $deb_pkgs
elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
    sudo yum install -yq $rpm_pkgs
    # 关闭防火墙并设置为开机自动关闭
    sudo systemctl disable --now firewalld

    # 关闭SELinux
    sudo sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
    # 临时关闭SELinux
    sudo setenforce 0
else
    echo "Unsupported OS: $ID"
    exit 1
fi



sudo sed -ri 's/^pool.*/#&/' /etc/chrony.conf
sudo tee /etc/chrony.conf << EOF
pool ntp1.aliyun.com iburst
EOF
sudo systemctl restart chronyd
sudo chronyc sources
# 修改时区，如果之前是这个时区就不用修改
sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
sudo bash -c 'echo "Asia/Shanghai" > /etc/timezone'

# 关闭当前交换分区
sudo swapoff -a
# 禁止开机自动启动交换分区
sudo sed -ri 's/.*swap.*/#&/' /etc/fstab

# 加载内核模块
cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# 加载
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# 加载生效
sudo sysctl -p /etc/sysctl.d/kubernetes.conf
sudo sysctl --system

lsmod | grep br_netfilter # 查看是否加载完成


# ------------------------------------------------------------------
# IPVS 相关的部分已经全部移除。
#
# 原因:kube-proxy 的 IPVS 模式在 Kubernetes 1.37 被正式弃用
# (官方时间表:1.40 起 --mode 默认切 nftables,1.43 彻底移除 IPVS
# 模式)。这条路线要退出,系统层就没必要再预装 ipvsadm,也没必要
# 再预加载 ip_vs / ip_vs_rr / ip_vs_wrr / ip_vs_sh。
#
# 注意:kube-proxy 用哪种代理模式是 **kubeadm 定的**(默认 iptables),
# 跟这里装不装内核模块是两码事 —— 不装 ip_vs 不影响集群正常跑。
# 代理模式在 04-kubeadm-init.sh 里被显式钉成了 iptables。
# ------------------------------------------------------------------

# 老版本(本脚本早期版本)装过的 IPVS 残留顺手清掉,免得重启之后
# 内核又把 ip_vs 加载上来。
sudo rm -f /etc/modules-load.d/ipvs.conf
