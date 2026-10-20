# vmware-k8s — IPVS 拆除后的回归护栏
#
# 背景:kube-proxy 的 IPVS 模式在 Kubernetes 1.37 被正式弃用
# (官方时间表:1.40 起 --mode 默认切 nftables,1.43 彻底移除)。
# 仓库的 setup-k8s/scripts/01-base-pkgs.sh 以前会装 ipvsadm、
# 预加载 ip_vs / ip_vs_rr / ip_vs_wrr / ip_vs_sh。
#
# 实测(2026-10,集群 v1.34.12):kube-proxy 的 ConfigMap 里 mode
# 字段是**空的**,kubeadm 的 ClusterConfiguration 里是 proxy: {} ——
# 空值被当成 iptables,所以这个集群从头到尾走的是 iptables,那些
# 内核模块和 ipvsadm **一点没用上**,纯死重。于是:
#   1. 01-base-pkgs.sh 里 IPVS 相关的部分全部拆掉;
#   2. 04-kubeadm-init.sh 里把代理模式显式钉成 iptables ——
#      空值在 1.37 会被判为即将过期并打告警,1.40 起默认切 nftables,
#      不钉死的话**升级一次数据面就悄悄换掉了**;
#   3. 编排层的就绪检查同步去掉 ipvsadm 这一项。
#
# 这个测试守住三件事:
#   1. IPVS 不要回到部署脚本(代码行里不许出现 ipvsadm / ip_vs)
#   2. kube-proxy 的代理模式必须被显式钉住,而且不能是 ipvs
#   3. 钉模式的那几条 kubectl 必须都带 --kubeconfig
#      (admin.conf 是 root 权限 600,而 root 的 HOME 是 /root,
#       那边没有 ~/.kube/config —— 漏了 kubectl 就去连
#       localhost:8080,报 "couldn't get current server API group
#       list"。这个坑实测踩过一次。)
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-ipvs-removal.ps1
#   ... -Root <另一棵树里的 vmware-k8s 目录>(否定测试扫副本时用)

param(
    # 要检查的 vmware-k8s 目录。默认是本文件所在目录的上一级。
    # setup-k8s/scripts 在它的**上一级**里找。
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $TestDir }
$RepoRoot = Split-Path -Parent $Root
$setupScripts = Join-Path $RepoRoot 'setup-k8s\scripts'

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

function Get-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

