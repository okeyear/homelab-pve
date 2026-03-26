# helm repo add cilium https://helm.cilium.io/
# helm repo update
# helm install cilium cilium/cilium --namespace kube-system

ChartVersion="1.19.2"
# https://github.com/cilium/charts
wget -c ${GHPROXY}https://github.com/cilium/charts/blob/master/cilium-${ChartVersion}.tgz


helm template cilium cilium-${ChartVersion}.tgz \
    --namespace kube-system \
    --set ingressController.enabled=true \
    --set ingressController.loadbalancerMode=dedicated \
    --set kubeProxyReplacement=true \
    --set l7Proxy=true \
    --set operator.replicas=1 \
    --set ipam.mode=kubernetes | \
    grep -oP '(?<=image: ").*?(?=@)' | sort -u 

# quay.io/cilium/cilium-envoy:v1.35.9-1773656288-7b052e66eb2cfc5ac130ce0a5be66202a10d83be
# quay.io/cilium/cilium:v1.19.2
# quay.io/cilium/operator-generic:v1.19.2
# 上面image同步到阿里云镜像

MIRRORS='registry.cn-beijing.aliyuncs.com/my-dockermirrors'
# https://docs.cilium.io/en/stable/helm-reference/
helm upgrade cilium cilium-${ChartVersion}.tgz \
    --install \
    --namespace kube-system \
    --reset-values \
    --set image.repository=${MIRRORS}/cilium \
    --set envoy.image.repository=${MIRRORS}/cilium-envoy \
    --set ingressController.enabled=true \
    --set ingressController.loadbalancerMode=dedicated \
    --set kubeProxyReplacement=true \
    --set l7Proxy=true \
    --set operator.replicas=1 \
    --set ipam.mode=kubernetes

# helm template cilium cilium-${ChartVersion}.tgz \
#     --namespace kube-system \
#     --set ingressController.enabled=true \
#     --set ingressController.loadbalancerMode=dedicated \
#     --set kubeProxyReplacement=true \
#     --set l7Proxy=true \
#     --set operator.replicas=1 \
#     --set ipam.mode=kubernetes | \
#     sed "s@quay.io/cilium@${MIRRORS}@g" | \
#     sed 's/@sha256:[a-f0-9]\{64\}//g' | kubectl apply -f -