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

      .DESCRIPTION
        找键的时候**大小写不敏感**,替换时保留原来那个键的写法。

        为什么:packer 生成的 vmx 里键名全是小写
        (ethernet0.connectiontype / ethernet0.addresstype /
        scsi0.virtualdev),而手写的代码里习惯写成驼峰
        (ethernet0.connectionType)。两者不是同一个键 —— 大小写敏感的
        匹配会认为"这个键不存在",于是**追加**一条同名(不同大小写)的
        键,vmx 里就出现两条描述同一件事的记录。VMware 解析时行为
        不确定(取哪条、报不报警都看版本),排障时更是看着完全正常。

        替换时保留原键的写法,免得 vmx 里同一个键一会儿驼峰一会儿小写,
        下次再改还是要靠不敏感匹配。
    #>
    param(
        [Parameter(Mandatory)][string]$VmxPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $VmxPath)
    $idx = -1
    $foundKey = $Key
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^\s*([A-Za-z0-9_:\.\-]+)\s*=')
        if (-not $m.Success) { continue }
        if ($m.Groups[1].Value -ieq $Key) {
            $idx = $i
            $foundKey = $m.Groups[1].Value
            break
        }
    }
    $prefix = "$foundKey = "
    if ($idx -ge 0) {
        $lines[$idx] = $prefix + '"' + $Value + '"'
    }
    else {
        $lines.Add($prefix + '"' + $Value + '"')
    }
    Write-Utf8Lines $VmxPath $lines.ToArray()
}

function Remove-VmxKey {
    <#
      .SYNOPSIS
        删掉 .vmx 里的某个键。大小写不敏感。
    #>
    param(
        [Parameter(Mandatory)][string]$VmxPath,
        [Parameter(Mandatory)][string]$Key
    )
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $VmxPath)
    $lines.RemoveAll({ param($l) $l -match ('^\s*([A-Za-z0-9_:\.\-]+)\s*=') -and $Matches[1] -ieq $Key }) | Out-Null
    Write-Utf8Lines $VmxPath $lines.ToArray()
}

function Remove-IsoAttachments {
    <#
      .SYNOPSIS
        把 .vmx 里指向 .iso 的键删掉。

      .DESCRIPTION
        模板是 packer 装出来的,装完 packer 自己会把 ISO 摘掉
        (模板 vmx 里只剩 ide0:0.filename = "auto detect")。
        这里是真克隆前的兜底:万一哪台机器上还挂着 ISO,每次启动都要
        去认那张盘,慢,还可能认错。

        之前是"追加一堆 ide1:0.* = FALSE"来关掉光驱 —— 那会在 vmx
        里凭空造出一个不存在的 ide1 控制器,还顺手写了个
        ide1:0.mode = "FALSE"(mode 键要的是 "pioneer"/"nat")。
        直接删掉真正指向 iso 的键更干净。
    #>
    param([Parameter(Mandatory)][string]$VmxPath)
    $lines = [System.Collections.Generic.List[string]](Read-Utf8Lines $VmxPath)
    $removed = @()
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($lines[$i], '^\s*([A-Za-z0-9_:\.\-]+)\s*=\s*"(.*)"\s*$')
        if (-not $m.Success) { continue }
        if ($m.Groups[2].Value -match '(?i)\.iso\s*$') {
            $removed += $m.Groups[1].Value
            $lines.RemoveAt($i)
        }
    }
    if ($removed.Count -gt 0) {
        Write-Info ("已摘掉 ISO 挂载: {0}" -f (($removed | Sort-Object -Unique) -join ', '))
    }
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
    # 走 Invoke-Native:vmrun 经常往 stderr 写警告,直接 & 的话在
    # $ErrorActionPreference='Stop' 下会当场终止脚本。
    return (Invoke-Native -Exe $VmrunExe -Arguments $all)
}

function Set-NodePaths {
    <#
      .SYNOPSIS
        算出每个节点的 VM 目录和 .vmx 路径。

      .DESCRIPTION
        clone 阶段会真的把 .vmx 改好(Copy-TemplateToNode 里有
        Add-Member),但那是在**另一个进程**里跑的 —— 每个阶段都是
        单独起一个 build.ps1,boot 阶段的节点定义又是全新的,
        Vmx / VmDir 是空的。

        结果就是 boot 阶段报
            Start-NodeVm : Cannot bind argument to parameter
            'Arguments' because it is an empty string.
        —— vmrun 的参数里那个 .vmx 路径是空的。

        路径其实是完全确定的:$VmRoot\<节点名>\<节点名>.vmx,
        这里直接算出来,不依赖上一个阶段留下的内存状态。
    #>
    param(
        [Parameter(Mandatory)][object[]]$NodeList,
        [Parameter(Mandatory)][string]$VmRoot
    )
    foreach ($n in $NodeList) {
        $dir = Join-Path $VmRoot $n.Name
        $n | Add-Member -NotePropertyName VmDir -NotePropertyValue $dir -Force
        $n | Add-Member -NotePropertyName Vmx `
            -NotePropertyValue (Join-Path $dir ($n.Name + '.vmx')) -Force
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
        # 先停掉还在跑的同名 VM:虚拟盘被它锁着的时候,
        # Remove-Item -Recurse 会失败("文件正在被另一进程使用")。
        Write-Info "已存在,先停掉再删掉旧的: $vmx"
        $null = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('stop', $vmx, 'hard')
        Start-Sleep -Seconds 3
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
    Remove-IsoAttachments -VmxPath $vmx

    # 磁盘:全克隆出来的盘是模板那么大,按节点规格扩一下
    Expand-NodeDisk -VmrunExe $VmrunExe -Node $Node -VmxPath $vmx

    $Node | Add-Member -NotePropertyName VmDir -NotePropertyValue $vmDir -Force
    $Node | Add-Member -NotePropertyName Vmx -NotePropertyValue $vmx -Force
    Write-Ok ("{0,-12} {1,-14} {2}  {3}C/{4}MB/{5}G" -f `
            $Node.Name, $Node.Address, $Node.Mac, $Node.Cpus, $Node.MemoryMB, $Node.DiskGB)
    return $Node
}

