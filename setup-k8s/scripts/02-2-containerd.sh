#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

color_echo "Installing Containerd..."

# if command -v containerd >/dev/null 2>&1; then
#     color_echo "Containerd is already installed."
#     exit 0
# fi

cd /tmp/setup-k8s/pkgs/
containerd_ver=$(get_github_latest_release containerd/containerd)
# curl -SLO https://github.com/containerd/containerd/releases/download/$containerd_ver/containerd-${containerd_ver/v/}-linux-amd64.tar.gz
export containerd_ver=${containerd_ver/v/}

[ -s containerd-${containerd_ver}-linux-amd64.tar.gz ] || wget -c "${GHPROXY}https://github.com/containerd/containerd/releases/download/v${containerd_ver}/containerd-${containerd_ver}-linux-amd64.tar.gz"

# unzip the containerd
sudo tar -C /usr/local -xf containerd-${containerd_ver/v/}-linux-amd64.tar.gz

# systemd服务脚本
# https://github.com/containerd/containerd/blob/main/containerd.service
sudo mkdir -pv /usr/local/lib/systemd/system
[ -s containerd.service ] || sudo wget -c ${GHPROXY}https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

sudo cp containerd.service /usr/local/lib/systemd/system/containerd.service

# sudo apt install runc

runc_ver=$(get_github_latest_release opencontainers/runc)
[ -s runc.amd64 ] || wget -c ${GHPROXY}https://github.com/opencontainers/runc/releases/download/${runc_ver}/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

runc -v

# download cni
# https://github.com/containernetworking/plugins/releases
cni_ver=$(get_github_latest_release containernetworking/plugins)
[ -s cni-plugins-linux-amd64-${cni_ver}.tgz ] || wget -c ${GHPROXY}https://github.com/containernetworking/plugins/releases/download/${cni_ver}/cni-plugins-linux-amd64-${cni_ver}.tgz

sudo mkdir -p /opt/cni/bin  
sudo tar -xzf cni-plugins-linux-amd64-${cni_ver}.tgz -C /opt/cni/bin  

# create default config
[ -d /etc/containerd ] || sudo mkdir /etc/containerd
sudo /usr/local/bin/containerd config default | sudo tee /etc/containerd/config.toml > /dev/null 2>&1

# 国内
if [ "${REGION}X" = "CNX" ]; then
    sudo sed -i 's@registry.k8s.io@registry.cn-hangzhou.aliyuncs.com/google_containers@' /etc/containerd/config.toml
fi
# 内网
# sudo sed -i 's@registry.k8s.io/pause:[0-9.]*@harbor.tscop.net/google_containers/pause:latest@' /etc/containerd/config.toml
grep pause /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd.service
sudo systemctl restart containerd.service



############## containerd配置自己加速地址
grep -C1 /etc/containerd/certs.d /etc/containerd/config.toml

sudo mkdir -pv /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml << EOF
server = "https://registry-1.docker.io" # 默认的官方仓库地址
[host."http://10.10.10.1:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  skip_tls_verify = true
# 关键：最后回退到官方源，确保在加速器失效时仍能拉取镜像
[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
EOF

sudo systemctl restart containerd

/usr/local/bin/ctr images pull  docker.io/library/busybox:latest --hosts-dir /etc/containerd/certs.d
