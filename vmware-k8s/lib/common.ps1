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
