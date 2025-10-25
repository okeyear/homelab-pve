#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}"
source ./functions.sh

color_echo "kubeadm init master ..."

# master=$( ip r get 1.1.1.1 | awk '/src/{print $7}' )
# cd /etc/kubernetes/

# k8s_ver=${k8s_ver/v/} # v1.34.1 -> 1.34.1
# kubeadm config print init-defaults --component-configs KubeletConfiguration | sudo tee kubeadm.yml

# sudo sed -i "/kubernetesVersion:/ckubernetesVersion: ${k8s_ver}"  kubeadm.yml
# sudo sed -i 's@registry.k8s.io@registry.cn-hangzhou.aliyuncs.com/google_containers@'  kubeadm.yml
# sudo sed -i "/name:/s/node/$(hostname)/"  kubeadm.yml
# sudo sed -i "/advertiseAddress/s/:.*$/: $master/" kubeadm.yml

# # 多master时候,需要增加部分如下
# sudo sed -i "/bindPort/s/6443/8443/" kubeadm.yml
# sudo sed -i "/ClusterConfiguration/a controlPlaneEndpoint: \"$VIP:6443\"" kubeadm.yml
# sudo sed -i "/serviceSubnet/a\  podSubnet: 10.244.0.0\/16" kubeadm.yml

# # 拉取K8S必须的模块镜像
# # 列出所需要的镜像列表
# kubeadm config images list --config /etc/kubernetes/kubeadm.yml | sed 's/^/ctr image pull /g'
# # 拉取镜像到本地
# sudo kubeadm config images pull --v=5 --config /etc/kubernetes/kubeadm.yml

# # 给image打标签
# # 循环改标签
# for i in $(sudo /usr/local/bin/ctr -n k8s.io image ls | awk '/^registry/{print $1}')
# do
#     sudo /usr/local/bin/ctr -n k8s.io image tag $i $(echo $i | sed 's@registry.cn-hangzhou.aliyuncs.com/google_containers@registry.k8s.io@')
# done


# sudo kubeadm init --v=9 --config /etc/kubernetes/kubeadm.yml --control-plane-endpoint="$VIP" --upload-certs --ignore-preflight-errors=ImagePull
# # 注：如果中途出错可以用  kubeadm reset -f  来进行回退





# kube-vip 设置
# https://kube-vip.io/docs/installation/static/#generating-a-manifest
sudo mkdir -pv /etc/kubernetes/manifests/
export VIP=$VIP
export INTERFACE=$(ip r get 1.1.1.1 | awk '/src/{print $5}')
# export KVVERSION=$(get_github_latest_release 'kube-vip/kube-vip')
export KVVERSION="latest"

# alias kube-vip="sudo /usr/local/bin/ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION; sudo /usr/local/bin/ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip"
# alias kube-vip="sudo /usr/local/bin/ctr image pull dockerproxy.net/plndr/kube-vip:$KVVERSION; sudo /usr/local/bin/ctr run --rm --net-host dockerproxy.net/plndr/kube-vip:$KVVERSION vip /kube-vip"
# alias kube-vip="docker run --network host --rm ghcr.io/kube-vip/kube-vip:$KVVERSION"

color_echo "Generating kube-vip manifest daemonset ..."

sudo /usr/local/bin/ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
# sudo /usr/local/bin/ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest daemonset `# pod` \
#     --inCluster `# --interface $INTERFACE` \
#     --vip "${VIP}" \
#     --controlplane \
#     --services \
#     --arp \
#     --leaderElection `# sed 's@ghcr.io/kube-vip@plndr@g' ` | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

sudo /usr/local/bin/ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest pod \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --services \
    --arp \
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml



# --control-plane-endpoint="$VIP"

if [ "${REGION}X" = "CNX" ]; then
    color_echo "Using China image repository for kubeadm init ..."
    sudo kubeadm init \
      --node-name=$(hostname) \
      --image-repository registry.cn-hangzhou.aliyuncs.com/google_containers \
      --apiserver-advertise-address=$(ip r get 1.1.1.1 | awk '/src/{print $7}') \
      --service-cidr=$SERVICE_CIDR \
      --control-plane-endpoint=$VIP:6443 \
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
      --service-cidr=$SERVICE_CIDR \
      --control-plane-endpoint=$VIP:6443 \
      --pod-network-cidr=$POD_CIDR \
      --cri-socket=unix:///var/run/containerd/containerd.sock `# unix:///run/cri-dockerd.sock` \
      --v 9 \
      --upload-certs \
      --ignore-preflight-errors=all
fi



# # 更新 kubeadm-config
# sudo bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get  cm -n kube-system kubeadm-config -o yaml" > kubeadm-config.yaml
# sudo sed -i "s/controlPlaneEndpoint: .*/controlPlaneEndpoint: \"${VIP}:6443\"/" kubeadm-config.yaml
# sudo sed -i "/controlPlaneEndpoint: .*/a\    advertise-address: \"${VIP}\"" kubeadm-config.yaml
# sudo bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f kubeadm-config.yaml"

# # 更新 kube-apiserver
# sudo sed -i "s/--advertise-address=[0-9.]*/--advertise-address=${VIP}/" /etc/kubernetes/manifests/kube-apiserver.yaml

# # 更新 kube-proxy
# sudo bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get cm -n kube-system kube-proxy -o yaml" > kube-proxy.yaml
# sudo sed -i "s|server:.*|server: https://${VIP}:6443|" kube-proxy.yaml
# sudo bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f kube-proxy.yaml"

# # 重启组件
# sudo bash -c "KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete pod -n kube-system -l component=kube-apiserver"
# sleep 10

# # 更新 kubeconfig
# sudo mv /etc/kubernetes/admin.conf /etc/kubernetes/admin.conf.bak
# sudo kubeadm init phase kubeconfig admin --control-plane-endpoint "${VIP}:6443"
# # sudo cp /etc/kubernetes/admin.conf ~/.kube/config

