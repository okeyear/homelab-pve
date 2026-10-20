# vmware-k8s — vmnet 检测与静态 DHCP 租约
#
# 节点要拿到固定 IP(10.10.10.11 / .101 / .102),因为仓库里
# setup-k8s/config.sh 的 MASTER_NODES / WORKER_NODES 就是写死的这几个地址。
#
# 做法:在 VMware 的 DHCP 配置里给每台机器的 MAC 写一条固定租约。
# guest 那边保持是一个普通的 DHCP 客户端,什么都不用改 —— 这比
# "往 guest 里写静态 IP"干净得多,也不用担心克隆之后 cloud-init
# 不重跑、IP 没被改的问题。

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

function Set-StaticDhcpLease {
    <#
      .SYNOPSIS
        在 vmnetdhcp.conf 的目标 subnet 段里写入/更新静态租约。
      .PARAMETER Lease
        @{ Mac='00:50:56:0A:0A:0B'; Address='10.10.10.11'; Name='k8s-master' }
    #>
    param(
        [Parameter(Mandatory)][string]$Subnet,       # 10.10.10.0
        [Parameter(Mandatory)][string]$Netmask,      # 255.255.255.0
        [Parameter(Mandatory)][object[]]$Lease
    )

    if (-not (Test-Path -LiteralPath $script:VmDhcpConf)) {
        Stop-WithError "找不到 $($script:VmDhcpConf),VMware 的 DHCP 服务没装好"
    }

    # 按 UTF-8 读,和下面写出去的编码对称(写是无 BOM 的 UTF-8)。
    # Get-Content 在 5.1 上默认 ANSI,读回来再写会把非 ASCII 变成乱码。
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $script:VmDhcpConf)
    $leaseNames = @($Lease | ForEach-Object { $_.Name })

    # ---- 1. 找到目标 subnet 段 ----
    # 之前这里用的是正则锚点 + 捕获组下标,结果把 subnet 段的正文
    # (range / option ...)整个弄丢了 —— 配置文件里有大括号,拿正则去
    # 猜哪一行是收尾,迟早出错。改成按大括号配对数行数,稳。
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^\s*subnet\s+' + [regex]::Escape($Subnet) +
                               '\s+netmask\s+' + [regex]::Escape($Netmask) + '\s*\{')) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) {
        Stop-WithError "vmnetdhcp.conf 里找不到 subnet $Subnet $Netmask 这一段"
    }

    $depth = 0
    $end = $start
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -le 0) { $end = $i; break }
    }
    if ($end -le $start) {
        Stop-WithError "subnet $Subnet 这一段的大括号不配对,不敢改"
    }

    # ---- 2. 把我们之前写的同名 host 块摘掉 ----
    $body = New-Object System.Collections.Generic.List[string]
    $i = $start
    while ($i -le $end) {
        $m = [regex]::Match($lines[$i], '^\s*host\s+(\S+)\s*\{')
        if ($m.Success -and ($leaseNames -contains $m.Groups[1].Value)) {
            $d = 0
            while ($i -le $end) {
                $d += ([regex]::Matches($lines[$i], '\{')).Count
                $d -= ([regex]::Matches($lines[$i], '\}')).Count
                $i++
                if ($d -le 0) { break }
            }
            continue
        }
        $body.Add($lines[$i])
        $i++
    }

    # ---- 3. 新租约插到 subnet 段收尾大括号之前 ----
    $close = $body[$body.Count - 1]
    $newBody = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $body.Count - 1; $i++) { $newBody.Add($body[$i]) }
    foreach ($l in $Lease) {
        $newBody.Add("host $($l.Name) {")
        $newBody.Add("    hardware ethernet $($l.Mac);")
        $newBody.Add("    fixed-address $($l.Address);")
        $newBody.Add("}")
    }
    $newBody.Add($close)

    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $start; $i++) { $result.Add($lines[$i]) }
    foreach ($l in $newBody) { $result.Add($l) }
    for ($i = $end + 1; $i -lt $lines.Count; $i++) { $result.Add($lines[$i]) }

    $backup = "$script:VmDhcpConf.vmware-k8s.bak"
    Copy-Item -LiteralPath $script:VmDhcpConf -Destination $backup -Force
    Write-Utf8Lines $script:VmDhcpConf $result.ToArray()
    Write-Ok "已写入静态租约到 $script:VmDhcpConf (备份: $backup)"

    foreach ($l in $Lease) {
        Write-Info ("    {0,-14} {1}  ->  {2}" -f $l.Name, $l.Mac, $l.Address)
    }
}

function Restart-VmwareDhcpService {
    $svc = Get-Service -Name 'VMnetDHCP' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Note '找不到 VMnetDHCP 服务,静态租约要等 VMware 重启后才生效'
        return
    }
    Write-Info '重启 VMnetDHCP 服务以加载新租约...'
    Restart-Service -Name 'VMnetDHCP' -Force
    Start-Sleep -Seconds 2
    $st = (Get-Service -Name 'VMnetDHCP').Status
    if ($st -ne 'Running') {
        Stop-WithError "VMnetDHCP 服务重启后状态是 $st,租约没生效"
    }
    Write-Ok 'VMnetDHCP 已重启'
}
