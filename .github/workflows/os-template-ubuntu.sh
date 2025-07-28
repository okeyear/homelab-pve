source /etc/os-release
# echo ${VERSION_CODENAME} ${UBUNTU_CODENAME}

sudo mv /etc/apt/sources.list{,.bak.init}

sudo tee /etc/apt/sources.list <<EOF
# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

# kvm agent
sudo apt update
sudo apt upgrade -y
sudo apt install -y vim wget telnet qemu-guest-agent
sudo apt clean
# 升级kernel 参考其他部分

# 修改 让本地hosts生效
sudo sed -i '/update_etc_hosts/s/^#*/#/' /etc/cloud/cloud.cfg

