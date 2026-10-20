# vmware-k8s — 把 k8s-base 克隆成 k8s 节点
#
# 用 vmrun full clone:base 盘整份复制一份,然后改 .vmx 里的
# 资源规格和网卡。
#
# 关键点:MAC 是写死的(addressType=static)。因为节点要靠 MAC
# 认领自己的 IP —— 宿主机把 IP / 网关 / DNS 写进 .vmx 的 guestinfo,
# guest 里那个开机服务(vmware-clone-prep.sh)读回来,写进 netplan。
#
# 为什么不走宿主机上的静态 DHCP 租约:那要改
# C:\ProgramData\VMware\vmnetdhcp.conf 并重启 VMnetDHCP 服务,
# 普通权限做不了,整套流程会被"必须以管理员身份运行"卡住。
# 现在 IP 完全由 guest 自己配,宿主机一个字的全局配置都不用改。

Set-StrictMode -Version Latest

function New-NodeDefinition {
    <#
      .SYNOPSIS
        生成一台节点的完整定义。
      .DESCRIPTION
        MAC 末位直接对应 IP 末位(十进制):00:50:56:0A:0A:0B -> .11
        这样宿主机和 guest 都能各自从 MAC 推出同一个地址,不需要
        额外的映射表。
    #>
    param(
        [Parameter(Mandatory)][string]$Name,        # k8s-master
        # 允许空串:base 机器(k8s-base)装 base 的过程中走 DHCP,
        # 地址是问出来的,事先不知道。PowerShell 的 mandatory string
        # 参数默认**拒绝**空串,不显式放开的话,建 base 节点这一步
        # 直接报 "Cannot bind argument to parameter 'Address' because
        # it is an empty string"。
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,     # 10.10.10.201
        [Parameter(Mandatory)][string]$Mac,         # 00:50:56:0A:0A:C9
        [Parameter(Mandatory)][string]$Role,         # master / worker
        [int]$Cpus = 2,
        [int]$MemoryMB = 4096,
        [int]$DiskGB = 20
    )
    [pscustomobject]@{
        Name     = $Name
        Address  = $Address
        Mac      = $Mac
        Role     = $Role
        Cpus     = $Cpus
        MemoryMB = $MemoryMB
        DiskGB   = $DiskGB
        VmDir    = $null
        Vmx      = $null
    }
}

function New-NodeMac {
    <#
      .SYNOPSIS
        按 IP 生成一个确定性的 VMware MAC。
      .DESCRIPTION
        用 VMware 自己的 OUI 00:50:56,后两字节从 IP 末位推:
        10.10.10.11  -> 00:50:56:0A:0A:0B
        10.10.10.101 -> 00:50:56:0A:0A:65
    #>
    param([Parameter(Mandatory)][string]$Address)
    $oct = [int](($Address -split '\.')[3])
    '{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}' -f 0x00, 0x50, 0x56, 0x0A, 0x0A, $oct
}

function Set-VmxValue {
    <#
      .SYNOPSIS
        改 .vmx 里的键值。键不存在就追加,存在就替换整行。
    #>
    param(
        [Parameter(Mandatory)][string]$VmxPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $VmxPath)
    $prefix = "$Key = "
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ("^\s*" + [regex]::Escape($Key) + "\s*=")) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $lines[$idx] = $prefix + '"' + $Value + '"'
    }
    else {
        $lines.Add($prefix + '"' + $Value + '"')
    }
    Write-Utf8Lines $VmxPath $lines.ToArray()
}

function Remove-VmxKey {
    param(
        [Parameter(Mandatory)][string]$VmxPath,
        [Parameter(Mandatory)][string]$Key
    )
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $VmxPath)
    $lines.RemoveAll({ param($l) $l -match ("^\s*" + [regex]::Escape($Key) + "\s*=") }) | Out-Null
    Write-Utf8Lines $VmxPath $lines.ToArray()
}

function Invoke-Vmrun {
    <#
      .SYNOPSIS
        调 vmrun,把 stdout/stderr 合并返回。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $all = @('-T', 'ws') + $Arguments
    $out = & $VmrunExe @all 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Output   = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    }
}

