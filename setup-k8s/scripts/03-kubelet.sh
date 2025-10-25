#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

color_echo "Installing kubelet kubectl kubeadm..."

if command -v kubeadm >/dev/null 2>&1; then
    color_echo "kubeadm is already installed."
    exit 0
fi

if [ "${REGION}X" = "CNX" ]; then
    export K8S_MIRROR='https://mirrors.aliyun.com/kubernetes-new/core/stable'
else
    export K8S_MIRROR='https://pkgs.k8s.io/core:/stable:'
fi

# https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/


if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    sudo apt-get update && sudo apt-get install -y apt-transport-https
    [ -d /etc/apt/keyrings ] || sudo mkdir -p /etc/apt/keyrings
    [ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ] && sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL ${K8S_MIRROR}/${k8sver}/deb/Release.key |
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_MIRROR}/${k8sver}/deb/ /" |
        sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    sudo apt-get install -yq kubelet kubeadm kubectl
elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
    sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=${K8S_MIRROR}/${k8sver}/rpm/
enabled=1
gpgcheck=1
gpgkey=${K8S_MIRROR}/${k8sver}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    sudo yum install -yq --nogpgcheck kubelet kubeadm kubectl cri-tools kubernetes-cni --disableexcludes=kubernetes
else
    echo "Unsupported OS: $ID"
    exit 1
fi