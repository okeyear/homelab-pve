#!/bin/bash
# vmware-k8s 注入的 BASH_ENV —— 让仓库脚本的地区判断变得确定。
#
# setup-k8s/scripts/functions.sh 靠 detect_region() 判断自己在不在国内:
# 它一家一家问过去(ipinfo.io / ipwho.is / sysad.win / ip-api.com),
# 谁先答出合法的国家码就用谁。这已经比"只问 ipinfo.io"稳得多,
# 但仍然是**看运气**的 —— 四家全挂的时候 REGION 是空,脚本会走
# else 分支改用 registry.k8s.io 拉控制面镜像。
#
# 而 registry.k8s.io 的 manifest 请求会 307 跳到
# europe-west3-docker.pkg.dev —— 这个域名在国内是
# "connection refused",containerd 就会一直重试,
# kubeadm init 永远不返回;
# 节点则因为拿不到 /var/lib/kubelet/config.yaml 一直崩溃重启。
#
# 所以这里把 curl 拦一道:这四个探测地址都返回**固定**的地区
# (读 /tmp/vmware-k8s/region.txt,读不到就当 CN),别的调用原样放行。
# 宿主机那边会先真的问一次 guest,问出来的结果写进 region.txt ——
# 所以这里返回的不是编的,是刚才测出来的。
#
# 用法(宿主机侧注入,注意是**环境变量**不是 source):
#
#     env BASH_ENV=/tmp/vmware-k8s/region-shim.sh bash <仓库脚本>
#
# BASH_ENV 只对**非交互**的 bash 生效,而且是 bash 启动时读的,
# 所以必须通过环境变量传 —— 仓库脚本自己 source functions.sh,
# 我们没法在里面插一行。
#
# 返回格式要跟各家的原始格式一致,不然仓库的 grep 提取不出来:
#   ipinfo.io/country → 纯文本国家码
#   ipinfo.io         → JSON,键 "country"
#   ipwho.is          → JSON,键 "country_code"
#   sysad.win         → JSON,键 "iso_code"
#   ip-api.com        → JSON,键 "countryCode"

VMWARE_K8S_REGION_FILE=/tmp/vmware-k8s/region.txt

vmware_k8s_region() {
    local r
    r=$(cat "$VMWARE_K8S_REGION_FILE" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$r" ] || r=CN
    printf '%s' "$r"
}

curl() {
    local a r
    for a in "$@"; do
        case "$a" in
            *ipinfo.io/country*)
                printf '%s\n' "$(vmware_k8s_region)"
                return 0
                ;;
            *ipinfo.io*)
                printf '{"ip": "0.0.0.0", "country": "%s"}\n' "$(vmware_k8s_region)"
                return 0
                ;;
            *ipwho.is*)
                printf '{\n    "country_code": "%s"\n}\n' "$(vmware_k8s_region)"
                return 0
                ;;
            *sysad.win*)
                printf '{"country":{"iso_code":"%s"}}\n' "$(vmware_k8s_region)"
                return 0
                ;;
            *ip-api.com*)
                printf '{"countryCode":"%s"}\n' "$(vmware_k8s_region)"
                return 0
                ;;
        esac
    done
    command curl "$@"
}