function Get-VmdkCapacityMB {
    <#
      .SYNOPSIS
        读出 .vmdk 的**虚拟**容量(MB)。

      .DESCRIPTION
        磁盘文件本身的大小不是容量:20G 的稀疏盘,文件可能只有 6G。
        真正写在描述符里的是扇区数:

            RW 41943040 SPARSE "disk-cl1.vmdk"

        41943040 个扇区 × 512 字节 = 20 GiB。

        monolithicSparse 的话描述符是**内嵌**在 .vmdk 文件头部的
        (前面有个 "KDMV" 魔数),单独的描述符文件则直接就是文本。
        两种都能用同一个正则读到。

        读不到就返回 $null —— 宁可不知道,也不要瞎猜一个容量出来
        (猜错了会把"不用扩"判断成"要扩",或者反过来)。
    #>
    param([Parameter(Mandatory)][string]$VmdkPath)
    $fs = $null
    $buf = $null
    $n = 0
    try {
        $fs = [System.IO.File]::Open($VmdkPath,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
    }
    catch {
        return $null
    }
    finally {
        if ($fs) { $fs.Close() }
    }
    if ($n -le 0) { return $null }
    $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    $m = [regex]::Match($head, 'RW\s+(\d+)\s+(SPARSE|PLAIN|VMFS|VMFSRAW|VMFSSPARSE|SE\s+sparse)')
    if (-not $m.Success) { return $null }
    $sectors = [long]$m.Groups[1].Value
    return [int][math]::Round($sectors * 512 / 1MB)
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

        已经是目标大小就**跳过**:模板本来就是 20G,克隆出来还是 20G,
        再扩一次 vmware-vdiskmanager 会报
        "One of the parameters supplied is invalid (0x3e80)"。
        这个报错是往 stderr 写的,在 $ErrorActionPreference='Stop' 下
        会把整个 build 带走 —— 实测就在 base 阶段踩过。
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
        # 大小写不敏感:VMware 写出来的可能是 scsi0:0.fileName,
        # 也可能是 scsi0:0.filename,只认一种就会漏掉唯一的盘。
        $m = [regex]::Match($l, '^\s*scsi0:0\.filename\s*=\s*"(.*)"', 'IgnoreCase')
        if ($m.Success) {
            $vmdkPath = Join-Path $vmDir $m.Groups[1].Value
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
    $curMB = Get-VmdkCapacityMB -VmdkPath $vmdkPath
    if ($null -ne $curMB) {
        if ($curMB -ge $targetMB) {
            Write-Ok "磁盘已经是 $curMB MB(>= 目标 $targetMB MB),不用扩"
            return
        }
        Write-Info "磁盘 $curMB MB -> 扩到 $targetMB MB"
    }

    $r = Invoke-Native -Exe $vdm -Arguments @('-x', "$targetMB", $vmdkPath)
    if ($r.ExitCode -ne 0) {
        Write-Note "扩盘失败(保持原大小): $($r.Output)"
        return
    }
    Write-Ok "磁盘已扩到 $targetMB MB ($($Node.DiskGB) GB)"
}

function Test-NodeVmRunning {
    <#
      .SYNOPSIS
        这台节点是不是已经在跑了。
      .DESCRIPTION
        `vmrun list` 只列正在跑的 VM,按 vmx 路径匹配。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$Vmx
    )
    $r = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('list')
    $hit = @($r.Output -split "`n" | Where-Object { $_.Trim() -like "*$Vmx*" })
    return ($hit.Count -gt 0)
}

function Start-NodeVm {
    <#
      .SYNOPSIS
        启动一台节点。

      .DESCRIPTION
        默认用 nogui 启动 —— 跑流水线的时候不需要窗口,也不怕
        图形界面接管(Workstation 对"不在库里、又是 vmrun 起的"机器,
        会在它关机时把整个目录当临时产物清掉,实测 20G 的盘一起没了)。

        -Gui 改成带控制台启动:节点会出现在 VMware Workstation 的
        库里,并且有实时画面。已经在跑的机器会先停掉再带控制台重启
        —— nogui 起的机器,Workstation 那边只有一幅旧画面。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][object]$Node,
        [switch]$Gui
    )
    $mode = if ($Gui) { 'gui' } else { 'nogui' }

    if (Test-NodeVmRunning -VmrunExe $VmrunExe -Vmx $Node.Vmx) {
        if (-not $Gui) {
            Write-Ok "$($Node.Name) 已经在跑,跳过启动"
            return
        }
        Write-Info "$($Node.Name) 已经在跑,先停掉再带控制台重启"
        $null = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('stop', $Node.Vmx, 'soft')
        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Test-NodeVmRunning -VmrunExe $VmrunExe -Vmx $Node.Vmx)) { break }
            Start-Sleep -Seconds 2
        }
        if (Test-NodeVmRunning -VmrunExe $VmrunExe -Vmx $Node.Vmx) {
            Write-Note "$($Node.Name) 停不掉,硬停"
            $null = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('stop', $Node.Vmx, 'hard')
            Start-Sleep -Seconds 3
        }
    }

    Write-Info "启动 $($Node.Name) (模式 $mode)"
    $r = Invoke-Vmrun -VmrunExe $VmrunExe -Arguments @('start', $Node.Vmx, $mode)
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
