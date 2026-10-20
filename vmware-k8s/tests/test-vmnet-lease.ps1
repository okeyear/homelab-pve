# vmware-k8s — VMware DHCP 池的读取与判断
#
# 为什么要有这个测试:
#
# 节点 IP 是**写死**的静态地址(10.10.10.201 / .202 / .203),
# 由 guest 自己写进 netplan。宿主机这边不再改 VMware 的 DHCP 配置,
# 所以整个流程不需要管理员权限。
#
# 但代价是:静态地址必须自己保证**不落在 VMware 的 DHCP 池里**。
# 池子里的地址随时可能被派给别的机器,IP 一撞,表现是
# "偶尔 SSH 上的是另一台机器" —— 极难查。
#
# 所以这里测两件事:
#   1. Get-VmnetDhcpRange 能不能从 vmnetdhcp.conf 里把 range 读出来
#   2. Test-IpInRange 的边界判断对不对(特别是上下边界和跨段)
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-vmnet-lease.ps1

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

# ---------------------------------------------------------------- 1
Write-Host '=== 从 vmnetdhcp.conf 里读出 range ==='

$fixture = Join-Path $TestDir '_vmnetdhcp.conf'
# 真机上这个文件里**有好几段** subnet:VMnet1 的 host-only、
# VMnet8 的 NAT……第一段往往不是我们要的那个。
# 实测本机第一个 range 是 192.168.56.128-254(VMnet1),
# 10.10.10.0/24 那段在文件更靠后的位置 —— 拿第一个来判断
# "静态地址有没有和 DHCP 撞",等于什么都没验。
$conf = @'
# VMware DHCP 配置(节选,格式和真的一模一样)
subnet 192.168.56.0 netmask 255.255.255.0 {
range 192.168.56.128 192.168.56.254;            # default allows up to 125 VM's
option broadcast-address 192.168.56.255;
option domain-name-servers 192.168.56.2;
option routers 192.168.56.2;
default-lease-time 1800;
max-lease-time 7200;
}
subnet 10.10.10.0 netmask 255.255.255.0 {
range 10.10.10.10 10.10.10.200;            # default allows up to 125 VM's
option broadcast-address 10.10.10.255;
option domain-name-servers 10.10.10.2;
option routers 10.10.10.2;
default-lease-time 1800;
max-lease-time 7200;
}
host VMnet8 {
    hardware ethernet 00:50:56:C0:00:08;
    fixed-address 10.10.10.1;
}
'@
Write-Utf8Text $fixture $conf

$range = Get-VmnetDhcpRange -Path $fixture -Subnet '10.10.10.0'
Assert-True ($null -ne $range) '读得出 range'
if ($range) {
    Assert-True ($range.Start -eq '10.10.10.10') "range 起点对(实际 $($range.Start))"
    Assert-True ($range.End -eq '10.10.10.200') "range 终点对(实际 $($range.End))"
}

# 不给网段时取第一个 —— 也就是 192.168.56.128 那段
$first = Get-VmnetDhcpRange -Path $fixture
Assert-True ($null -ne $first) '不给网段时也能读出 range'
if ($first) {
    Assert-True ($first.Start -eq '192.168.56.128') "默认取的是文件里第一段(实际 $($first.Start))"
}

# 指定一个不存在的网段 -> null(不拿别的网段凑数)
Assert-True ($null -eq (Get-VmnetDhcpRange -Path $fixture -Subnet '10.99.99.0')) `
    '网段不存在时返回 null(不拿别的网段凑数)'

# 没有 range 的配置文件 -> 返回 null(而不是瞎猜一个)
$noRange = Join-Path $TestDir '_vmnetdhcp_norange.conf'
Write-Utf8Text $noRange "subnet 10.10.10.0 netmask 255.255.255.0 {`noption routers 10.10.10.2;`n}"
Assert-True ($null -eq (Get-VmnetDhcpRange -Path $noRange)) '没有 range 行时返回 null(不瞎猜)'

# 文件不存在 -> null
Assert-True ($null -eq (Get-VmnetDhcpRange -Path (Join-Path $TestDir '_不存在的文件.conf'))) `
    '文件不存在时返回 null'

# ---------------------------------------------------------------- 2
Write-Host ''
Write-Host '=== Test-IpInRange 的边界判断 ==='
$start = '10.10.10.10'
$end = '10.10.10.200'

# 池内
Assert-True (Test-IpInRange -Address '10.10.10.10' -Start $start -End $end) '起点算在池内'
Assert-True (Test-IpInRange -Address '10.10.10.200' -Start $start -End $end) '终点算在池内'
Assert-True (Test-IpInRange -Address '10.10.10.100' -Start $start -End $end) '中间算在池内'

# 池外
Assert-True (-not (Test-IpInRange -Address '10.10.10.9' -Start $start -End $end)) '起点前面一个不在池内'
Assert-True (-not (Test-IpInRange -Address '10.10.10.201' -Start $start -End $end)) '终点后面一个不在池内'
Assert-True (-not (Test-IpInRange -Address '10.10.10.1' -Start $start -End $end)) '宿主机自己的地址不在池内'
Assert-True (-not (Test-IpInRange -Address '10.10.10.250' -Start $start -End $end)) 'VIP 不在池内'
Assert-True (-not (Test-IpInRange -Address '10.10.11.100' -Start $start -End $end)) '别的网段不在池内'
Assert-True (-not (Test-IpInRange -Address '10.9.10.100' -Start $start -End $end)) '更前面的网段不在池内'

# ---------------------------------------------------------------- 3
Write-Host ''
Write-Host '=== 本方案用到的静态地址都在池外 ==='
# 这是**真机**检查:读真实的 vmnetdhcp.conf,确认 build.ps1 变量区
# 里的静态地址不会和 DHCP 抢。读不到配置就跳过(不是所有机器都装了
# VMware 的 DHCP 服务)。
$real = Get-VmnetDhcpRange -Subnet '10.10.10.0'
if (-not $real) {
    Write-Host '  [skip] 本机读不到 vmnetdhcp.conf,跳过真机检查' -ForegroundColor Yellow
}
else {
    Write-Host ("       本机 DHCP 池: {0} - {1}" -f $real.Start, $real.End)
    foreach ($ip in @('10.10.10.9', '10.10.10.201', '10.10.10.202', '10.10.10.203', '10.10.10.250')) {
        Assert-True (-not (Test-IpInRange -Address $ip -Start $real.Start -End $real.End)) `
            "$ip 不在本机 DHCP 池里"
    }
}

# ---------------------------------------------------------------- 清理
foreach ($f in @($fixture, $noRange)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
