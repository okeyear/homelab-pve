#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"

source ./scripts/functions.sh

# get config file
if [ -s "${SCRIPT_DIR}/config.sh" ]; then
    source "${SCRIPT_DIR}/config.sh"
fi

# download pkgs
[ -d pkgs ] || mkdir pkgs
cd pkgs
containerd_ver=$(get_github_latest_release containerd/containerd)
wget -c "${GHPROXY}https://github.com/containerd/containerd/releases/download/${containerd_ver}/containerd-${containerd_ver/v/}-linux-amd64.tar.gz"
wget -c ${GHPROXY}https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
runc_ver=$(get_github_latest_release opencontainers/runc)
wget -c ${GHPROXY}https://github.com/opencontainers/runc/releases/download/${runc_ver}/runc.amd64
cni_ver=$(get_github_latest_release containernetworking/plugins)
wget -c ${GHPROXY}https://github.com/containernetworking/plugins/releases/download/${cni_ver}/cni-plugins-linux-amd64-${cni_ver}.tgz
cd -


# install base packages, containerd, kubelet, kubeadm, kubectl on all nodes
color_echo "Setting up base packages on node"
bash scripts/01-base-pkgs.sh

color_echo "Setting up containerd on node"
bash scripts/02-2-containerd.sh

color_echo "Installing kubelet, kubectl, kubeadm on node"
bash scripts/03-kubelet.sh


# initialize the first master node
for NODE in "${MASTER_NODES[0]}"; do
    color_echo "kubeadm init on node: ${NODE}"
    MASTER_NODES=$(echo ${MASTER_NODES[@]} | sed 's!\s!,!g') VIP=${LoadBalancer} POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} bash scripts/04-kubeadm-init.sh
done


# todo: which cni plugin to use