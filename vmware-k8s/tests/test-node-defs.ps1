# vmware-k8s — 节点定义与 MAC 推导
#
# MAC 末位必须严格对应 IP 末位(十进制),因为：
#   1. 宿主机靠它写静态 DHCP 租约
#   2. guest 在拿不到 guestinfo 时靠 MAC 末位反推主机名
# 两边算出来不一致,节点就找不到。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\clone.ps1')

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

Write-Host '=== MAC 推导 ==='
$cases = @(
    @{ Ip = '10.10.10.201'; Mac = '00:50:56:0A:0A:C9' },
    @{ Ip = '10.10.10.202'; Mac = '00:50:56:0A:0A:CA' },
    @{ Ip = '10.10.10.203'; Mac = '00:50:56:0A:0A:CB' },
    @{ Ip = '10.10.10.9';   Mac = '00:50:56:0A:0A:09' },
    @{ Ip = '10.10.10.11';  Mac = '00:50:56:0A:0A:0B' }
)
foreach ($c in $cases) {
    $got = New-NodeMac -Address $c.Ip
    Assert-True ($got -eq $c.Mac) ("{0} -> {1}" -f $c.Ip, $got)
}

Write-Host ''
Write-Host '=== MAC 末位反推 IP 末位 ==='
foreach ($c in $cases) {
    $last = [int]('0x' + ($c.Mac -split ':')[-1])
    $ipLast = [int](($c.Ip -split '\.')[-1])
    Assert-True ($last -eq $ipLast) ("{0} 的 MAC 末位 {1} == IP 末位 {2}" -f $c.Ip, $last, $ipLast)
}

Write-Host ''
Write-Host '=== MAC 是合法的 VMware OUI ==='
foreach ($c in $cases) {
    Assert-True ($c.Mac -like '00:50:56:*') ("{0} 用的是 VMware 的 OUI 00:50:56" -f $c.Mac)
    Assert-True ($c.Mac -match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$') ("{0} 格式合法" -f $c.Mac)
}

Write-Host ''
Write-Host '=== 节点定义 ==='
$nodes = @(
    New-NodeDefinition -Name 'k8s-master' -Address '10.10.10.201' `
        -Mac (New-NodeMac -Address '10.10.10.201') -Role 'master' -Cpus 2 -MemoryMB 4096 -DiskGB 20
    New-NodeDefinition -Name 'k8s-worker1' -Address '10.10.10.202' `
        -Mac (New-NodeMac -Address '10.10.10.202') -Role 'worker' -Cpus 2 -MemoryMB 4096 -DiskGB 20
)
Assert-True ($nodes.Count -eq 2) '生成了 2 个节点'
# 注意 @():Where-Object 只剩一个结果时返回的是**单个对象**而不是数组,
# 严格模式下对它取 .Count 会抛 PropertyNotFoundStrict。
Assert-True (@($nodes | Where-Object { $_.Role -eq 'master' }).Count -eq 1) '正好 1 个 master'
Assert-True (@($nodes | Where-Object { $_.Role -eq 'worker' }).Count -eq 1) '正好 1 个 worker'
Assert-True ($nodes[0].Name -eq 'k8s-master') 'master 名字对'
Assert-True ($nodes[1].Address -eq '10.10.10.202') 'worker 地址对'

Write-Host ''
Write-Host '=== .vmx 改写 ==='
$tmp = Join-Path $TestDir '_test.vmx'
# 不带 BOM:5.1 的 Set-Content -Encoding UTF8 会加 BOM,而 Set-VmxValue
# 是按行改写的,BOM 会粘在第一行前面,改完的 .vmx 第一行就废了。
[System.IO.File]::WriteAllLines($tmp, @(
    '.encoding = "UTF-8"',
    'displayName = "k8s-template"',
    'memsize = "2048"',
    'numvcpus = "2"',
    'ethernet0.addressType = "generated"',
    'scsi0.virtualDev = "pvscsi"'
), (New-Object System.Text.UTF8Encoding($false)))

Set-VmxValue -VmxPath $tmp -Key 'memsize' -Value '4096'
Set-VmxValue -VmxPath $tmp -Key 'ethernet0.address' -Value '00:50:56:0A:0A:0B'
Set-VmxValue -VmxPath $tmp -Key 'guestinfo.hostname' -Value 'k8s-master'
# guest 靠这三个键拿到自己的 IP / 网关 / DNS(VMware 不会给 guest 传
# 环境变量,guestinfo 是唯一可靠的通道)
Set-VmxValue -VmxPath $tmp -Key 'guestinfo.ip' -Value '10.10.10.201'
Set-VmxValue -VmxPath $tmp -Key 'guestinfo.gateway' -Value '10.10.10.2'
Set-VmxValue -VmxPath $tmp -Key 'guestinfo.nameserver' -Value '10.10.10.2,223.5.5.5'
Remove-VmxKey -VmxPath $tmp -Key 'ethernet0.addressType'

$out = Get-Content -LiteralPath $tmp
Assert-True ($out -contains 'memsize = "4096"') '已有键被替换成新值'
Assert-True ($out -contains 'ethernet0.address = "00:50:56:0A:0A:0B"') '新键被追加'
Assert-True ($out -contains 'guestinfo.hostname = "k8s-master"') '带点的键被追加'
Assert-True ($out -contains 'guestinfo.ip = "10.10.10.201"') 'guestinfo.ip 被写进去'
Assert-True ($out -contains 'guestinfo.gateway = "10.10.10.2"') 'guestinfo.gateway 被写进去'
Assert-True ($out -contains 'guestinfo.nameserver = "10.10.10.2,223.5.5.5"') 'guestinfo.nameserver 被写进去'
Assert-True (-not ($out -contains 'ethernet0.addressType = "generated"')) '键被删除'
Assert-True ($out -contains 'displayName = "k8s-template"') '没碰到的键原样保留'
Assert-True ($out -contains '.encoding = "UTF-8"') '第一行没被 BOM 污染'
Assert-True (@($out | Where-Object { $_ -like 'memsize*' }).Count -eq 1) 'memsize 只有一行'
Remove-Item -LiteralPath $tmp -Force

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
