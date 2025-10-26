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
for NODE in "${MASTER_NODES[@]}" "${WORKER_NODES[@]}"; do

    rsync --no-perms --rsync-path="sudo rsync" -e  'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' -avz --partial --progress --inplace ../setup-k8s "${NODE_USER}@${NODE}:/tmp/"

    color_echo "Setting up base packages on node: ${NODE}"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" 'bash /tmp/setup-k8s/scripts/01-base-pkgs.sh'

    # color_echo "Installing containerd on node: ${NODE}"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" 'bash /tmp/setup-k8s/scripts/02-2-containerd.sh'

    color_echo "Installing kubelet, kubectl, kubeadm on node: ${NODE}"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" "k8sver=v${K8S_VERSION%.*} bash /tmp/setup-k8s/scripts/03-kubelet.sh"

done

# initialize the first master node
for NODE in "${MASTER_NODES[0]}"; do
    color_echo "kubeadm init on node: ${NODE}"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" "MASTER_NODES=$(echo ${MASTER_NODES[@]} | sed 's!\s!,!g') VIP=${LoadBalancer} POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} bash /tmp/setup-k8s/scripts/04-kubeadm-init.sh"
    # ssh "${NODE_USER}@${NODE}" "POD_CIDR=${POD_CIDR} SERVICE_CIDR=${SERVICE_CIDR} VIP=${LoadBalancer} bash /tmp/setup-k8s/scripts/05-k8s-master.sh"
    sleep 5
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" "sudo kubeadm token create --print-join-command" | tee ./scripts/07-k8s-worker.sh
done

# worker join and additional master join
for NODE in "${WORKER_NODES[@]}"; do
    color_echo "Joining node to cluster: ${NODE}"
    rsync --no-perms --rsync-path="sudo rsync" -e  'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' -avz --partial --progress --inplace ./scripts "${NODE_USER}@${NODE}:/tmp/setup-k8s/"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  "${NODE_USER}@${NODE}" "sudo bash /tmp/setup-k8s/scripts/07-k8s-worker.sh"
done