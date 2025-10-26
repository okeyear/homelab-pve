#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

color_echo "kubeadm init ..."

# 
echo "$MASTER_NODES,127.0.0.1,$VIP,api.k8s.local,k8s-api.internal"

if [ "${REGION}X" = "CNX" ]; then
    color_echo "Using China image repository for kubeadm init ..."
    cat <<EOF    
    sudo kubeadm init \
      --node-name=$(hostname) \
      --image-repository registry.cn-hangzhou.aliyuncs.com/google_containers \
      --apiserver-advertise-address=$(ip r get 1.1.1.1 | awk '/src/{print $7}') \
      --apiserver-cert-extra-sans "$MASTER_NODES,127.0.0.1,$VIP,api.k8s.local,k8s-api.internal" \
      --service-cidr=$SERVICE_CIDR \
      --pod-network-cidr=$POD_CIDR \
      --cri-socket=unix:///var/run/containerd/containerd.sock `# unix:///run/cri-dockerd.sock` \
      --v 9 \
      --upload-certs \
      --ignore-preflight-errors=all
EOF
    sudo kubeadm init \
      --node-name=$(hostname) \
      --image-repository registry.cn-hangzhou.aliyuncs.com/google_containers \
      --apiserver-advertise-address=$(ip r get 1.1.1.1 | awk '/src/{print $7}') \
      --apiserver-cert-extra-sans "$MASTER_NODES,127.0.0.1,$VIP,api.k8s.local,k8s-api.internal" \
      --service-cidr=$SERVICE_CIDR \
      --pod-network-cidr=$POD_CIDR \
      --cri-socket=unix:///var/run/containerd/containerd.sock `# unix:///run/cri-dockerd.sock` \
      --v 9 \
      --upload-certs \
      --ignore-preflight-errors=all      
else
    color_echo "Using default image repository for kubeadm init ..."
    sudo kubeadm init \
      --node-name=$(hostname) \
      --image-repository registry.k8s.io \
      --apiserver-advertise-address=$(ip r get 1.1.1.1 | awk '/src/{print $7}') \
      --apiserver-cert-extra-sans "$MASTER_NODES,127.0.0.1,$VIP,api.k8s.local,k8s-api.internal" \
      --service-cidr=$SERVICE_CIDR \
      --pod-network-cidr=$POD_CIDR \
      --cri-socket=unix:///var/run/containerd/containerd.sock `# unix:///run/cri-dockerd.sock` \
      --v 9 \
      --upload-certs \
      --ignore-preflight-errors=all
fi

# verify the apiserver certificate SANs
echo | openssl s_client -connect ${MASTER_NODES[0]}:6443 -servername kubernetes 2>/dev/null | \
openssl x509 -noout -text | \
grep -A1 'Subject Alternative Name'