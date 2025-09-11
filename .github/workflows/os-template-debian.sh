sudo sed -i 's|^deb http://ftp.debian.org|deb https://mirrors.ustc.edu.cn|g' /etc/apt/sources.list
sudo sed -i 's|^deb http://security.debian.org|deb https://mirrors.ustc.edu.cn/debian-security|g' /etc/apt/sources.list
# kvm agent
sudo apt update
sudo apt upgrade
sudo apt install -y vim wget telnet qemu-guest-agent
sudo apt clean
# 升级kernel 参考其他部分

# 修改 让本地hosts生效
sudo sed -i '/update_etc_hosts/s/^#*/#/' /etc/cloud/cloud.cfg
