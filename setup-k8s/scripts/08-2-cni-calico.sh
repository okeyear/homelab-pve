function get_github_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
    grep '"tag_name":' |                                            # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/'                                    # Pluck JSON value
}
calico_ver=$(get_github_latest_release "projectcalico/calico")
# calico_ver='v3.26.4'
######################
# https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
curl -O https://raw.githubusercontent.com/projectcalico/calico/${calico_ver}/manifests/calico.yaml

#  wget https://docs.projectcalico.org/manifests/calico.yaml

# 手工搜索修改这两行 sed -i 's@192.168.0.0/16@10.244.0.0/16@' calico.yaml
# grep -C 1 CALICO_IPV4POOL_CIDR calico.yaml
#            # no effect. This should fall within `--cluster-cidr`.
#            - name: CALICO_IPV4POOL_CIDR
#              value: "10.244.0.0/16"

sed -i.bak '/# \- name: CALICO_IPV4POOL_CIDR/a\            - name: CALICO_IPV4POOL_CIDR\n              value: "10.244.0.0/16"' calico.yaml

sed -i 's@image: quay.io/calico/@image: registry.cn-beijing.aliyuncs.com/my-dockermirrors/@g'  calico.yaml

# sed -i 's@docker.io@harbor.tscop.net/dockerhub@g' calico.${calico_ver}.yaml
kubectl apply -f calico.yaml

