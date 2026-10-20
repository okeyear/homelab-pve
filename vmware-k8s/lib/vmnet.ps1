# vmware-k8s — vmnet 检测
#
# 节点要拿到固定 IP(10.10.10.201 / .202 / .203),因为仓库里
# setup-k8s/config.sh 的 MASTER_NODES / WORKER_NODES 就是写死的
# 这几个地址。
#
# 做法**不在宿主机上**做:早期方案是往 VMware 的 DHCP 配置里写静态
# 租约,那要改 C:\ProgramData\VMware\vmnetdhcp.conf 并重启 VMnetDHCP
# 服务,普通权限做不了。现在改成由 guest 自己写 netplan 配静态 IP
# (见 guest/clone-prep.sh),宿主机这边一行全局配置都不用改。
#
# 但"地址不能和 DHCP 池撞"这件事必须查 —— VMware 的 DHCP 池是
# 10.10.10.10 - 10.10.10.200,写死的静态地址要是落在池子里,
# DHCP 随时可能把它派给别的机器,IP 就撞了。

Set-StrictMode -Version Latest

$script:VmDhcpConf = 'C:\ProgramData\VMware\vmnetdhcp.conf'
$script:VmNatConf = 'C:\ProgramData\VMware\vmnetnat.conf'

function Get-VmnetAdapters {
    <#
      .SYNOPSIS
        列出宿主机上的 VMware 虚拟网卡,按 vmnet 号排序。
    #>
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'VMware Virtual Ethernet Adapter for VMnet(\d+)' } |
        ForEach-Object {
            [pscustomobject]@{
                Name       = $_.Name
                Vmnet      = [int]([regex]::Match($_.InterfaceDescription, 'VMnet(\d+)').Groups[1].Value)
                Mac        = $_.MacAddress
                Status     = $_.Status
                Ip         = (Get-NetIPAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty IPAddress)
                PrefixLen  = (Get-NetIPAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty PrefixLength)
            }
        } | Sort-Object Vmnet
}

function Get-VmnetNatSubnet {
    <#
      .SYNOPSIS
        从 vmnetnat.conf 里读出 NAT 网段。NAT 网段是有网关、能出网的那个。
    #>
    if (-not (Test-Path -LiteralPath $script:VmNatConf)) { return $null }
    $conf = Read-Utf8Text $script:VmNatConf
    $m = [regex]::Match($conf, 'ip\s*=\s*(\d+\.\d+\.\d+\.\d+)')
    if (-not $m.Success) { return $null }
    $gw = $m.Groups[1].Value
    [pscustomobject]@{ Gateway = $gw; Subnet = (($gw -replace '\.\d+$', '.0') + '/24') }
}

