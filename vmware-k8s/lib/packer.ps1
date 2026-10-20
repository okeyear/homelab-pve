# vmware-k8s — Packer 安装与 Ubuntu ISO 下载
#
# Packer 本机没有预装。这里按"下载官方 zip + 用官方 SHA256SUMS 校验 +
# 解压到仓库内的 .cache"的方式装,不动系统 PATH,也不需要管理员权限。

Set-StrictMode -Version Latest

function Select-Sha256Line {
    <#
      .SYNOPSIS
        从 SHA256SUMS 的内容里挑出某个文件对应的那一行。
      .DESCRIPTION
        两种格式都得认,少认一种就查不到校验和:

          <hash>  <filename>      HashiCorp 的 packer SHA256SUMS
          <hash> *<filename>      GNU coreutils 的二进制模式(iso 就是这种)

        之前只按 "\s+文件名" 匹配,遇到 Ubuntu 的 "*文件名" 一条都匹配不上,
        于是报"没有 ubuntu-26.04.1 的条目" —— 明明就在那儿。
    #>
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$FileName
    )
    $rx = "\s+\*?$([regex]::Escape($FileName))\s*$"
    return ($Lines | Where-Object { $_ -match $rx } | Select-Object -First 1)
}

function Get-LatestPackerVersion {
    <#
      .SYNOPSIS
        问 HashiCorp 的 release API 要最新版本号。
      .DESCRIPTION
        不用 GitHub releases:那要 token,而且在 CN 网络下经常连不上。
        releases.hashicorp.com 的 API 是公开的,返回 JSON。
    #>
    $api = 'https://api.releases.hashicorp.com/v1/releases/packer/latest'
    try {
        $j = Invoke-RestMethod -Uri $api -TimeoutSec 60 -UseBasicParsing
        return $j.version
    }
    catch {
        Write-Note "查询 packer 最新版本失败: $($_.Exception.Message)"
        return $null
    }
}

function Install-Packer {
    <#
      .SYNOPSIS
        确保 .cache\packer\packer.exe 存在且可用。
      .OUTPUTS
        packer.exe 的完整路径。
    #>
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [string]$Version = ''
    )

    $dest = Join-Path $CacheDir 'packer'
    $exe = Join-Path $dest 'packer.exe'
    if (Test-Path -LiteralPath $exe) {
        Write-Ok "packer 已就位: $exe"
        return $exe
    }

    if (-not $Version) { $Version = Get-LatestPackerVersion }
    if (-not $Version) {
        Stop-WithError '无法确定 packer 版本。请在 build.ps1 里设置 $PackerVersion 后重试。'
    }
    Write-Info "packer 最新版本: $Version"

    $file = "packer_${Version}_windows_amd64.zip"
    $base = "https://releases.hashicorp.com/packer/$Version"
    $zip = Join-Path $CacheDir $file
    $sums = Join-Path $CacheDir "packer_${Version}_SHA256SUMS"

    Invoke-Download -Uri "$base/$file" -OutFile $zip
    Invoke-Download -Uri "$base/packer_${Version}_SHA256SUMS" -OutFile $sums

    # SHA256SUMS 里的行形如 "<hash>  <file>"(也兼容 "*<file>" 的写法)
    $line = Select-Sha256Line -Lines (Get-Content -LiteralPath $sums) -FileName $file
    if (-not $line) {
        Stop-WithError "SHA256SUMS 里找不到 $file 的条目"
    }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    if (-not (Test-Sha256 -Path $zip -Expected $expected)) {
        Stop-WithError "packer 压缩包校验失败,拒绝解压"
    }
    Write-Ok "packer SHA256 校验通过"

    Expand-ZipTo -ZipPath $zip -DestDir $dest
    if (-not (Test-Path -LiteralPath $exe)) {
        Stop-WithError "解压后找不到 $exe"
    }
    $ver = (& $exe version) -join ' '
    Write-Ok "packer 安装完成: $ver"
    return $exe
}

