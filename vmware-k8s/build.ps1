<#
.SYNOPSIS
    在 Windows 上用 Packer + VMware Workstation 搭一个本地 k8s 集群。

.DESCRIPTION
    流程:
      1. preflight  体检 VMware / SSH / 磁盘,并把网络方案算出来
      2. packer     下载并校验 Packer(装在仓库内的 .cache,不污染系统)
      3. iso        从镜像站下 Ubuntu LTS 的 live-server ISO,校验 SHA256
      4. template   packer build 出一张模板盘(2C/2G/20G)
      5. network    给三个节点的 MAC 写静态 DHCP 租约,IP 固定住
      6. clone      vmrun full clone 出 1 master + 2 worker
      7. boot       启动并等三个节点 ssh 可用、地址核对无误
      8. k8s        复用仓库的 setup-k8s/scripts/*.sh 装集群(1 master + 2 worker)

    集群内部的组件安装全部走仓库里现成的脚本,这里一行都不改。

.EXAMPLE
    .\build.cmd                       # 全流程
    .\build.cmd -Stage preflight      # 只体检,不动任何东西
    .\build.cmd -Stage k8s            # 只跑装集群那一步
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'preflight', 'packer', 'iso', 'template', 'network', 'clone', 'boot', 'k8s', 'destroy')]
    [string]$Stage = 'all',

    # 只做环境体检并打印将要执行的计划,不下载、不克隆、不改任何配置
    [switch]$Check,

    # 强制重新 build 模板(默认:模板已存在就复用)
    [switch]$ForceTemplate,

    # 跳过 CNI 安装(默认会装,main.sh 漏了这一步)
    [switch]$SkipCni
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ==================================================================
#  变量区 —— 要改的东西都在这里
# ==================================================================

# ---- 网络 ---------------------------------------------------------
# VMware Workstation 的网段。宿主机上 vmnet8 已经是 10.10.10.0/24
# (NAT),这三个节点就挂在它上面:宿主机能直连,节点也能出网。
$NetSubnet = '10.10.10.0/24'
$MasterIP = '10.10.10.11'
$WorkerIPs = @('10.10.10.101', '10.10.10.102')
# apiserver 证书里的额外 SAN,不是真的 VIP
$LoadBalancerIP = '10.10.10.10'

# ---- 模板 ---------------------------------------------------------
$TemplateName = 'k8s-template'
$TemplateCpu = 2
$TemplateMemMB = 2048
$TemplateDiskGB = 20

# ---- 节点规格(从模板克隆后再改 .vmx)------------------------------
$NodeCpu = 2
$NodeMemMB = 4096
$NodeDiskGB = 20

# ---- 操作系统 -----------------------------------------------------
$UbuntuVersion = '26.04'
$IsoMirror = 'https://mirrors.ustc.edu.cn/ubuntu-releases'

# ---- k8s ----------------------------------------------------------
$K8sMinor = '1.34'            # 小版本,决定 apt 仓库用哪个分支
$NetworkPlugin = 'calico'     # calico / flannel / cilium
$PodCidr = '10.244.0.0/16'
$ServiceCidr = '10.96.0.0/12'
$ClusterName = 'devops-k8s'

# ---- 账号 ---------------------------------------------------------
$SshUser = 'vagrant'
$VagrantPassword = 'vagrant'

# ---- 路径 ---------------------------------------------------------
# VM 放哪儿。20G 一台的盘 + 模板,三个节点差不多 80G,别放 C 盘。
$VmRoot = 'D:\vmware-k8s'
$PackerVersion = ''            # 留空 = 自动取最新版
# 虚拟硬件版本号,**不是** Workstation 的产品版本(17.6 / 25.0.1 那种)。
# 这两个号完全是两套。填错的话 VMware 会拒绝打开 VM,弹
# "created by a VMware product that is incompatible"。
# 21 = packer 插件的默认值,兼容性最好。
$VmwareHardwareVersion = '21'

# ==================================================================
#  路径与库
# ==================================================================

$WorkDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $WorkDir
$CacheDir = Join-Path $WorkDir '.cache'
$StateDir = Join-Path $CacheDir 'state'
$HttpDir = Join-Path $CacheDir 'http'
$KnownHosts = Join-Path $CacheDir 'known_hosts'
$SshKey = Join-Path $env:USERPROFILE '.ssh\id_rsa'

. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\packer.ps1')
. (Join-Path $WorkDir 'lib\vmnet.ps1')
. (Join-Path $WorkDir 'lib\clone.ps1')
. (Join-Path $WorkDir 'lib\k8s.ps1')

foreach ($d in @($CacheDir, $StateDir, $HttpDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==================================================================
#  节点定义
# ==================================================================

function New-ClusterNodes {
    $nodes = @()
    $nodes += New-NodeDefinition -Name 'k8s-master' -Address $MasterIP `
        -Mac (New-NodeMac -Address $MasterIP) -Role 'master' `
        -Cpus $NodeCpu -MemoryMB $NodeMemMB -DiskGB $NodeDiskGB
    $i = 1
    foreach ($ip in $WorkerIPs) {
        $nodes += New-NodeDefinition -Name ("k8s-worker{0}" -f $i) -Address $ip `
            -Mac (New-NodeMac -Address $ip) -Role 'worker' `
            -Cpus $NodeCpu -MemoryMB $NodeMemMB -DiskGB $NodeDiskGB
        $i++
    }
    return $nodes
}

$Nodes = New-ClusterNodes

# ==================================================================
#  阶段
# ==================================================================

function Invoke-Preflight {
    Write-Step '环境体检'

    # 管理员权限只有"写静态 DHCP 租约 + 重启 VMnetDHCP 服务"这一步需要
    # —— 那是全局配置,普通权限改不了。其余阶段(下载、打包、克隆、装 k8s)
    # 都不碰系统配置,不该被这个挡住。
    $needsAdmin = ($Stage -eq 'all' -or $Stage -eq 'network') -and (-not $Check)
    if ($needsAdmin -and -not (Test-Administrator)) {
        Stop-WithError @'
需要管理员权限。写静态 DHCP 租约要改 C:\ProgramData\VMware\vmnetdhcp.conf
并重启 VMnetDHCP 服务,这两件事普通权限做不了。
请用管理员身份重新运行(右键 build.cmd -> 以管理员身份运行)。
只做体检的话加 -Check,不需要管理员。
'@
    }
    if ($needsAdmin) { Write-Ok '管理员权限 OK' }
    else { Write-Info '这一步不需要管理员权限' }

    $vmDir = Resolve-VmwareInstallDir
    if (-not $vmDir) {
        Stop-WithError @'
找不到 VMware Workstation 的安装目录(需要里面有 vmrun.exe)。
这台机器上注册表里留着 Workstation 25.0.1 的卸载项,但程序目录已经没了
——如果确实没装,先去装;装过的话可能是被清理掉了。
'@
    }
    Write-Ok "VMware Workstation -> $vmDir"
    $vmrun = Join-Path $vmDir 'vmrun.exe'
    Confirm-Tool -Path $vmrun -What 'vmrun'

    $ssh = Get-SshExe
    if (-not $ssh) { Stop-WithError '找不到 ssh.exe' }
    Write-Ok "ssh -> $ssh"
    $scp = Get-ScpExe
    if (-not $scp) { Stop-WithError '找不到 scp.exe' }
    Write-Ok "scp -> $scp"

    if (-not (Test-Path -LiteralPath $SshKey)) {
        Stop-WithError "找不到 SSH 私钥 $SshKey`n    这把钥匙的公钥要写进模板,节点上才能免密登录。"
    }
    Write-Ok "SSH 私钥 -> $SshKey"

    # 磁盘:模板 + 3 个节点
    # 盘符从 $VmRoot 的路径里取,而不是去找那个目录 —— 目录这会儿
    # 还不存在,按"存在才算"会退回去查 C 盘,而 VM 明明是要放 D 盘的。
    $needGB = $TemplateDiskGB + ($Nodes.Count * $NodeDiskGB)
    $root = [System.IO.Path]::GetPathRoot($VmRoot)
    $rootDrive = Get-PSDrive -Name $root.TrimEnd(':\') -ErrorAction SilentlyContinue
    if (-not $rootDrive) {
        Write-Note "读不到 $root 的磁盘信息,跳过磁盘检查"
    }
    elseif ($rootDrive.Free / 1GB -lt ($needGB + 10)) {
        Write-Note ("{0} 只剩 {1:N1} GB,模板+节点大约需要 {2} GB(放在 {3})" -f `
                $rootDrive.Name, ($rootDrive.Free / 1GB), $needGB, $VmRoot)
    }
    else {
        Write-Ok ("{0} 余量 {1:N1} GB,需要约 {2} GB" -f $rootDrive.Name, ($rootDrive.Free / 1GB), $needGB)
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.HypervisorPresent) {
        Write-Note 'Hyper-V/VBS 处于开启状态,VMware 会走 WHP 后端,性能明显不如原生。'
    }

    # 网络
    $vmnet = Resolve-VmnetForSubnet -Subnet $NetSubnet
    Write-Ok ("{0} ({1}) 落在 {2},网关 {3}" -f $vmnet.Name, $vmnet.Ip, $NetSubnet, $vmnet.Gateway)
    if ($vmnet.Ip -notlike '10.10.10.*') {
        Write-Note ("宿主机在 {0} 上的地址是 {1},与目标网段 {2} 不一致" -f $vmnet.Name, $vmnet.Ip, $NetSubnet)
    }

    # 节点与 IP 的对应
    Write-Info '节点规划:'
    foreach ($n in $Nodes) {
        Write-Host ("        {0,-14} {1,-14} {2,-18} {3}C/{4}MB/{5}G  {6}" -f `
                $n.Name, $n.Address, $n.Mac, $n.Cpus, $n.MemoryMB, $n.DiskGB, $n.Role)
    }
    return $vmnet
}

function Invoke-InstallPacker {
    Write-Step '准备 Packer'
    $exe = Install-Packer -CacheDir $CacheDir -Version $PackerVersion
    Write-Utf8Text (Join-Path $StateDir 'packer.exe') $exe
    return $exe
}

function Invoke-PrepareIso {
    Write-Step "准备 Ubuntu $UbuntuVersion ISO"
    $iso = Resolve-UbuntuIso -Version $UbuntuVersion -MirrorBase $IsoMirror -CacheDir $CacheDir
    Write-Utf8Text (Join-Path $StateDir 'iso.json') ($iso | ConvertTo-Json)
    return $iso
}

function Get-PasswordHash {
    <#
      .SYNOPSIS
        生成 subiquity 要的 SHA-512 crypt 哈希。
      .DESCRIPTION
        subiquity 的 identity.password 要的是哈希值,不是明文。
        用 openssl passwd -6 生成;没有 openssl 时退回内置的
        默认密码哈希(只对默认密码 'vagrant' 有效)。
    #>
    param([string]$Password = 'vagrant')
    foreach ($p in @(
            'D:\Program Files\Git\usr\bin\openssl.exe',
            'C:\Program Files\Git\usr\bin\openssl.exe',
            'D:\Program Files\Git\mingw64\bin\openssl.exe')) {
        if (Test-Path -LiteralPath $p) {
            $h = (& $p passwd -6 $Password 2>$null | Select-Object -First 1)
            if ($h -and $h -match '^\$6\$') { return $h.Trim() }
        }
    }
    if ($Password -eq 'vagrant') {
        Write-Note '找不到 openssl,退回内置的默认密码哈希'
        return '$6$cE0h.ADjjQi0kBs1$sfpmjMsQZPo7BuVYekbyU3SOEXCu6u/QOZJqDbfV1cfo2y8bDz3hnSct8zk7QHwa.oamyfQAyW4V6iOA3eP9q/'
    }
    Stop-WithError "改过密码就必须要 openssl 来算哈希,找不到 openssl.exe"
}

function Invoke-BuildTemplate {
    param(
        [Parameter(Mandatory)][string]$PackerExe,
        [Parameter(Mandatory)][string]$VmwareDir
    )

    # 注意:PowerShell 不会像 C 那样自动拼接相邻的字符串字面量。
    # 'a\'"b" 会被当成**两个参数**,Join-Path 于是收到三个,报
    # "A positional parameter cannot be found that accepts argument 'b'"。
    $templateVmx = Join-Path $WorkDir ('packer\output\ubuntu-template\' + $TemplateName + '.vmx')
    if ((Test-Path -LiteralPath $templateVmx) -and (-not $ForceTemplate)) {
        Write-Ok "模板已存在,复用: $templateVmx"
        return $templateVmx
    }

    Write-Step "用 Packer 构建模板($TemplateCpu C / $TemplateMemMB MB / $TemplateDiskGB G)"

    $iso = Read-Utf8Text (Join-Path $StateDir 'iso.json') | ConvertFrom-Json

    # --- 生成 autoinstall 的 user-data ---
    # 具体怎么读怎么写见 lib\packer.ps1 的 New-AutoinstallUserData,
    # 那里有踩过的坑的完整说明(编码搞错会让 subiquity 静默丢掉
    # 整段 late-commands)。
    $pub = Read-Utf8Text "$SshKey.pub"
    $hash = Get-PasswordHash -Password $VagrantPassword
    # 变量名不能叫 $httpDir —— PowerShell 的变量名**大小写不敏感**,
    # $httpDir 和上面那个 $HttpDir 是同一个变量!这一行等于把 $HttpDir
    # 又拼了一层 "http",后面 pkrvars 里的 http_dir 就变成了
    # .cache/http/http/http,packer 根本找不到 user-data。
    $userDataDir = Join-Path $HttpDir 'http'
    $null = New-AutoinstallUserData `
        -TemplatePath (Join-Path $WorkDir 'packer\http\user-data') `
        -OutPath (Join-Path $userDataDir 'user-data') `
        -MetaDataPath (Join-Path $WorkDir 'packer\http\meta-data') `
        -PublicKey $pub `
        -PasswordHash $hash `
        -Hostname $TemplateName
    Write-Ok 'autoinstall user-data 已生成'

    # --- 生成 pkrvars ---
    # 用有序字典拼,不要在 here-string 里手写插值:here-string 里的
    # $((...)/guest) 会被当成除法,而嵌套的引号和反斜杠也难读。
    $varsMap = [ordered]@{
        # 用**本地文件**,不让 packer 自己再去下载一遍。
        # 镜像站对 packer 追加的 "?checksum=..." 查询串直接返 403,
        # 于是 packer 报 "error downloading ISO: [bad response code: 403]"
        # —— 其实 ISO 早就下好、校验过了,白折腾。
        # go-getter 认 file:// 开头的本地路径。
        iso_url              = (ConvertTo-PackerFileUrl $iso.Path)
        iso_checksum         = $iso.Checksum
        vm_name              = $TemplateName
        cpus                 = $TemplateCpu
        memory_mb            = $TemplateMemMB
        disk_gb              = $TemplateDiskGB
        vmware_hardware_version = $VmwareHardwareVersion
        ssh_username         = $SshUser
        ssh_password         = $VagrantPassword
        ssh_private_key_file = ($SshKey -replace '\\', '/')
        guest_scripts_dir    = (($WorkDir -replace '\\', '/') + '/guest')
        http_dir             = ($userDataDir -replace '\\', '/')
    }
    $vars = ($varsMap.GetEnumerator() | ForEach-Object { '{0,-22} = "{1}"' -f $_.Key, $_.Value }) -join "`n"
    $pkrvars = Join-Path $WorkDir 'packer\ubuntu-template.pkrvars.hcl'
    Write-Utf8Text $pkrvars $vars
    Write-Ok "变量文件: $pkrvars"

    # --- build ---
    # 注意 -var-file=... 这种写法:参数值必须带引号。不带引号时
    # PowerShell 5.1 不会展开 $var(见 tests\test-encoding.ps1),
    # 原样把字面量传给 packer,packer 会报
    # "Could not guess format of $var"。
    Push-Location (Join-Path $WorkDir 'packer')
    $packerOut = $null
    $code = 1
    try {
        # 原生命令往 stderr 写东西,在 $ErrorActionPreference='Stop' 下
        # 会变成**终止性错误** —— packer 的报错正文就这么被吃掉了,
        # 只剩一句"退出码 1",完全指不到真因(第一次跑就是这样:
        # 真实原因是镜像站 403,而日志里啥都没有)。这里临时放宽,
        # 把输出收下来,存一份日志,再打印出来。
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $packerOut = & $PackerExe build '-var-file=ubuntu-template.pkrvars.hcl' '-color=false' '.' 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prev
        }
    }
    finally {
        Pop-Location
    }
    if ($packerOut) {
        $text = ($packerOut | ForEach-Object { $_.ToString() }) -join "`n"
        Write-Utf8Text (Join-Path $CacheDir 'packer-build.log') $text
        $packerOut | ForEach-Object { Write-Host "  $_" }
    }
    if ($code -ne 0) {
        Stop-WithError "packer build 失败(退出码 $code),完整日志见 .cache\packer-build.log"
    }
    if (-not (Test-Path -LiteralPath $templateVmx)) {
        Stop-WithError "packer 说成功了,但没找到 $templateVmx"
    }
    Write-Ok "模板构建完成: $templateVmx"
    return $templateVmx
}

function Invoke-SetupNetwork {
    param([Parameter(Mandatory)][object]$Vmnet)

    Write-Step "配置静态 DHCP 租约(网段 $($Vmnet.Subnet))"
    $leases = foreach ($n in $Nodes) {
        [pscustomobject]@{ Name = $n.Name; Mac = $n.Mac; Address = $n.Address }
    }
    $netmask = '255.255.255.0'
    $subnetBase = ($NetSubnet -split '/')[0]
    Set-StaticDhcpLease -Subnet $subnetBase -Netmask $netmask -Lease @($leases)
    Restart-VmwareDhcpService
    Write-Ok '三个节点的地址已钉死'
}

function Invoke-CloneNodes {
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$TemplateVmx,
        [Parameter(Mandatory)][object]$Vmnet
    )
    Write-Step '全克隆出 k8s 节点'
    foreach ($n in $Nodes) {
        $null = Copy-TemplateToNode -VmrunExe $VmrunExe -TemplateVmx $TemplateVmx `
            -VmRoot $VmRoot -Node $n -Vnet $Vmnet.Name
    }
}

function Invoke-BootNodes {
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$SshExe
    )
    Write-Step '启动节点并等待就绪'
    foreach ($n in $Nodes) {
        Start-NodeVm -VmrunExe $VmrunExe -Node $n
    }
    $sshArgs = New-SshArgs -SshExe $SshExe -KeyFile $SshKey -KnownHosts $KnownHosts
    foreach ($n in $Nodes) {
        $ok = Wait-NodeReady -SshExe $SshExe -SshArgs $sshArgs -User $SshUser -Host_ $n.Address -TimeoutSec 900
        if (-not $ok) {
            Stop-WithError "节点 $($n.Name) 没起来"
        }
    }
}

function Invoke-DestroyNodes {
    param([Parameter(Mandatory)][string]$VmrunExe)
    Write-Step '删除节点'
    foreach ($n in $Nodes) {
        $dir = Join-Path $VmRoot $n.Name
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Ok "已删除 $dir"
        }
    }
}

# ==================================================================
#  主流程
# ==================================================================

Write-Host ''
Write-Host '=== vmware-k8s ===' -ForegroundColor White
Write-Host "阶段: $Stage$(if ($Check) { '(仅体检)' })"

$vmnet = Invoke-Preflight

if ($Check) {
    Write-Step '体检结束,没有改动任何东西'
    Write-Host '去掉 -Check 就会开始真的干活。'
    return
}

$vmrun = Join-Path (Resolve-VmwareInstallDir) 'vmrun.exe'
$sshExe = Get-SshExe
$scpExe = Get-ScpExe
$vmwareDir = Resolve-VmwareInstallDir

$run = {
    param($s)
    return ($Stage -eq 'all' -or $Stage -eq $s)
}

if (& $run 'packer') {
    $packerExe = Invoke-InstallPacker
}
else {
    $packerExe = Read-Utf8Text (Join-Path $StateDir 'packer.exe')
    $packerExe = $packerExe.Trim()
}

if (& $run 'iso') {
    $iso = Invoke-PrepareIso
}

if (& $run 'template') {
    $templateVmx = Invoke-BuildTemplate -PackerExe $packerExe -VmwareDir $vmwareDir
}
else {
    $templateVmx = Join-Path $WorkDir ('packer\output\ubuntu-template\' + $TemplateName + '.vmx')
}

if (& $run 'network') {
    Invoke-SetupNetwork -Vmnet $vmnet
}

if (& $run 'clone') {
    Invoke-CloneNodes -VmrunExe $vmrun -TemplateVmx $templateVmx -Vmnet $vmnet
}

if (& $run 'boot') {
    Invoke-BootNodes -VmrunExe $vmrun -SshExe $sshExe
}

if (& $run 'k8s') {
    $ok = Invoke-K8sStage -SshExe $sshExe -ScpExe $scpExe -KeyFile $SshKey -KnownHosts $KnownHosts `
        -User $SshUser -RepoRoot $RepoRoot -Nodes $Nodes -K8sMinor $K8sMinor `
        -NetworkPlugin $NetworkPlugin -PodCidr $PodCidr -ServiceCidr $ServiceCidr `
        -LoadBalancer $LoadBalancerIP -SkipCni:$SkipCni
}

if ($Stage -eq 'destroy') {
    Invoke-DestroyNodes -VmrunExe $vmrun
}

Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Green
Write-Host "master : $MasterIP"
Write-Host ("worker : {0}" -f ($WorkerIPs -join ', '))
Write-Host "查看集群: ssh -i `"$SshKey`" $SshUser@$MasterIP 'kubectl get nodes -o wide'"
