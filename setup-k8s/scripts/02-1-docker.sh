#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

color_echo "Installing Docker..."

if [ "${REGION}X" = "CNX" ]; then
    # China download
    wget https://linuxmirrors.cn/docker.sh -O /tmp/docker.sh
    sudo bash /tmp/docker.sh \
    --source mirrors.aliyun.com/docker-ce/ \
    --source-registry mirror.ccs.tencentyun.com \
    --protocol http \
    --use-intranet-source false \
    --install-latest true \
    --close-firewall true \
    --ignore-backup-tips

    # sudo bash <(curl -sSL https://linuxmirrors.cn/docker.sh) \

else
    curl -fsSL https://get.docker.com | sudo bash -s docker
fi
sudo systemctl enable --now docker