function Resolve-UbuntuIso {
    <#
      .SYNOPSIS
        解析出 Ubuntu LTS 的 live-server ISO:URL + 校验文件。
      .DESCRIPTION
        镜像站把补丁版本放在同一个目录里(26.04 / 26.04.1 / 26.04.2 ...),
        写死文件名过几个月就下不到了。这里列目录、挑版本号最大的那个,
        再把同目录的 SHA256SUMS 一起下回来给 packer 校验。
    #>
    param(
        [Parameter(Mandatory)][string]$Version,      # 例如 26.04
        [Parameter(Mandatory)][string]$MirrorBase,   # 例如 https://mirrors.ustc.edu.cn/ubuntu-releases
        [Parameter(Mandatory)][string]$CacheDir
    )

    $dirUrl = "$MirrorBase/$Version/"
    $listing = $null
    foreach ($m in @($MirrorBase, 'https://mirror.nyist.edu.cn/ubuntu-releases')) {
        $u = "$m/$Version/"
        try {
            $listing = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 60).Content
            if ($listing) { $dirUrl = $u; break }
        }
        catch {
            Write-Note "镜像 $u 不可用: $($_.Exception.Message)"
        }
    }
    if (-not $listing) {
        Stop-WithError "所有镜像都列不出 $Version 的目录"
    }

    $pattern = "ubuntu-$([regex]::Escape($Version))(\.[0-9]+)*-live-server-amd64\.iso"
    $names = [regex]::Matches($listing, $pattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
    if (-not $names) {
        Stop-WithError "镜像 $dirUrl 里没有 ubuntu-$Version-live-server-amd64.iso"
    }

    # 挑版本号最大的那个。26.04.1 > 26.04 —— 用 [version] 比大小,
    # 不用字符串比,否则 '26.04.1' 会被 '26.04' 按字典序排在后面。
    $chosen = $names |
        Sort-Object -Property @{
            Expression = {
                $v = ($_ -replace '^ubuntu-([0-9.]+)-.*$', '$1')
                try { [version]$v } catch { [version]'0.0' }
            }
        } -Descending |
        Select-Object -First 1

    Write-Ok "ISO: $chosen  (来自 $dirUrl)"

    $isoPath = Join-Path $CacheDir $chosen
    $sumsPath = Join-Path $CacheDir 'SHA256SUMS'
    $isoUrl = "$dirUrl$chosen"

    if (-not (Test-Path -LiteralPath $isoPath)) {
        Write-Step "下载 Ubuntu $Version ISO (约 2.7 GB,断点续传已启用)"
        Invoke-Download -Uri $isoUrl -OutFile $isoPath
    }
    else {
        Write-Ok "ISO 已存在,跳过下载: $isoPath"
    }

    if (-not (Test-Path -LiteralPath $sumsPath)) {
        Invoke-Download -Uri "$dirUrl/SHA256SUMS" -OutFile $sumsPath
    }

    # 校验和不匹配就删掉重下——半截的 ISO 在 packer 里会表现为一个
    # 莫名其妙的光盘错误,不如直接重来。
    $line = Select-Sha256Line -Lines (Get-Content -LiteralPath $sumsPath) -FileName $chosen
    if (-not $line) {
        Stop-WithError "SHA256SUMS 里没有 $chosen 的条目,无法校验"
    }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    if (-not (Test-Sha256 -Path $isoPath -Expected $expected)) {
        Write-Note "ISO 校验失败,删除后重新下载一次"
        Remove-Item -LiteralPath $isoPath -Force
        Invoke-Download -Uri $isoUrl -OutFile $isoPath
        if (-not (Test-Sha256 -Path $isoPath -Expected $expected)) {
            Stop-WithError 'ISO 重新下载后仍然校验失败'
        }
    }
    Write-Ok 'ISO SHA256 校验通过'

    return [pscustomobject]@{
        Path     = $isoPath
        Url      = $isoUrl
        # 直接给哈希值,不让 packer 自己解析 SHA256SUMS。
        # 那个文件是 GNU 的 "<hash> *<file>" 格式,packer 的 file: 类型
        # 未必认得那个星号 —— 认不得就会报
        # "checksum file didn't contain expected hash",而哈希明明就在那儿。
        # 反正上面已经自己校验过一遍了,把结果直接喂给它最省事。
        Checksum = "sha256:$expected"
        SumsPath = $sumsPath
        FileName = $chosen
    }
}

function New-AutoinstallUserData {
    <#
      .SYNOPSIS
        把 packer/http/user-data 模板的占位符替换掉,写出最终文件。

      .DESCRIPTION
        这个函数是编码事故的高发点,单独拎出来就是为了能被测试直接调用。

        模板是 UTF-8。一旦用 Get-Content 读(5.1 默认 ANSI/GBK),中文会变
        乱码,某些多字节序列被误解后还会把行尾吃掉 —— `late-commands:`
        会被粘到上一行注释后面。YAML 照样能解析,但 subiquity 会**静默忽略**
        整段 late-commands:免密 sudo、machine-id 重置、SSH host key 清理
        全都不做。模板看着装好了,克隆出来的节点全是废的,而且要等到真跑
        起来才发现。

        所以读一律 Read-Utf8Text,写一律 Write-Utf8Text,一步都不许走 ANSI。
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$MetaDataPath = '',
        [Parameter(Mandatory)][string]$PublicKey,
        [Parameter(Mandatory)][string]$PasswordHash,
        [Parameter(Mandatory)][string]$Hostname,
        # 固定地址相关。模板装系统期间和装完之后都用这一个地址,
        # 宿主机那边直接用 packer 的 ssh_host 指过去。
        [Parameter(Mandatory)][string]$TemplateCidr,   # 10.10.10.9/24
        [Parameter(Mandatory)][string]$Gateway,        # 10.10.10.2
        [Parameter(Mandatory)][string]$DnsPrimary,     # 10.10.10.2
        [Parameter(Mandatory)][string]$DnsSecondary    # 223.5.5.5
    )

    $tpl = Read-Utf8Text $TemplatePath
    # 方法链不能跨行以 "." 开头 —— 那是 PowerShell 7 的写法,5.1 会报
    # "意外的标记 .Replace"。把括号打在行尾,点跟在后面才行。
    $out = ($tpl.Replace('__SSH_AUTHORIZED_KEY__', $PublicKey.Trim())).
        Replace('__PASSWORD_HASH__', $PasswordHash).
        Replace('__HOSTNAME__', $Hostname).
        Replace('__TEMPLATE_CIDR__', $TemplateCidr).
        Replace('__GATEWAY__', $Gateway).
        Replace('__DNS_PRIMARY__', $DnsPrimary).
        Replace('__DNS_SECONDARY__', $DnsSecondary)

    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-Utf8Text $OutPath $out

    if ($MetaDataPath -and (Test-Path -LiteralPath $MetaDataPath)) {
        Copy-Item -LiteralPath $MetaDataPath -Destination (Join-Path $dir 'meta-data') -Force
    }
    return $OutPath
}