function Copy-TemplateToNode {
    <#
      .SYNOPSIS
        把 base 盘全克隆成一台节点,并按节点定义改好 .vmx。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$TemplateVmx,
        [Parameter(Mandatory)][string]$VmRoot,
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][string]$Vnet,
        # 网关 / DNS,写进 guestinfo 交给 guest 自己配 netplan。
        # base 机器不需要(它走 DHCP),可以留空。
        [string]$Gateway = '',
        [string]$Dns = ''
    )

    $vmDir = Join-Path $VmRoot $Node.Name
    $vmx = Join-Path $vmDir "$($Node.Name).vmx"

    if (Test-Path -LiteralPath $vmx) {
        Write-Info "已存在,先删掉旧的: $vmx"
        Remove-Item -LiteralPath $vmDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $vmDir) {
        Remove-Item -LiteralPath $vmDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    Write-Info "full clone: $TemplateVmx -> $vmx"
    $r = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('clone', $TemplateVmx, $vmx, 'full')
    if ($r.ExitCode -ne 0) {
        Stop-WithError "vmrun clone 失败:`n$($r.Output)"
    }

    # ---- 改 .vmx ----
    Set-VmxValue -VmxPath $vmx -Key 'displayName' -Value $Node.Name
    Set-VmxValue -VmxPath $vmx -Key 'memsize' -Value ([string]$Node.MemoryMB)
    Set-VmxValue -VmxPath $vmx -Key 'numvcpus' -Value ([string]$Node.Cpus)
    Set-VmxValue -VmxPath $vmx -Key 'scsi0.virtualDev' -Value 'pvscsi'
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.connectionType' -Value 'nat'
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.vnet' -Value $Vnet
    # MAC 写死:节点要靠它认领自己的 IP,必须是开机前就已知的。
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.addressType' -Value 'static'
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.address' -Value $Node.Mac
    # guestinfo:guest 那边靠它拿到自己的主机名
    Set-VmxValue -VmxPath $vmx -Key 'guestinfo.hostname' -Value $Node.Name
    # guestinfo:guest 那边靠它拿到自己的 IP / 网关 / DNS,写进 netplan。
    # VMware 不会给 guest 传环境变量,guestinfo 是唯一可靠的通道
    # (guest 里用 vmware-rpctool "info-get guestinfo.ip" 读)。
    #
    # base 机器的 Address 是空的(它走 DHCP,地址用 vmrun 问出来),
    # 这三个键就不写 —— 写一个空字符串进去,clone-prep 会当成"宿主机
    # 说这个地址是空的",反而添乱。
    if ($Node.Address) {
        Set-VmxValue -VmxPath $vmx -Key 'guestinfo.ip' -Value $Node.Address
        if ($Gateway) { Set-VmxValue -VmxPath $vmx -Key 'guestinfo.gateway' -Value $Gateway }
        if ($Dns) { Set-VmxValue -VmxPath $vmx -Key 'guestinfo.nameserver' -Value $Dns }
    }
    Set-VmxValue -VmxPath $vmx -Key 'annotation' -Value "vmware-k8s $($Node.Role) $($Node.Address)"

    # 模板上挂着的安装 ISO 不用了,留着会让机器每次启动都去认那张盘。
    foreach ($k in @('ide1:0.present', 'ide1:0.fileName', 'ide1:0.deviceType',
            'ide1:0.startConnected', 'ide1:0.mode', 'sata0:1.present')) {
        Set-VmxValue -VmxPath $vmx -Key $k -Value 'FALSE'
    }
    Remove-VmxKey -VmxPath $vmx -Key 'ide1:0.fileName'
    Remove-VmxKey -VmxPath $vmx -Key 'ide1:0.deviceType'

    # 磁盘:全克隆出来的盘是模板那么大,按节点规格扩一下
    Expand-NodeDisk -VmrunExe $VmrunExe -Node $Node -VmxPath $vmx

    $Node | Add-Member -NotePropertyName VmDir -NotePropertyValue $vmDir -Force
    $Node | Add-Member -NotePropertyName Vmx -NotePropertyValue $vmx -Force
    Write-Ok ("{0,-12} {1,-14} {2}  {3}C/{4}MB/{5}G" -f `
            $Node.Name, $Node.Address, $Node.Mac, $Node.Cpus, $Node.MemoryMB, $Node.DiskGB)
    return $Node
}

function Expand-NodeDisk {
    <#
      .SYNOPSIS
        把克隆出来的虚拟盘扩到节点规格要求的大小。
      .DESCRIPTION
        vmrun 没有 resize 子命令,得用 vmware-vdiskmanager。
        磁盘改大是安全的(vmx 里写的是新大小,盘上是稀疏文件),
        改小会丢数据,所以只允许变大。

        磁盘文件的位置**从 .vmx 里读**(scsi0:0.fileName),不靠扫目录猜:
        packer 的产物叫 disk.vmdk,而 vmrun full clone 出来的常常叫
        <节点名>-disk1.vmdk —— 靠文件名模式去筛,很容易把唯一那块盘
        筛掉,然后"扩盘"静默变成"什么都没做"。

        vmware-vdiskmanager -x 的单位是**MB**,不是 "20 GB" 这种带单位的
        字符串(写成带单位的会被当成非法值)。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][string]$VmxPath
    )
    $vdm = Join-Path (Split-Path -Parent $VmrunExe) 'vmware-vdiskmanager.exe'
    if (-not (Test-Path -LiteralPath $vdm)) {
        Write-Note "找不到 vmware-vdiskmanager.exe,磁盘保持模板大小"
        return
    }

    $vmDir = Split-Path -Parent $VmxPath
    $vmdkPath = $null
    foreach ($l in (Read-Utf8Lines $VmxPath)) {
        if ($l -match '^\s*scsi0:0\.fileName\s*=\s*"(.*)"') {
            $vmdkPath = Join-Path $vmDir $Matches[1]
            break
        }
    }
    if (-not $vmdkPath -or -not (Test-Path -LiteralPath $vmdkPath)) {
        # .vmx 里没写 scsi0:0.fileName(老磁盘用 ide/sata)就退回去扫,
        # 但这次不排除任何名字 —— 只排除 snapshot 目录。
        $hit = Get-ChildItem -LiteralPath $vmDir -Filter '*.vmdk' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -eq $vmDir } |
            Select-Object -First 1
        if ($hit) { $vmdkPath = $hit.FullName }
    }
    if (-not $vmdkPath) {
        Write-Note '没找到 .vmdk,磁盘保持模板大小'
        return
    }

    # 目标大小:MB
    $targetMB = [int]$Node.DiskGB * 1024
    $r = & $vdm -x $targetMB $vmdkPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Note "扩盘失败(保持原大小): $(($r | Out-String).Trim())"
        return
    }
    Write-Ok "磁盘已扩到 $targetMB MB ($($Node.DiskGB) GB)"
}

function Start-NodeVm {
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][object]$Node
    )
    Write-Info "启动 $($Node.Name)"
    $r = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('start', $Node.Vmx, 'nogui')
    if ($r.ExitCode -ne 0) {
        Stop-WithError "启动 $($Node.Name) 失败:`n$($r.Output)"
    }
}

function Stop-NodeVm {
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][object]$Node,
        [switch]$Hard
    )
    if ($Hard) {
        $null = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('stop', $Node.Vmx, 'hard')
    }
    else {
        $null = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('stop', $Node.Vmx, 'soft')
    }
}

function Get-NodeGuestIp {
    <#
      .SYNOPSIS
        用 vmrun 从 VMware Tools 问 guest 当前的 IP。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][object]$Node
    )
    $r = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('getGuestIPAddress', $Node.Vmx, '-wait')
    if ($r.ExitCode -ne 0) { return $null }
    $ip = ($r.Output -split "`n" | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1)
    if ($ip) { return $ip.Trim() }
    return $null
}
