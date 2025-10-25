#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

# update kernel for rhel-based system OS 7
if [ -f /etc/redhat-release ] && [ "$(cat /etc/redhat-release | grep 'release 7')" != "" ]; then
    sudo yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
    sudo yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel
    sudo grub2-set-default 0
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    color_echo "Kernel updated, please reboot system to take effect."
else
    color_echo "Not RHEL-based OS 7, skip kernel update."
fi