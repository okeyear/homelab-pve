# vmware-k8s — 静态 DHCP 租约写入器的离线测试
#
# 这个函数会改宿主机上 VMware 的全局配置,写坏了三台机器都上不了网。
# 所以先在副本上测,并且要证明:
#   1. 租约确实写进去了
#   2. 文件里原有的内容(别的网段、VMware 自己的 host 块、地址池)一个都没丢
#   3. 重复执行是幂等的 —— 不会攒出一堆重复条目
#
# 上一版这里用正则锚点 + 捕获组下标去切文件,结果把 subnet 段的正文
# (range / option ...)整个弄丢了。现在改成按大括号配对数行数,
# 这个测试就是防它再犯的。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\vmnet.ps1')

$failed = 0
$total = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

$real = 'C:\ProgramData\VMware\vmnetdhcp.conf'
if (-not (Test-Path -LiteralPath $real)) {
    Write-Host "[skip] 这台机器上没有 $real" -ForegroundColor Yellow
    exit 0
}

$copy = Join-Path $TestDir 'vmnetdhcp.conf.copy'
Copy-Item -LiteralPath $real -Destination $copy -Force
$script:VmDhcpConf = $copy

$before = Get-Content -LiteralPath $copy -Raw
$beforeLines = ($before -split "`r?`n").Count

$leases = @(
    [pscustomobject]@{ Name = 'k8s-master';  Mac = '00:50:56:0A:0A:0B'; Address = '10.10.10.11' },
    [pscustomobject]@{ Name = 'k8s-worker1'; Mac = '00:50:56:0A:0A:65'; Address = '10.10.10.101' },
    [pscustomobject]@{ Name = 'k8s-worker2'; Mac = '00:50:56:0A:0A:66'; Address = '10.10.10.102' }
)

Write-Host ''
Write-Host '=== 第一次写入 ==='
Set-StaticDhcpLease -Subnet '10.10.10.0' -Netmask '255.255.255.0' -Lease $leases
$after1 = Get-Content -LiteralPath $copy -Raw

Write-Host ''
Write-Host '=== 断言 ==='
Assert-True ($after1 -match 'host k8s-master \{')                  '写进了 k8s-master 块'
Assert-True ($after1 -match 'hardware ethernet 00:50:56:0A:0A:0B;') '写进了 master 的 MAC'
Assert-True ($after1 -match 'fixed-address 10\.10\.10\.11;')         '写进了 master 的地址'
Assert-True ($after1 -match 'fixed-address 10\.10\.10\.101;')        '写进了 worker1 的地址'
Assert-True ($after1 -match 'fixed-address 10\.10\.10\.102;')        '写进了 worker2 的地址'

# 原有内容必须完好 —— 这几条是被上一个版本弄坏过的
Assert-True ($after1 -match 'range 10\.10\.10\.10 10\.10\.10\.200')  'DHCP 地址池还在'
Assert-True ($after1 -match 'option routers 10\.10\.10\.2;')          '网关配置还在'
Assert-True ($after1 -match 'option domain-name-servers 10\.10\.10\.2;') 'DNS 配置还在'
Assert-True ($after1 -match 'default-lease-time 1800;')              '租期配置还在'
Assert-True ($after1 -match 'subnet 192\.168\.56\.0')                '别的网段(VMnet1)还在'
Assert-True ($after1 -match 'host VMnet8 \{')                        'VMware 自己的 host 块还在'
Assert-True ($after1 -match 'host VMnet1 \{')                        'VMnet1 的块还在'

$after1Lines = ($after1 -split "`r?`n").Count
Write-Host "  (行数 $beforeLines -> $after1Lines,三个块各 4 行,应该 +12)"
Assert-True ($after1Lines -eq ($beforeLines + 12)) '行数正好多了 12 行(3 块 x 4 行)'

Write-Host ''
Write-Host '=== 第二次写入(幂等性) ==='
Set-StaticDhcpLease -Subnet '10.10.10.0' -Netmask '255.255.255.0' -Lease $leases
$after2 = Get-Content -LiteralPath $copy -Raw

$count = ([regex]::Matches($after2, 'host k8s-master \{')).Count
Assert-True ($count -eq 1) "k8s-master 块只有一个(实际 $count)"
$count = ([regex]::Matches($after2, 'fixed-address 10\.10\.10\.11;')).Count
Assert-True ($count -eq 1) "10.10.10.11 的租约只有一条(实际 $count)"
Assert-True (($after2 -split "`r?`n").Count -eq $after1Lines) '第二次写入没有增加行数'
Assert-True ($after2 -match 'subnet 192\.168\.56\.0') '第二次写入后别的网段还在'
Assert-True ($after2 -match 'range 10\.10\.10\.10 10\.10\.10\.200') '第二次写入后地址池还在'

Write-Host ''
Write-Host '=== 清理 ==='
Remove-Item -LiteralPath $copy -Force
Remove-Item -LiteralPath "$copy.vmware-k8s.bak" -Force -ErrorAction SilentlyContinue
Write-Host '  副本已删除,宿主机上的 vmnetdhcp.conf 未被改动'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
