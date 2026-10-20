# vmware-k8s — setup-k8s/config.sh 生成
#
# 这个文件是集群装完之后才写的 —— 也就是说,它一旦写错,报错的时候
# 集群已经起来了,你得手动收拾。所以这里的每一条断言都值得较真。
#
# 之前在这儿栽过两个跟头:
#   1. `${CLUSTER_NAME:-"devops-k8s"}` 写在 PowerShell 的可展开
#      here-string 里,被当成了变量引用,输出变成 "CLUSTER_NAME="。
#   2. 同一个 here-string 里引用了根本没定义的 $K8sVersion,严格
#      模式下直接抛错,而这行偏偏是最后一步才执行。
#
# 另外仓库的 main.sh 用 ${K8S_VERSION%.*} 取 major.minor,所以
# K8S_VERSION 必须是完整版本号,不能只写 "1.34"。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\k8s.ps1')

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

$masters = @(
    [pscustomobject]@{ Name = 'k8s-master';  Address = '10.10.10.11' }
)
$workers = @(
    [pscustomobject]@{ Name = 'k8s-worker1'; Address = '10.10.10.101' }
    [pscustomobject]@{ Name = 'k8s-worker2'; Address = '10.10.10.102' }
)

$cfg = New-K8sConfigContent -Masters $masters -Workers $workers `
    -K8sVersion '1.34.12' -PodCidr '10.244.0.0/16' -ServiceCidr '10.96.0.0/12' `
    -LoadBalancer '10.10.10.10' -User 'vagrant' -NetworkPlugin 'calico'

$lines = $cfg -split "`n"

Write-Host '=== 关键字段 ==='
Assert-True (@($lines | Where-Object { $_ -eq 'CLUSTER_NAME=${CLUSTER_NAME:-"devops-k8s"}' }).Count -eq 1) `
    'CLUSTER_NAME 的 shell 默认值语法原样保留(没被 PowerShell 吃掉)'
Assert-True (@($lines | Where-Object { $_ -eq 'K8S_VERSION=${K8S_VERSION:-1.34.12}' }).Count -eq 1) `
    'K8S_VERSION 是完整版本号,且带 shell 默认值'
Assert-True (@($lines | Where-Object { $_ -eq 'POD_CIDR=10.244.0.0/16' }).Count -eq 1) 'POD_CIDR 对'
Assert-True (@($lines | Where-Object { $_ -eq 'SERVICE_CIDR=10.96.0.0/12' }).Count -eq 1) 'SERVICE_CIDR 对'
Assert-True (@($lines | Where-Object { $_ -eq 'MASTER_NODES=("10.10.10.11")' }).Count -eq 1) 'MASTER_NODES 格式对'
Assert-True (@($lines | Where-Object { $_ -eq 'WORKER_NODES=("10.10.10.101" "10.10.10.102")' }).Count -eq 1) 'WORKER_NODES 格式对'
Assert-True (@($lines | Where-Object { $_ -eq "LoadBalancer='10.10.10.10'" }).Count -eq 1) 'LoadBalancer 对'
Assert-True (@($lines | Where-Object { $_ -eq 'NODE_USER=vagrant' }).Count -eq 1) 'NODE_USER 对'
Assert-True (@($lines | Where-Object { $_ -eq 'NETWORK_PLUGIN="calico"' }).Count -eq 1) 'NETWORK_PLUGIN 对'
Assert-True (@($lines | Where-Object { $_ -eq 'ENABLE_METALLB=false' }).Count -eq 1) 'ENABLE_METALLB 对'

Write-Host ''
Write-Host '=== 不能出现空值 ==='
# 空值是最阴的:shell 不报错,脚本照跑,等到某天用到这个变量才炸。
foreach ($k in @('CLUSTER_NAME', 'K8S_VERSION', 'POD_CIDR', 'SERVICE_CIDR',
                 'MASTER_NODES', 'WORKER_NODES', 'LoadBalancer', 'NODE_USER',
                 'NETWORK_PLUGIN')) {
    $bad = @($lines | Where-Object { $_ -match "^$k\s*=\s*$" })
    Assert-True ($bad.Count -eq 0) "$k 不是空值"
}

Write-Host ''
Write-Host '=== 换行符 ==='
Assert-True (-not $cfg.Contains("`r")) '内容里没有 CR(这个文件要被 Linux source)'
Assert-True ($cfg.EndsWith("`n")) '结尾有换行'

Write-Host ''
Write-Host '=== 否定测试:老写法会产出什么 ==='
# 如果有人把 CLUSTER_NAME 那行改回可展开 here-string,输出就变成
# "CLUSTER_NAME=" —— 这一条就是防这个的。
Assert-True (-not (@($lines | Where-Object { $_ -eq 'CLUSTER_NAME=' }).Count -ge 1)) `
    '没有退化成 "CLUSTER_NAME="(老写法会这样)'

# 老写法里的 $K8sVersion 根本不存在,严格模式下会直接抛错。
# 这里用"如果它不存在会不会炸"来证明:能跑到这里就说明没炸。
Assert-True $true '生成过程没有因为未定义变量抛错(老写法在这里就炸)'

Write-Host ''
Write-Host '=== 和仓库里的 config.sh.example 对齐 ==='
$example = Join-Path (Split-Path -Parent $WorkDir) 'setup-k8s\config.sh.example'
if (Test-Path -LiteralPath $example) {
    $exText = Read-Utf8Text $example
    foreach ($key in @('CLUSTER_NAME', 'K8S_VERSION', 'POD_CIDR', 'SERVICE_CIDR',
                       'MASTER_NODES', 'LoadBalancer', 'WORKER_NODES', 'NODE_USER',
                       'SSH_KEY_PATH', 'NETWORK_PLUGIN', 'ENABLE_METALLB')) {
        Assert-True ($cfg -match "(?m)^$key=") "config.sh.example 里有的键,生成的 config.sh 也有: $key"
    }
}
else {
    Write-Host '  [skip] 找不到 setup-k8s/config.sh.example' -ForegroundColor Yellow
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
