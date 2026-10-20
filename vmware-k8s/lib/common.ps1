# vmware-k8s — 共用函数库
#
# 只做"无状态的小工具",不做编排。所有需要跨阶段传递的东西都放在
# build.ps1 的变量区里,或者写进 $StateDir 下的文件。

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- 编码
#
# PowerShell 5.1 里 Get-Content / Set-Content 的默认编码是**系统 ANSI
# 代码页**(中文 Windows 上是 GBK),不是 UTF-8。拿它们读写 UTF-8 文件,
# 中文会变成乱码 —— 更糟的是,某些多字节序列被 GBK 误解后会把行尾
# 吃掉,下一行直接粘到注释后面。
#
# 实际踩过的坑:packer 的 autoinstall user-data 是 UTF-8,用
# Get-Content -Raw 读出来再写回去,`late-commands:` 整行被吞进上一行
# 的注释里,subiquity 就会**静默忽略** late-commands(免密 sudo、
# machine-id 重置、SSH host key 清理全都不做),模板看起来装好了,
# 实际上克隆出来的节点是废的。
#
# 所以规矩定死:读用 Read-Utf8*,写用 Write-Utf8*(一律不带 BOM)。

function Read-Utf8Text {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-Utf8Lines {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Utf8Lines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines
    )
    [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 路径

function ConvertTo-PackerFileUrl {
    <#
      .SYNOPSIS
        把本地路径转成 packer(底层是 go-getter)认的 file:// URL。
      .DESCRIPTION
        Windows 上要的是三斜杠形式:file:///C:/Users/...
        go-getter 把 file:// 交给本地文件读取器,于是 packer 直接用
        已经下好、校验过的 ISO,不会再自己去镜像站下一遍。
    #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $slashed = $full -replace '\\', '/'
    if (-not $slashed.StartsWith('/')) { $slashed = '/' + $slashed }
    return 'file://' + $slashed
}

# ---------------------------------------------------------------- 输出

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    [ok]   $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [info] $Message" -ForegroundColor Gray
}

function Write-Note {
    param([string]$Message)
    Write-Host "    [note] $Message" -ForegroundColor Yellow
}

# 故意不叫 Write-Error:那个是 cmdlet,名字会撞。
function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

# 终止当前流程。抛异常而不是 exit,这样调用方还能拿到退出码。
function Stop-WithError {
    param([string]$Message)
    Write-Fail $Message
    throw $Message
}

function Confirm-Tool {
    <#
      .SYNOPSIS
        确认一个外部工具可用,不可用就带着"怎么办"一起退出。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$What,
        [string]$Hint = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Stop-WithError "$What 不可用: $Path`n    $Hint"
    }
    Write-Ok "$What -> $Path"
    return $Path
}

# ---------------------------------------------------------------- 工具探测

function Resolve-VmwareInstallDir {
    <#
      .SYNOPSIS
        找到 VMware Workstation 的安装目录。
      .DESCRIPTION
        注册表里的 DisplayName 可能在程序已经被删掉之后还留着(这台机器
        上就出现过一次:注册表里有 Workstation 25.0.1,程序目录却没了)。
        所以先查目录,查不到再看注册表,查到的注册表路径也必须真的存在。
    #>
    $candidates = @(
        'D:\Program Files (x86)\VMware\VMware Workstation',
        'C:\Program Files (x86)\VMware\VMware Workstation',
        'C:\Program Files\VMware\VMware Workstation'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'vmrun.exe')) { return $c }
    }

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^VMware Workstation' -and $_.InstallLocation } |
            ForEach-Object {
                $p = $_.InstallLocation.TrimEnd('\')
                if (Test-Path -LiteralPath (Join-Path $p 'vmrun.exe')) { return $p }
            }
    }
    return $null
}

