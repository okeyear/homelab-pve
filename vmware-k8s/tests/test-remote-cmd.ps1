# vmware-k8s — 远端命令包装 + 地区补丁的离线测试
#
# 这两块是 2026-10-20 那次"kubeadm init 挂了 15 分钟"的直接产物:
#
#   1. Add-RemoteTimeout —— 远端命令套 timeout,让它不可能永远挂着。
#   2. guest/region-shim.sh —— 把仓库 functions.sh 的地区判断固定住,
#      免得它判错之后去用 registry.k8s.io(那个地址的 manifest 请求
#      会 307 跳到国内连不上的 europe-west3-docker.pkg.dev)。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-remote-cmd.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-remote-cmd.ps1 -Root <别的目录>

param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $TestDir }

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

. (Join-Path $Root 'lib\common.ps1')

# ================================================================ timeout
Write-Host '=== Add-RemoteTimeout:单程序 ==='
$r = Add-RemoteTimeout -Command 'echo hello' -TimeoutSec 30
Assert-True ($r -eq 'timeout -k 30 30 echo hello') "单程序直接加前缀(实际: $r)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:0 表示不套 ==='
$r = Add-RemoteTimeout -Command 'echo hello' -TimeoutSec 0
Assert-True ($r -eq 'echo hello') "TimeoutSec=0 时原样返回(实际: $r)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:开头的 VAR=VAL 赋值 ==='
$r = Add-RemoteTimeout -Command 'MASTER_NODES=10.10.10.201 VIP=10.10.10.250 bash /tmp/x.sh' -TimeoutSec 900
Assert-True ($r -match '^timeout -k 30 900 env ') "赋值形式走 env(实际: $r)"
Assert-True ($r -match 'env MASTER_NODES=10\.10\.10\.201 VIP=10\.10\.10\.250 bash /tmp/x\.sh$') `
    "赋值原样保留在 env 后面(实际: $r)"
# 关键:timeout 不能直接看到 VAR=VAL,否则它会把 "MASTER_NODES=..." 当程序名
Assert-True ($r -notmatch 'timeout -k 30 900 MASTER_NODES') "timeout 后面不能直接跟赋值(否则 timeout 会找不到程序)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:复合命令必须整体交给 bash -c ==='
$r = Add-RemoteTimeout -Command 'mkdir -p ~/.kube && sudo cat x > y' -TimeoutSec 60
Assert-True ($r -match "^timeout -k 30 60 bash -c '") "复合命令用 bash -c 包起来(实际: $r)"
Assert-True ($r -match "&& sudo cat x > y'$") "命令内容原样保留(实际: $r)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:带引号的单程序不用 bash -c ==='
# find -exec 是**一个**程序,引号是它自己的参数,直接加前缀就行
$r = Add-RemoteTimeout -Command "find /tmp -name '*.sh' -exec sed -i 's/x/y/' {} +" -TimeoutSec 60
Assert-True ($r -match '^timeout -k 30 60 find ') "单程序直接加前缀(实际: $r)"
Assert-True ($r -notmatch 'bash -c') "单程序不需要 bash -c(实际: $r)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:复合命令里的单引号要转义 ==='
$r = Add-RemoteTimeout -Command "cd /tmp/setup-k8s/scripts && grep -l 'x' *.sh" -TimeoutSec 60
# bash -c '...' 里的单引号必须写成 '\'' 才不会提前闭合
Assert-True ($r -match "bash -c '") "复合命令走 bash -c(实际: $r)"
Assert-True ($r -match "grep -l '\\''x'\\''") "命令内部的单引号按 POSIX 规矩转义成 '\''(实际: $r)"

Write-Host ''
Write-Host '=== Add-RemoteTimeout:管道也算复合 ==='
$r = Add-RemoteTimeout -Command 'lsmod | grep ip_vs' -TimeoutSec 60
Assert-True ($r -match "bash -c '") "带管道的命令走 bash -c(实际: $r)"

# ================================================================ 地区补丁
Write-Host ''
Write-Host '=== 地区补丁脚本 ==='
$shim = Join-Path $Root 'guest\region-shim.sh'
Assert-True (Test-Path -LiteralPath $shim) "补丁脚本存在: guest/region-shim.sh"
if (Test-Path -LiteralPath $shim) {
    $bytes = [System.IO.File]::ReadAllBytes($shim)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasCr = @($bytes | Where-Object { $_ -eq 13 }).Count
    $text = [System.IO.File]::ReadAllText($shim, [System.Text.Encoding]::UTF8)

    Assert-True (-not $hasBom) '补丁脚本没有 BOM(BOM 会挡住 bash 的第一行)'
    Assert-True ($hasCr -eq 0) '补丁脚本是 LF 换行'

    # 必须定义 curl 函数,并且只拦 ipinfo.io
    Assert-True ($text -match '(?m)^curl\(\)\s*\{') '定义了 curl 函数'
    Assert-True ($text -match '\*ipinfo\.io\*') '只拦 ipinfo.io'
    Assert-True ($text.Contains('command curl "$@"')) '其他调用用 command curl 原样放行'
    # 文件路径要和 Install-RegionShim 里写的对得上
    Assert-True ($text -match '/tmp/vmware-k8s/region\.txt') '地区从 /tmp/vmware-k8s/region.txt 读'
    # functions.sh 的 grep 要求 country 的值后面紧跟 `",`
    Assert-True ($text -match '\\"country\\": \\"\$r\\",') 'JSON 里 country 后面带逗号(跟 functions.sh 的 grep 对得上)'
}

