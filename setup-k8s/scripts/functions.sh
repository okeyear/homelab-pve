#!/bin/bash
export DEBIAN_FRONTEND=noninteractive


export PATH=/snap/bin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:~/.local/bin:$PATH
export LANG=en_US.UTF8

[ -f /etc/os-release ] && source /etc/os-release
alias ssh='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
color_echo() {
    # 定义颜色代码数组（文字色30-37，背景色40-47）
    local text_colors=(31 32 33 34 35 36 37)  # 排除黑色30
    local bg_colors=(40 41 42 43 44 45 46 47) # 包含黑色40
    
    # 随机选择文字颜色
    local text_idx=$((RANDOM % ${#text_colors[@]}))
    local text_color=${text_colors[$text_idx]}
    
    # 确保背景色与文字色不同
    local bg_color
    while :; do
        bg_color=${bg_colors[$((RANDOM % ${#bg_colors[@]}))]}
        [ "$bg_color" != "$((text_color + 10))" ] && break
    done
    
    # 输出带颜色的文本
    echo -e "\e[${text_color};${bg_color}m$1\e[0m"
}

function get_github_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
        grep '"tag_name":' |                                          # Get tag line
        sed -E 's/.*"([^"]+)".*/\1/'                                  # Pluck JSON value
}

# ---------------------------------------------------------------- 地区判断
#
# 只问 ipinfo.io 一家是不够的:它对匿名请求会限流,拿不到 country 字段
# 时 REGION 就是空,脚本会走 else 分支改用 registry.k8s.io 拉控制面镜像。
#
# 而 registry.k8s.io 的 manifest 请求会 307 跳到
# europe-west3-docker.pkg.dev —— 这个域名在国内是 connection refused,
# containerd 会一直重试,kubeadm init 永远不返回,节点则因为拿不到
# /var/lib/kubelet/config.yaml 一直崩溃重启。
#
# 所以一家问不到就换下一家,最多问三轮。
#
# 各家实测(国内出口):
#   https://ipinfo.io/country  → 200,纯文本国家码("CN")
#   https://ipwho.is/           → 200,**缩进** JSON,键是 "country_code": "CN"
#                                (冒号后有空格,grep 要容忍空格)
#   http://sysad.win            → 200,紧凑 JSON("iso_code":"CN")
#                                https 版证书主机名对不上,只能用 http
#   http://ip-api.com/json      → 200,紧凑 JSON("countryCode":"CN")
#                                https 版免费端点返回 403,只能用 http
#
# curl_probe:带超时和重试的 curl,拿不到内容就返回非 0。
curl_probe() {
    local url="$1"
    local timeout="${2:-8}"
    local attempt out
    for attempt in 1 2; do
        out=$(curl -sS --max-time "$timeout" --connect-timeout "$timeout" "$url" 2>/dev/null)
        if [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
    done
    return 1
}

detect_region() {
    local region
    local attempt

    for attempt in 1 2 3; do

        region=$(curl_probe 'https://ipinfo.io/country' | tr -d '[:space:]')
        [[ "$region" =~ ^[A-Z]{2}$ ]] && { echo "$region"; return 0; }

        region=$(curl_probe 'https://ipwho.is/' | grep -oE '"country_code":[[:space:]]*"[A-Z]+"' | head -n1 | cut -d'"' -f4)
        [[ "$region" =~ ^[A-Z]{2}$ ]] && { echo "$region"; return 0; }

        region=$(curl_probe 'http://sysad.win' | grep -oE '"iso_code":"[A-Z]+"' | head -n1 | cut -d'"' -f4)
        [[ "$region" =~ ^[A-Z]{2}$ ]] && { echo "$region"; return 0; }

        region=$(curl_probe 'http://ip-api.com/json' | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d'"' -f4)
        [[ "$region" =~ ^[A-Z]{2}$ ]] && { echo "$region"; return 0; }

    done

    return 1
}

# first,  if Region in China or not
# REGION=$(curl -s ipinfo.io| grep -oP '(?<=country": ").*?(?=",)')
# REGION=$(curl -s "http://ipwho.is/"| jq -r '.country_code')
# REGION=$(curl -s "http://sysad.win"| jq -r '.country.iso_code')
# REGION=$(curl -s "http://sysad.win"| grep -oP '(?<=iso_code":")[a-zA-Z.]*?(?=")')
# REGION=$(curl -s "http://ipwho.is/"| jq -r '.country_code')
REGION=$(detect_region)
# 四个源都问不到,就退到"看镜像源通不通" ——
# 地区判错的后果是 kubeadm init 拉不到镜像一直挂着,宁可慢也不能挂。
if [ -z "$REGION" ]; then
    if curl_probe 'https://registry.cn-hangzhou.aliyuncs.com/v2/' >/dev/null 2>&1; then
        REGION=CN
    fi
fi

if [ "${REGION}X" = "CNX" ]; then
    color_echo "Your IP is in China $REGION, will using China resource."
    export GHPROXY="${GHPROXY:-https://ghfast.top/}"
    # 备注: 地址可以用咱们的或者从https://ghproxy.link/找一个
    # 备注: 地址可以用咱们的或者从https://dockerproxy.link/找一个
    export BINPROXY='files.m.daocloud.io/'
    # export PIP_ARGS='-i https://mirrors.aliyun.com/pypi/simple'
    export PIP_ARGS='-i http://mirrors.tencentyun.com/pypi/simple --trusted-host mirrors.tencentyun.com'
else
    color_echo "Your IP is in $REGION (not in China), will using global resource directly." 
    export GHPROXY=''
    # 备注: 地址可以用咱们的或者从https://ghproxy.link/找一个
    # 备注: 地址可以用咱们的或者从https://dockerproxy.link/找一个
    export BINPROXY=''       
fi
