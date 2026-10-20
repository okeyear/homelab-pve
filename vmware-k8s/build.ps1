<#
.SYNOPSIS
    在 Windows 上用 Packer + VMware Workstation 搭一个本地 k8s 集群。

.DESCRIPTION
    分三层克隆,每层只干一件事:

      1. preflight  体检 VMware / SSH / 磁盘,并把网络方案算出来
      2. packer     下载并校验 Packer(装在仓库内的 .cache,不污染系统)
      3. iso        从镜像站下 Ubuntu LTS 的 live-server ISO,校验 SHA256
      4. template   packer build 出一张**最小化**模板盘(2C/2G/20G)
      5. base       从模板克隆出 k8s-base,装 cloud-init / 换源 / 基础包 /
                    containerd / k8s 组件,打好封存标记,然后关机
      6. clone      从 k8s-base 克隆出 1 master + 2 worker
      7. boot       启动三个节点,等它们各自配好静态 IP、ssh 可用
      8. k8s        复用仓库的 setup-k8s/scripts/*.sh 装集群

    分层的好处:
      - 三个节点从同一张盘克隆,天然一致
      - 装 k8s 组件这种重活失败,只要重跑 base 阶段(几分钟),
        不用重装系统(20 分钟)
      - 模板越薄,packer 阶段的失败面越小

    全流程**不需要管理员权限**:节点 IP 由 guest 自己写 netplan 配好,
    宿主机不用改 VMware 的 DHCP 配置、不用重启服务。

    集群内部的组件安装全部走仓库里现成的脚本,这里一行都不改。

.EXAMPLE
    .\build.cmd                       # 全流程
    .\build.cmd -Stage preflight      # 只体检,不动任何东西
    .\build.cmd -Stage template       # 只做模板
    .\build.cmd -Stage k8s            # 只跑装集群那一步
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'preflight', 'packer', 'iso', 'template', 'base', 'clone', 'boot', 'k8s', 'destroy')]
    [string]$Stage = 'all',

    # 只做环境体检并打印将要执行的计划,不下载、不克隆、不改任何配置
    [switch]$Check,

    # 强制重新 build 模板(默认:模板已存在就复用)
    [switch]$ForceTemplate,

    # 跳过 CNI 安装(默认会装,main.sh 漏了这一步)
    [switch]$SkipCni,

    # 弹 VMware 窗口跑模板构建(排障用)。
    # 默认不弹 —— 图形界面接管由 vmrun 启动的 VM 之后,关机时会把
    # 整个 output 目录当临时产物清掉(实测 20G 的 disk.vmdk 一起没了)。
    [switch]$ShowWindow
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ==================================================================
#  变量区 —— 要改的东西都在这里
# ==================================================================

# ---- 网络 ---------------------------------------------------------
# VMware Workstation 的网段。宿主机上 vmnet8 已经是 10.10.10.0/24
# (NAT),这几个节点就挂在它上面:宿主机能直连,节点也能出网。
$NetSubnet = '10.10.10.0/24'

# ---- 固定地址 vs DHCP 池 --------------------------------------------
#
# VMware 的 DHCP 池是 10.10.10.10 - 10.10.10.200(vmnetdhcp.conf 里的
# range 行)。**凡是写死成静态 IP 的地址,都必须落在池子外面** ——
# 否则 DHCP 随时可能把这个地址派给别的机器,IP 就撞了,表现是
# "偶尔 SSH 上的是另一台机器"。
#
# 所以:
#   模板 / k8s-base   10.10.10.9    (池外)
#   三个节点          .201 / .202 / .203  (池外)
#   apiserver SAN     10.10.10.250  (池外,只是个证书里的额外名字)
#
# k8s-base 自己用 DHCP(装 base 的过程中还没到 clone-prep 那一步),
# 它拿到的地址在池子中间,不和上面任何一个冲突。
$TemplateIP = '10.10.10.9'
$TemplateCidr = "$TemplateIP/24"
$TemplateGateway = '10.10.10.2'
$TemplateDnsPrimary = '10.10.10.2'
$TemplateDnsSecondary = '223.5.5.5'

$MasterIP = '10.10.10.201'
$WorkerIPs = @('10.10.10.202', '10.10.10.203')
# apiserver 证书里的额外 SAN,不是真的 VIP
$LoadBalancerIP = '10.10.10.250'

# ---- 模板 ---------------------------------------------------------
$TemplateName = 'k8s-template'
$TemplateCpu = 2
$TemplateMemMB = 2048
$TemplateDiskGB = 20

# ---- 中间产物:k8s 基础镜像 ----------------------------------------
# 分两层克隆:
#
#   packer 出的最小化模板  ->  k8s-base  ->  三个 k8s 节点
#                            (装好 cloud-init / 换源 / 基础包 /
#                             containerd / k8s 组件)
#
# k8s-base 是"半成品",但重活都在它身上做完了:失败只要重跑 base
# 阶段(几分钟),不用重装系统(20 分钟)。三个节点从它克隆,天然一致。
$BaseName = 'k8s-base'
$BaseCpu = 2
$BaseMemMB = 2048
$BaseDiskGB = 20
# base 机器自己的 MAC。它在装 base 的过程中走 DHCP,IP 由
# vmrun getGuestIPAddress 问出来,不用预先写死。
$BaseMac = '00:50:56:0A:0A:09'

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

# ---- 排障开关 -------------------------------------------------------
# true  = 模板构建用 vmrun nogui 启动,不弹 VMware 窗口(默认)
# false = 弹窗口,装机出错时屏幕上直接写着原因
# 临时切成 false:build.cmd -Stage template -ShowWindow
$PackerHeadless = (-not $ShowWindow)

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
. (Join-Path $WorkDir 'lib\base.ps1')
. (Join-Path $WorkDir 'lib\k8s.ps1')

foreach ($d in @($CacheDir, $StateDir, $HttpDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==================================================================
#  节点定义
# ==================================================================

function New-RandomVmwareMac {
    <#
      .SYNOPSIS
        生成一个随机的 VMware MAC。

      .DESCRIPTION
        每轮 build 必须换一个 MAC。理由见 packer\ubuntu-template.pkr.hcl
        里 variable "mac_address" 的说明:packer 找 guest IP 靠读
        VMware 的 DHCP 租约文件,同一个 MAC 的旧租约(30 分钟有效期)
        会让它去试一堆已经没人用的地址。

        模板的 MAC 反正会被 clone 那一步覆盖成每个节点自己的,这里
        随机选不影响最终结果。
    #>
    $b = New-Object 'System.Byte[]' 3
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    '{0}:{1}:{2}:{3}:{4}:{5}' -f '00', '50', '56', `
        $b[0].ToString('X2'), $b[1].ToString('X2'), $b[2].ToString('X2')
}

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

# 中间产物 k8s-base。它的地址留空 —— 装机过程中走 DHCP,
# 装完之后 clone-prep 才会按 MAC 给它配静态 IP(10.10.10.9)。
$BaseNode = New-NodeDefinition -Name $BaseName -Address '' -Mac $BaseMac -Role 'base' `
    -Cpus $BaseCpu -MemoryMB $BaseMemMB -DiskGB $BaseDiskGB

$Nodes = New-ClusterNodes

# ==================================================================
#  阶段
# ==================================================================

function Invoke-Preflight {
    Write-Step '环境体检'

    # 全流程**不需要管理员权限**。
    #
    # 早先的方案要在宿主机上写静态 DHCP 租约(改
    # C:\ProgramData\VMware\vmnetdhcp.conf 并重启 VMnetDHCP 服务),
    # 那两步普通权限做不了。现在节点的静态 IP 是 guest 自己写
    # netplan 配好的,宿主机这边一个字的全局配置都不用改。
    Write-Ok '这一步(以及后面每一步)都不需要管理员权限'

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

    # 静态地址不能落在 VMware 的 DHCP 池里 —— 池里的地址随时可能被
    # 派给别的机器,IP 一撞,表现是"偶尔 SSH 上的是另一台机器",
    # 极难查。这里直接把冲突的地址点名报出来。
    $dhcpRange = Get-VmnetDhcpRange -Subnet (($NetSubnet -split '/')[0])
    if (-not $dhcpRange) {
        Write-Note "读不到 VMware 的 DHCP 池范围(检查 $($script:VmDhcpConf)),跳过地址冲突检查"
    }
    else {
        Write-Ok ("VMware DHCP 池: {0} - {1}" -f $dhcpRange.Start, $dhcpRange.End)
        $staticAddrs = @($TemplateIP) + @($MasterIP) + @($WorkerIPs) + @($LoadBalancerIP)
        $clash = @($staticAddrs | Where-Object {
                Test-IpInRange -Address $_ -Start $dhcpRange.Start -End $dhcpRange.End
            })
        if ($clash.Count -gt 0) {
            Stop-WithError ("这些静态地址落在 VMware 的 DHCP 池({0} - {1})里,会撞 IP:`n    {2}`n    把它们挪到池子外面去(build.ps1 的变量区)。" -f `
                    $dhcpRange.Start, $dhcpRange.End, ($clash -join ', '))
        }
        Write-Ok '静态地址都在 DHCP 池外面'
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
    $templateVmx = Join-Path $WorkDir ('packer\output\' + $TemplateName + '.vmx')
    if ((Test-Path -LiteralPath $templateVmx) -and (-not $ForceTemplate)) {
        Write-Ok "模板已存在,复用: $templateVmx"
        return $templateVmx
    }

    Write-Step "用 Packer 构建模板($TemplateCpu C / $TemplateMemMB MB / $TemplateDiskGB G)"

    $iso = Read-Utf8Text (Join-Path $StateDir 'iso.json') | ConvertFrom-Json

    # --- 生成 autoinstall 的 user-data ---
    # 具体怎么读怎么写见 lib\packer.ps1 的 New-AutoinstallUserData,
    # 那里有踩过的坑的完整说明(编码搞错会让 subiquity 静默丢掉
    # 整段配置)。
    #
    # 模板的 MAC 每轮换一个。这里必须**先生成、后面两处都用同一个**:
    # 一处写进 user-data 的 network 段(按接口名匹配,不依赖 MAC),
    # 一处写进 .vmx。写错一处,packer 找的地址和 guest 实际地址就对不上了。
    $templateMac = New-RandomVmwareMac
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
        -Hostname $TemplateName `
        -TemplateCidr $TemplateCidr `
        -Gateway $TemplateGateway `
        -DnsPrimary $TemplateDnsPrimary `
        -DnsSecondary $TemplateDnsSecondary
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
        http_dir             = ($userDataDir -replace '\\', '/')
        # 直接告诉 packer guest 在哪儿,不去猜 DHCP 租约。
        # 理由见 pkr.hcl 里 variable "ssh_host" 的说明。
        ssh_host             = $TemplateIP
        # 装系统要十几分钟,packer 会在这个地址上一直等目标系统起来。
        ssh_handshake_attempts = 1000
        headless             = $PackerHeadless
        # 每轮换一个随机 MAC,理由见 pkr.hcl 里 variable "mac_address"。
        mac_address          = $templateMac
    }
    # bool 要写成 true / false,**不能加引号** —— 加了引号 HCL 里就成了
    # 字符串,packer validate 会报 "Inappropriate value for attribute
    # 'headless': string required"。
    $vars = ($varsMap.GetEnumerator() | ForEach-Object {
            if ($_.Value -is [bool]) {
                '{0,-22} = {1}' -f $_.Key, $_.Value.ToString().ToLower()
            }
            else {
                '{0,-22} = "{1}"' -f $_.Key, $_.Value
            }
        }) -join "`n"
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
    # packer 的详细日志落到 .cache\packer-debug.log。
    #
    # packer 默认只把 DEBUG 日志写进临时文件(packer-logXXXX),进程一退出
    # 就删掉 —— 出问题的时候什么都看不到。指定 PACKER_LOG_PATH 之后
    # 日志会留在那儿,而且是**实时**写的,build 卡在哪一步一眼就能看出来。
    $debugLog = Join-Path $CacheDir 'packer-debug.log'
    $prevLog = $env:PACKER_LOG
    $prevLogPath = $env:PACKER_LOG_PATH
    $env:PACKER_LOG = '1'
    $env:PACKER_LOG_PATH = $debugLog
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
        if ($null -eq $prevLog) { Remove-Item Env:PACKER_LOG -ErrorAction SilentlyContinue }
        else { $env:PACKER_LOG = $prevLog }
        if ($null -eq $prevLogPath) { Remove-Item Env:PACKER_LOG_PATH -ErrorAction SilentlyContinue }
        else { $env:PACKER_LOG_PATH = $prevLogPath }
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

function Invoke-CloneNodes {
    <#
      .SYNOPSIS
        从 k8s-base 克隆出三个 k8s 节点。
      .DESCRIPTION
        注意克隆的**源是 k8s-base,不是 packer 出的模板**。base 那一层
        已经把 cloud-init / apt 源 / 基础包 / containerd / k8s 组件
        装好了,三个节点从它克隆,三台天然一致。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$BaseVmx,
        [Parameter(Mandatory)][object]$Vmnet
    )
    Write-Step '从 k8s-base 克隆出 k8s 节点'
    foreach ($n in $Nodes) {
        $null = Copy-TemplateToNode -VmrunExe $VmrunExe -TemplateVmx $BaseVmx `
            -VmRoot $VmRoot -Node $n -Vnet $Vmnet.Name `
            -Gateway $TemplateGateway -Dns "$($TemplateDnsPrimary),$($TemplateDnsSecondary)"
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
        $ok = Wait-NodeReady -SshExe $SshExe -SshArgs $sshArgs -User $SshUser `
            -Host_ $n.Address -KnownHosts $KnownHosts -TimeoutSec 900
        if (-not $ok) {
            Stop-WithError "节点 $($n.Name) 没起来"
        }
    }
}

function Invoke-DestroyNodes {
    param([Parameter(Mandatory)][string]$VmrunExe)
    Write-Step '删除节点'
    # k8s-base 也要删 —— 它是中间产物,重跑 base 阶段会重新克隆一份。
    foreach ($n in @($Nodes) + @($BaseNode)) {
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
    $templateVmx = Join-Path $WorkDir ('packer\output\' + $TemplateName + '.vmx')
}

# k8s-base 的位置:和节点一样,放在 $VmRoot 底下,vmx 名字跟目录同名。
$baseVmx = Join-Path $VmRoot ($BaseName + '\' + $BaseName + '.vmx')

if (& $run 'base') {
    $baseVmx = Invoke-BuildBase -VmrunExe $vmrun -TemplateVmx $templateVmx `
        -SshExe $sshExe -ScpExe $scpExe -KeyFile $SshKey -KnownHosts $KnownHosts `
        -User $SshUser -Password $VagrantPassword -RepoRoot $RepoRoot -Base $BaseNode `
        -Vnet $vmnet.Name -K8sMinor $K8sMinor
}

if (& $run 'clone') {
    Invoke-CloneNodes -VmrunExe $vmrun -BaseVmx $baseVmx -Vmnet $vmnet
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