function Get-SshExe {
    # Windows 自带的 OpenSSH 优先;Git for Windows 的也能用。
    foreach ($p in @(
            'C:\Windows\System32\OpenSSH\ssh.exe',
            'D:\Program Files\Git\usr\bin\ssh.exe',
            'C:\Program Files\Git\usr\bin\ssh.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-ScpExe {
    foreach ($p in @(
            'C:\Windows\System32\OpenSSH\scp.exe',
            'D:\Program Files\Git\usr\bin\scp.exe',
            'C:\Program Files\Git\usr\bin\scp.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------- 下载

function Invoke-Download {
    <#
      .SYNOPSIS
        下载文件,支持断点续传。
      .DESCRIPTION
        用 System.Net.HttpWebRequest 而不是 Invoke-WebRequest:后者在
        PowerShell 5.1 上对大文件会先整个读进内存,而且不支持 Range。
        镜像站经常限速,断点续传是必需品不是加分项。
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 3600
    )

    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $have = 0
    if (Test-Path -LiteralPath $OutFile) {
        $have = (Get-Item -LiteralPath $OutFile).Length
    }

    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Timeout = 60000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = 'vmware-k8s/1.0'
    if ($have -gt 0) {
        $req.AddRange([long]$have)
        Write-Info "续传 $OutFile (已有 $have 字节)"
    }

    $resp = $null
    $out = $null
    try {
        $resp = $req.GetResponse()
        $total = $resp.ContentLength + $have
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Open($OutFile,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)

        $buf = New-Object byte[] 1048576
        $read = 0
        $done = $have
        $lastPct = -1
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $read)
            $done += $read
            if ($total -gt 0) {
                $pct = [int](100 * $done / $total)
                if ($pct -ge $lastPct + 10) {
                    $lastPct = $pct
                    Write-Host ("    [dl ] {0,3}%  {1:N0} / {2:N0} 字节" -f $pct, $done, $total) -NoNewline
                    Write-Host "`r" -NoNewline
                }
            }
        }
        $out.Close(); $out = $null
        Write-Host ''
        Write-Ok "下载完成: $OutFile ($([math]::Round($done / 1MB, 1)) MB)"
    }
    catch {
        if ($out) { $out.Close() }
        Stop-WithError "下载失败: $Uri`n    $($_.Exception.Message)"
    }
    finally {
        if ($resp) { $resp.Close() }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Sha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $actual = Get-FileSha256 -Path $Path
    if ($actual -eq $Expected.ToLowerInvariant()) { return $true }
    Write-Fail "SHA256 不匹配: $Path`n    期望 $Expected`n    实际 $actual"
    return $false
}

function Expand-ZipTo {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
}

# ---------------------------------------------------------------- 外部程序

function Invoke-Native {
    <#
      .SYNOPSIS
        跑一个外部程序,把 stdout/stderr 合并收下来,返回退出码和输出。

      .DESCRIPTION
        仓库里所有对外部程序的调用都**必须**走这个函数,不要直接
        `& $exe ...`。

        原因:PowerShell 5.1 里,原生命令往 **stderr** 写东西,在
        $ErrorActionPreference='Stop' 下会被变成**终止性错误** ——
        脚本当场退出,退出码和输出一个都拿不到。

        实际踩过两次:

          1. vmware-vdiskmanager 报 "One of the parameters supplied is
             invalid (0x3e80)"(其实只是盘已经是 20G、不用再扩),
             整个 base 阶段被带走,日志里只有半句英文报错。
          2. ssh 第一次连接一台新机器时会往 stderr 写
             "Warning: Permanently added '10.10.10.201' to the list of
             known hosts." —— 这句话**每个新节点都会出现**,
             照直写就会让 k8s 阶段在第一台节点上就死掉。

        所以:临时把 $ErrorActionPreference 放宽成 'Continue',
        stderr 的内容就只是流到输出里(2>&1 合并),退出码照样拿得到。
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{
        ExitCode = $code
        Output   = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    }
}

# ---------------------------------------------------------------- 远端命令

function Add-RemoteTimeout {
    <#
      .SYNOPSIS
        给一条远端命令套上 timeout,让它不可能永远挂着。

      .DESCRIPTION
        为什么必须有这个:远端命令**不会自己结束**的情况是真实存在的。
        2026-10-20 那次 kubeadm init 卡了 15 分钟没返回 —— 原因是
        containerd 一直重试拉不到的镜像(registry.k8s.io 跳到的
        europe-west3-docker.pkg.dev 在国内是 connection refused)。
        ssh 的连接是好的(远端进程还活着),所以宿主机这边等多久都没用,
        整个 build 就那么干耗着。

        做法是在**远端**套 timeout,而不是在宿主机上掐 ssh 进程 ——
        后者只能杀掉 ssh,远端那个进程还会继续跑,下次重跑又撞上。

        两种命令形态:

        1. 单个程序(可以带 VAR=VAL 前缀)
           timeout -k 30 900 env VAR=VAL prog args
           VAR=VAL 必须挪到 env 后面 —— 否则 timeout 会把
           "VAR=VAL" 当成要执行的程序名,直接报 "failed to run command"。

        2. 复合命令(带 && / || / ; / | / 反引号)
           timeout -k 30 900 bash -c '...'
           必须整体交给 bash -c,否则 timeout 只管得到第一条命令,
           保护是假的(后面的 && 还是能一直挂着)。
           包在单引号里,命令内部的单引号按 POSIX 规矩转义成 '\''。
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 0
    )
    if ($TimeoutSec -le 0) { return $Command }

    if ($Command -match '&&|\|\||;|\||`') {
        $escaped = $Command.Replace("'", "'\''")
        return "timeout -k 30 $TimeoutSec bash -c '$escaped'"
    }

    $m = [regex]::Match($Command, '^\s*((?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+)(.*)$')
    if ($m.Success) {
        $assign = $m.Groups[1].Value.TrimEnd()
        $rest = $m.Groups[2].Value
        return "timeout -k 30 $TimeoutSec env $assign $rest"
    }

    return "timeout -k 30 $TimeoutSec $Command"
}

# ---------------------------------------------------------------- 杂项

function Test-Administrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-IpBytes {
    # '10.10.10.11' -> [byte[]] 10,10,10,11
    param([Parameter(Mandatory)][string]$Address)
    $parts = $Address -split '\.'
    if ($parts.Count -ne 4) { throw "不是合法的 IPv4 地址: $Address" }
    [byte[]]@([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
}

function Format-Duration {
    param([timespan]$Span)
    '{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds
}
