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

[ -d ~/.kube ] ||  mkdir ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config

# ------------------------------------------------------------------
# 显式钉住 kube-proxy 的代理模式。
#
# kubeadm 不给 kube-proxy 写 mode(写出来是空的)。空值在 1.37 会被
# 判为即将过期并打告警,1.40 起默认值改成 nftables —— 也就是说
# **升级一次,数据面就悄悄换掉了**。这里写死 iptables,跟现在的实际
# 行为一致(实测 mode 留空时 kube-proxy 走的就是 iptables),升级不漂。
#
# 想换 nftables 就改下面这一行。
#
# IPVS 模式在 1.37 已弃用、1.43 会被彻底移除,这里永远不会选它;
# 系统层的 IPVS 残留(01-base-pkgs.sh)也已经清掉。
# ------------------------------------------------------------------
KUBE_PROXY_MODE=iptables

# admin.conf 是 root 权限 600,所以这三条都得带 sudo + 显式 kubeconfig
# (root 的 HOME 是 /root,那边没有 ~/.kube/config)。
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get cm kube-proxy -o yaml > /tmp/kube-proxy-cm.yaml
sudo sed -i "s/^\( *\)mode: \"\"$/\1mode: \"${KUBE_PROXY_MODE}\"/" /tmp/kube-proxy-cm.yaml
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f /tmp/kube-proxy-cm.yaml

# mode 只在启动时读一次,得重启 DaemonSet 才生效
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system rollout restart ds/kube-proxy
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system rollout status ds/kube-proxy --timeout=180s
