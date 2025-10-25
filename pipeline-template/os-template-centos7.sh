sudo sed -i '/^PasswordAuth/s/no/yes/' /etc/ssh/sshd_config
sudo service sshd restart

sudo systemctl disable --now firewalld
sudo sed -i 's|SELINUX=enforcing|SELINUX=disabled|' /etc/selinux/config
# sudo curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo

minorver=7.9.2009
sudo sed -e "s|^mirrorlist=|#mirrorlist=|g" \
    -e "s|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=https://mirrors.aliyun.com/centos-vault/$minorver|g" \
    -e "s|^#baseurl=http://mirror.centos.org/\$contentdir/\$releasever|baseurl=https://mirrors.aliyun.com/centos-vault/$minorver|g" \
    -i.bak \
    /etc/yum.repos.d/CentOS-*.repo

# kvm agent
sudo yum -y install vim wget telnet qemu-guest-agent
# 升级kernel 参考其他部分

# 修改 让本地hosts生效
sudo sed -i '/update_etc_hosts/s/^#*/#/' /etc/cloud/cloud.cfg
# 开启sshd的密码验证
sudo sed -i '/ssh_pwauth/s/false/true/' /etc/cloud/cloud.cfg

sudo yum update -y
# sudo yum clean all 