# ================================================================ CNI 兜底
Write-Host ''
Write-Host '=== CNI 镜像源兜底的 sed 命令 ==='
. (Join-Path $Root 'lib\k8s.ps1')
$repair = New-CniRepairCommand -Manifest 'calico.yaml' `
    -From 'registry.cn-beijing.aliyuncs.com/my-dockermirrors/' -To 'quay.io/calico/'
Write-Host "  命令: $repair"
# sed 的 s 命令要三个分隔符:s@模式@替换@标志
$m = [regex]::Match($repair, "sed -i 's@(?<a>[^@]*)@(?<b>[^@]*)@(?<f>[^@]*)'")
Assert-True ($m.Success) 'sed 表达式是 s@模式@替换@标志 的形式(三个分隔符)'
Assert-True ($m.Groups['a'].Value -eq 'registry.cn-beijing.aliyuncs.com/my-dockermirrors/') `
    '模式是原来那个坏掉的地址'
Assert-True ($m.Groups['b'].Value -eq 'quay.io/calico/') '替换回官方源 quay.io'
Assert-True ($m.Groups['f'].Value -eq 'g') '标志位是 g'
Assert-True ($repair -match 'kubectl apply -f calico\.yaml') '改完重新 apply 一次'

# 否定测试:少写一个分隔符的老写法
$old = "sed -i 's@registry.cn-beijing.aliyuncs.com/my-dockermirrors/quay.io/calico/@g' calico.yaml"
Assert-True ($old -notmatch "s@[^@]*@[^@]*@[^@]*'") '老写法(少一个分隔符)确实不满足三分隔符'

# ================================================================ 编排接线
Write-Host ''
Write-Host '=== k8s 阶段的接线 ==='
$k8sText = [System.IO.File]::ReadAllText((Join-Path $Root 'lib\k8s.ps1'), [System.Text.Encoding]::UTF8)
$buildText = [System.IO.File]::ReadAllText((Join-Path $Root 'build.ps1'), [System.Text.Encoding]::UTF8)

Assert-True ($k8sText -match 'Install-RegionShim') 'k8s 阶段装了地区补丁'
Assert-True ($k8sText -match 'Resolve-Region') 'k8s 阶段先判定地区'
Assert-True ($k8sText -match 'Reset-K8sNode') 'k8s 阶段会重置节点(保证能重跑)'
Assert-True ($k8sText -match 'Invoke-RepoScript') '仓库脚本统一走 Invoke-RepoScript'
Assert-True ($k8sText -match 'BASH_ENV=') 'Invoke-RepoScript 注入 BASH_ENV'
Assert-True ($k8sText -match 'MASTER_NODES\s*=\s*\$masterList') 'kubeadm init 拿到了 MASTER_NODES'
Assert-True ($buildText -match "ShimFile.*region-shim\.sh") 'build.ps1 把补丁脚本路径传给了 k8s 阶段'

# 否定测试:仓库脚本不能被我们改过
Write-Host ''
Write-Host '=== 仓库脚本一个字都没改 ==='
$repoScripts = Join-Path (Split-Path -Parent $Root) 'setup-k8s\scripts'
foreach ($f in @('functions.sh', '04-kubeadm-init.sh', '08-2-cni-calico.sh')) {
    $p = Join-Path $repoScripts $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    Assert-True ($t -notmatch 'VMWARE_K8S_REGION|BASH_ENV') "$f 里没有我们的注入痕迹"
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
