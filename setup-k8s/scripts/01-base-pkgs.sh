#!/bin/bash
export PATH=/snap/bin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:~/.local/bin:$PATH
export LANG=en_US.UTF8

# install base packages

source /etc/os-release

deb_pkgs="chrony conntrack ipvsadm libseccomp2 apt-transport-https lsb-release ca-certificates gnupg curl wget vim git jq"
rpm_pkgs="chrony conntrack ipvsadm libseccomp curl wget vim git jq"

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


# 安装ipvs依赖包
# sudo yum install -y conntrack ipvsadm libseccomp
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
# nf_conntrack_ipv4
EOF
# 加载
for x in `cat /etc/modules-load.d/ipvs.conf`; do
    sudo modprobe $x
done

# if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
#     cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
# ip_vs
# ip_vs_rr
# ip_vs_wrr
# ip_vs_sh
# nf_conntrack_ipv4
# EOF
#     # 加载
#     for x in `cat /etc/modules-load.d/ipvs.conf`; do
#         sudo modprobe $x
#     done
# elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
#     sudo tee /etc/sysconfig/modules/ipvs.modules <<EOF
# modprobe -- ip_vs
# modprobe -- ip_vs_rr
# modprobe -- ip_vs_wrr
# modprobe -- ip_vs_sh
# modprobe -- nf_conntrack_ipv4
# EOF

#     sudo chmod +x /etc/sysconfig/modules/ipvs.modules
#     # 执行脚本
#     sudo /etc/sysconfig/modules/ipvs.modules

# else
#     echo "Unsupported OS: $ID"
#     exit 1
# fi


# 验证ipvs模块
lsmod | grep -e ip_vs -e nf_conntrack_ipv4