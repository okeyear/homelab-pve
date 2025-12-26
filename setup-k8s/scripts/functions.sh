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

# first,  if Region in China or not
REGION=$(curl -s ipinfo.io| grep -oP '(?<=country": ").*?(?=",)')

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