# 只看**代码行**:以 # 开头的是注释。注释里可以写"为什么拆掉 IPVS",
# 但代码里不许再出现 IPVS。
function Get-CodeLines {
    param([string]$Text)
    if ($null -eq $Text) { return @() }
    $out = @()
    foreach ($l in ($Text -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { continue }
        $out += $l
    }
    return $out
}

Write-Host "检查目录: $Root"
Write-Host "仓库脚本: $setupScripts"
Write-Host ''

# ---------------------------------------------------------------- 01-base-pkgs.sh
Write-Host '=== 01-base-pkgs.sh:IPVS 必须已经被拆掉 ==='
$basePkg = Get-Text (Join-Path $setupScripts '01-base-pkgs.sh')
Assert-True ($null -ne $basePkg) 'IPVS_BASE_PKGS_MISSING: 找不到 01-base-pkgs.sh'

$baseCode = Get-CodeLines $basePkg
$baseCodeText = ($baseCode -join "`n")

Assert-True (-not ($baseCodeText -match '(?i)ipvsadm')) `
    'IPVSADM_IN_BASE_PKGS: 01-base-pkgs.sh 的代码里不许再出现 ipvsadm'
Assert-True (-not ($baseCodeText -match '(?i)ip_vs')) `
    'IPVS_MODULE_IN_BASE_PKGS: 01-base-pkgs.sh 的代码里不许再加载 ip_vs 系列模块'
Assert-True (-not ($baseCodeText -match '(?i)nf_conntrack_ipv4')) `
    'IPVS_CONNTRACK_IN_BASE_PKGS: 01-base-pkgs.sh 的代码里不许再出现 nf_conntrack_ipv4'
Assert-True (-not ($baseCodeText -match '(?i)tee\s+/etc/modules-load\.d/ipvs\.conf')) `
    'IPVS_MODULES_FILE_IN_BASE_PKGS: 01-base-pkgs.sh 不许再写 /etc/modules-load.d/ipvs.conf'

# 反过来:该装的东西还得在(拆 IPVS 不能把基础包一起拆了)
Assert-True (($baseCodeText -match '(?i)chrony') -and ($baseCodeText -match '(?i)libseccomp')) `
    'BASE_PKGS_BROKEN: 01-base-pkgs.sh 里 chrony / libseccomp 还在不在'

# ---------------------------------------------------------------- 04-kubeadm-init.sh
Write-Host ''
Write-Host '=== 04-kubeadm-init.sh:kube-proxy 代理模式必须被钉死 ==='
$kubeadmInit = Get-Text (Join-Path $setupScripts '04-kubeadm-init.sh')
Assert-True ($null -ne $kubeadmInit) 'KUBEADM_INIT_MISSING: 找不到 04-kubeadm-init.sh'

$initCode = Get-CodeLines $kubeadmInit
$initCodeText = ($initCode -join "`n")

# 代理模式:必须有,而且不能是 ipvs
$modeMatch = [regex]::Match($initCodeText, '(?m)^KUBE_PROXY_MODE\s*=\s*"?([A-Za-z0-9_-]+)"?\s*$')
Assert-True ($modeMatch.Success) `
    'PROXY_MODE_NOT_PINNED: 04-kubeadm-init.sh 里没有 KUBE_PROXY_MODE=... 这一行'
$mode = ''
if ($modeMatch.Success) { $mode = $modeMatch.Groups[1].Value }
Assert-True ($mode -and ($mode -ne 'ipvs')) `
    'PROXY_MODE_IS_IPVS: kube-proxy 的代理模式不能是 ipvs(1.37 已弃用,1.43 会被移除)'
Assert-True (($mode -eq 'iptables') -or ($mode -eq 'nftables')) `
    'PROXY_MODE_UNKNOWN: 代理模式只能是 iptables / nftables'

# kubectl 每一条都得带 --kubeconfig(admin.conf 是 root 权限 600,
# root 的 HOME 是 /root,那边没有 ~/.kube/config)
$kubectlLines = @($initCode | Where-Object { $_ -match 'kubectl' })
Assert-True ($kubectlLines.Count -gt 0) `
    'PROXY_MODE_NOT_APPLIED: 04-kubeadm-init.sh 里一条 kubectl 都没有'
$badKubectl = @($kubectlLines | Where-Object { $_ -notmatch '--kubeconfig' })
Assert-True ($badKubectl.Count -eq 0) `
    'KUBECTL_WITHOUT_KUBECONFIG: 每条 kubectl 都必须带 --kubeconfig(否则会去连 localhost:8080)'

# 改完 ConfigMap 得重启 DaemonSet,mode 只在启动时读一次
Assert-True (($initCodeText -match 'rollout\s+restart\s+ds/kube-proxy')) `
    'PROXY_MODE_NOT_RESTARTED: 改完 mode 必须 rollout restart ds/kube-proxy'
Assert-True (($initCodeText -match 'get\s+cm\s+kube-proxy')) `
    'PROXY_MODE_NOT_APPLIED: 没有把 kube-proxy 的 ConfigMap 拉出来改'
Assert-True (-not ($initCodeText -match '(?i)ipvs')) `
    'IPVS_IN_KUBEADM_INIT: 04-kubeadm-init.sh 的代码里不许出现 ipvs'

# init 本身没被改坏
Assert-True (($initCodeText -match 'kubeadm\s+init')) `
    'KUBEADM_INIT_BROKEN: 04-kubeadm-init.sh 里 kubeadm init 还在不在'

# ---------------------------------------------------------------- 编排层
Write-Host ''
Write-Host '=== 编排层:不许再要求 ipvsadm ==='
$k8sLib = Get-Text (Join-Path $Root 'lib\k8s.ps1')
Assert-True ($null -ne $k8sLib) 'K8S_LIB_MISSING: 找不到 lib\k8s.ps1'
Assert-True (-not ($k8sLib -match '(?i)command -v ipvsadm')) `
    'IPVSADM_REQUIRED_BY_ORCHESTRATOR: lib\k8s.ps1 的就绪检查里不许再要求 ipvsadm'

$baseLib = Get-Text (Join-Path $Root 'lib\base.ps1')
Assert-True ($null -ne $baseLib) 'BASE_LIB_MISSING: 找不到 lib\base.ps1'
Assert-True (-not ($baseLib -match '(?i)ipvsadm')) `
    'IPVSADM_REQUIRED_BY_ORCHESTRATOR: lib\base.ps1 里不许再提 ipvsadm'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
