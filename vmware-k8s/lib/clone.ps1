# vmware-k8s — 从模板全克隆出 k8s 节点
#
# 用 vmrun full clone:模板盘整份复制一份,然后改 .vmx 里的
# 资源规格和网卡。
#
# 关键点:MAC 是写死的(addressType=static)。因为节点要靠 MAC
# 在 VMware 的 DHCP 里拿固定 IP(见 vmnet.ps1),MAC 必须在
# 开机之前就是已知的,不能等 VMware 随机生成。

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
        [Parameter(Mandatory)][string]$Address,     # 10.10.10.11
        [Parameter(Mandatory)][string]$Mac,         # 00:50:56:0A:0A:0B
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
        把模板全克隆成一台节点,并按节点定义改好 .vmx。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$TemplateVmx,
        [Parameter(Mandatory)][string]$VmRoot,
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][string]$Vnet
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
    # MAC 写死:节点要靠它拿固定 IP,必须是开机前就已知的。
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.addressType' -Value 'static'
    Set-VmxValue -VmxPath $vmx -Key 'ethernet0.address' -Value $Node.Mac
    # guestinfo:guest 那边靠它拿到自己的主机名
    Set-VmxValue -VmxPath $vmx -Key 'guestinfo.hostname' -Value $Node.Name
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
    $vmdk = Get-ChildItem -LiteralPath (Split-Path -Parent $VmxPath) -Filter '*.vmdk' -File |
        Where-Object { $_.Name -notlike '*-disk1.vmdk' -and $_.Name -notlike '*snapshot*' } |
        Select-Object -First 1
    if (-not $vmdk) {
        Write-Note '没找到 .vmdk,磁盘保持模板大小'
        return
    }
    $target = "{0} GB" -f $Node.DiskGB
    $r = & $vdm -x $target $vmdk.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Note "扩盘失败(保持原大小): $(($r | Out-String).Trim())"
        return
    }
    Write-Ok "磁盘已扩到 $target"
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
