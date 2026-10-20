#!/bin/bash
# vmware-k8s 注入的 BASH_ENV —— 让仓库脚本的地区判断变得确定。
#
# setup-k8s/scripts/functions.sh 是这么判断自己在不在国内的:
#
#     REGION=$(curl -s ipinfo.io | grep -oP '(?<=country": ").*?(?=",)')
#
# 这个判断有三个致命问题:
#
#   1. ipinfo.io 对匿名请求会限流,返回的内容里没有 country 字段,
#      grep 匹配不到 -> REGION 是空 -> 走 else 分支。
#   2. curl 没有 --connect-timeout,ipinfo.io 要是卡住,整个脚本
#      就挂在那儿不动了。
#   3. 走 else 分支的代价极大:脚本改用 registry.k8s.io 拉控制面镜像。
#      而 registry.k8s.io 的 manifest 请求会 307 跳到
#      europe-west3-docker.pkg.dev —— 这个域名在国内是
#      "connection refused",containerd 就会一直重试,
#      kubeadm init 永远不返回;
#      节点则因为拿不到 /var/lib/kubelet/config.yaml 一直崩溃重启。
#
# 所以这里把 curl 拦一道:只有 ipinfo.io 返回固定的地区(读
# /tmp/vmware-k8s/region.txt,读不到就当 CN),别的调用原样放行。
#
# 用法(宿主机侧注入,注意是**环境变量**不是 source):
#
#     env BASH_ENV=/tmp/vmware-k8s/region-shim.sh bash <仓库脚本>
#
# BASH_ENV 只对**非交互**的 bash 生效,而且是 bash 启动时读的,
# 所以必须通过环境变量传 —— 仓库脚本自己 source functions.sh,
# 我们没法在里面插一行。
#
# 另外注意 JSON 的格式:functions.sh 的 grep 要求 country 的值
# 后面紧跟 `",`(带逗号),所以这里多留了一个字段。

VMWARE_K8S_REGION_FILE=/tmp/vmware-k8s/region.txt

curl() {
    local a r
    for a in "$@"; do
        case "$a" in
            *ipinfo.io*)
                r=$(cat "$VMWARE_K8S_REGION_FILE" 2>/dev/null | tr -d ' \t\r\n')
                [ -n "$r" ] || r=CN
                printf '%s\n' "{\"ip\": \"0.0.0.0\", \"country\": \"$r\", \"city\": \"unknown\", \"org\": \"vmware-k8s\"}"
                return 0
                ;;
        esac
    done
    command curl "$@"
}