function Resolve-VmnetForSubnet {
    <#
      .SYNOPSIS
        找到承载目标网段的 vmnet,并核对宿主机自己在这个网段里。
      .OUTPUTS
        @{ Name='vmnet8'; Ip='10.10.10.1'; Prefix=24; Gateway='10.10.10.2' }
    #>
    param(
        [Parameter(Mandatory)][string]$Subnet,      # 例如 10.10.10.0/24
        [string]$Prefer = 'vmnet8'
    )
    $base = ($Subnet -split '/')[0] -replace '\.\d+$', ''

    $adapters = Get-VmnetAdapters
    if (-not $adapters) {
        Stop-WithError '宿主机上找不到任何 VMware 虚拟网卡。VMware Workstation 的网络组件没装好。'
    }

    # 先看有没有现成就在目标网段里的网卡
    $match = $adapters | Where-Object { $_.Ip -and $_.Ip -like "$base.*" } | Select-Object -First 1
    if (-not $match) {
        # 没有就退回 NAT 网段——NAT 是唯一自带 DHCP + 出网能力的
        $nat = Get-VmnetNatSubnet
        if ($nat) {
            $match = $adapters | Where-Object { $_.Ip -eq $nat.Gateway } | Select-Object -First 1
            if ($match) {
                Write-Note ("目标网段 {0} 在宿主机上没有对应的 vmnet,改用 NAT 网段 {1}(vmnet{2})" -f `
                        $Subnet, $nat.Subnet, $match.Vmnet)
            }
        }
    }
    if (-not $match) {
        Write-Fail ("宿主机上没有 vmnet 落在 {0} 里。现有网卡:" -f $Subnet)
        $adapters | ForEach-Object { Write-Host ("        vmnet{0}  {1}  {2}" -f $_.Vmnet, $_.Ip, $_.Status) }
        Write-Host '        用 vmnetcfg.exe(VMware 安装目录下)把某个 vmnet 改成这个网段,或者改 build.ps1 里的 $NetSubnet。'
        Stop-WithError '无法确定用哪个 vmnet'
    }

    $nat = Get-VmnetNatSubnet
    [pscustomobject]@{
        Name    = $match.Name
        Vmnet   = $match.Vmnet
        Ip      = $match.Ip
        Prefix  = $match.PrefixLen
        Gateway = $(if ($nat) { $nat.Gateway } else { "$base.2" })
        Dns     = $(if ($nat) { $nat.Gateway } else { "$base.2" })
    }
}

function Get-VmnetDhcpRange {
    <#
      .SYNOPSIS
        读出某个网段在 VMware DHCP 里的地址池范围。

      .DESCRIPTION
        写在 vmnetdhcp.conf 的 subnet 段里,形如:

            subnet 10.10.10.0 netmask 255.255.255.0 {
            range 10.10.10.10 10.10.10.200;            # default allows up to 125 VM's
            ...

        **必须按网段找,不能拿文件里第一个 range 就用。**
        一个 vmnetdhcp.conf 里通常有好几段(VMnet1 的 host-only、
        VMnet8 的 NAT……),第一段往往不是我们关心的那个。实测本机上
        第一个 range 是 192.168.56.128-254(VMnet1),而 NAT 那段
        10.10.10.0/24 的 range 在文件更靠后的位置 —— 拿第一个来判断
        "静态地址有没有和 DHCP 撞",等于什么都没验。

        读不到就返回 $null —— 宁可不知道,也不要瞎猜一个范围出来
        (猜错了会让人以为地址是安全的,实际撞了 IP)。

      .PARAMETER Subnet
        目标网段,例如 '10.10.10.0'。留空 = 取文件里第一个 range。
    #>
    param(
        [string]$Subnet = '',
        [string]$Path = ''
    )
    if (-not $Path) { $Path = $script:VmDhcpConf }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $Path)

    # 找到目标 subnet 段。段里有可能有嵌套的大括号(少见,但
    # "host xxx { ... }" 就是一层的),所以按大括号配对数行数,
    # 不靠正则去猜哪一行是收尾。
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($Subnet) {
            if ($lines[$i] -match ('^\s*subnet\s+' + [regex]::Escape($Subnet) + '\s')) { $start = $i; break }
        }
        else {
            if ($lines[$i] -match '^\s*subnet\s+') { $start = $i; break }
        }
    }
    if ($start -lt 0) { return $null }

    $depth = 0
    $end = $start
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -le 0) { $end = $i; break }
    }

    for ($i = $start; $i -le $end; $i++) {
        $m = [regex]::Match($lines[$i], '^\s*range\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)')
        if ($m.Success) {
            return [pscustomobject]@{
                Start = $m.Groups[1].Value
                End   = $m.Groups[2].Value
                Subnet = $Subnet
            }
        }
    }
    return $null
}

function Test-IpInRange {
    <#
      .SYNOPSIS
        判断一个 IP 是否落在某个地址范围里。
    #>
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Start,
        [Parameter(Mandatory)][string]$End
    )
    $a = [System.Net.IPAddress]::Parse($Address)
    $s = [System.Net.IPAddress]::Parse($Start)
    $e = [System.Net.IPAddress]::Parse($End)
    $ab = $a.GetAddressBytes()
    $sb = $s.GetAddressBytes()
    $eb = $e.GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        if ($ab[$i] -lt $sb[$i]) { return $false }
        if ($ab[$i] -gt $eb[$i]) { return $false }
    }
    return $true
}
