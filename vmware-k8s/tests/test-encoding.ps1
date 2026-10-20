# vmware-k8s — 编码回归测试
#
# 这里防的是一类很阴的 bug:PowerShell 5.1 的 Get-Content / Set-Content
# 默认用**系统 ANSI 代码页**(中文 Windows 上是 GBK),不是 UTF-8。
# 拿它们读写 UTF-8 文件,中文会变成乱码;更糟的是,某些多字节序列被
# GBK 误解之后会把行尾吃掉,下一行直接粘到上一行末尾。
#
# 实际踩到的后果:packer 的 autoinstall user-data 是 UTF-8,build.ps1
# 用 Get-Content -Raw 读出来再写回去,`late-commands:` 整行被粘到上一
# 行注释后面 —— YAML 照样能解析,但 subiquity 会**静默忽略**整段
# late-commands(免密 sudo、machine-id 重置、SSH host key 清理全都不
# 做)。模板看着装好了,克隆出来的节点全是废的,而且要等到真跑起来
# 才发现。
#
# 所以规矩定死:读用 Read-Utf8*,写用 Write-Utf8*(一律不带 BOM),
# 生产脚本里不允许再出现 Get-Content / Set-Content。
#
# 这个测试同时包含**否定测试**:它会先证明"用 ANSI 读确实会把
# late-commands 粘进注释",再断言"用 UTF-8 读不会"。这样这条断言
# 才不是摆设 —— 哪天有人把 Read-Utf8Text 改回 Get-Content,这里立刻红。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\packer.ps1')

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

$userData = Join-Path $WorkDir 'packer\http\user-data'

# ---------------------------------------------------------------- 1
Write-Host '=== user-data 本身是合法 UTF-8 ==='
$bytes = [System.IO.File]::ReadAllBytes($userData)
$strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $null = $strict.GetString($bytes)
    Assert-True $true '按严格 UTF-8 解码不报错'
}
catch {
    Assert-True $false "按严格 UTF-8 解码报错: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 2
Write-Host ''
Write-Host '=== Read-Utf8Text 保住结构 ==='
$good = Read-Utf8Text $userData
$goodLines = $good -split "`r?`n"
$standalone = @($goodLines | Where-Object { $_.Trim() -eq 'network:' })
Assert-True ($standalone.Count -eq 1) 'network: 单独成行(没有被粘到注释后面)'

# 读出来的内容必须和原始字节对得上
$reencoded = (New-Object System.Text.UTF8Encoding($false)).GetBytes($good)
Assert-True ($reencoded.Length -eq $bytes.Length) '重新编码后长度和原始字节一致'
$same = $true
for ($i = 0; $i -lt [Math]::Min($reencoded.Length, $bytes.Length); $i++) {
    if ($reencoded[$i] -ne $bytes[$i]) { $same = $false; break }
}
Assert-True $same '重新编码后字节和原始文件完全一致(没被改写)'

# ---------------------------------------------------------------- 3
Write-Host ''
Write-Host '=== 否定测试:ANSI 读法确实会坏(证明上面那条断言会咬) ==='
$ansi = [System.Text.Encoding]::GetEncoding(936)   # GBK
$ansiText = $ansi.GetString($bytes)
$ansiLines = $ansiText -split "`r?`n"
$ansiStandalone = @($ansiLines | Where-Object { $_.Trim() -eq 'network:' })
$glued = @($ansiLines | Where-Object { $_ -match 'network:' -and $_.Trim() -ne 'network:' })
Assert-True ($ansiStandalone.Count -eq 0) 'ANSI 读法下 network: 不再单独成行'
Assert-True ($glued.Count -ge 1) 'ANSI 读法下 network: 被粘进了注释行'
if ($glued.Count -ge 1) {
    Write-Host "       实际粘成这样: $($glued[0].Trim())" -ForegroundColor DarkGray
}
Assert-True ($good -ne $ansiText) '两种读法结果不同(文件里确实有非 ASCII 内容)'

# ---------------------------------------------------------------- 3b
Write-Host ''
Write-Host '=== 生产函数 New-AutoinstallUserData 的产物 ==='
# 这一条走的是 build.ps1 真正调用的那个函数 —— 不是"再模拟一遍"。
# 哪天有人把 Read-Utf8Text 改回 Get-Content,这里立刻红。
$gen = Join-Path $TestDir '_gen\user-data'
$null = New-AutoinstallUserData `
    -TemplatePath $userData `
    -OutPath $gen `
    -MetaDataPath (Join-Path $WorkDir 'packer\http\meta-data') `
    -PublicKey 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQtest@example' `
    -PasswordHash '$6$abc$defghijklmnopqrstuv' `
    -Hostname 'k8s-template' `
    -TemplateCidr '10.10.10.9/24' `
    -Gateway '10.10.10.2' `
    -DnsPrimary '10.10.10.2' `
    -DnsSecondary '223.5.5.5'

$genText = Read-Utf8Text $gen
$genLines = $genText -split "`r?`n"
Assert-True (@($genLines | Where-Object { $_.Trim() -eq 'network:' }).Count -eq 1) `
    '生成的 user-data 里 network: 单独成行'
Assert-True ($genText.Contains('k8s-template')) '占位符 __HOSTNAME__ 换掉了'
Assert-True (-not $genText.Contains('__HOSTNAME__')) '没有残留的占位符'
Assert-True ($genText.Contains('10.10.10.9/24')) '占位符 __TEMPLATE_CIDR__ 换成了实际地址'
Assert-True ($genText.Contains('via: 10.10.10.2')) '占位符 __GATEWAY__ 换成了实际网关'
Assert-True (-not $genText.Contains('__TEMPLATE_CIDR__')) '没有残留的地址占位符'
$genBytes = [System.IO.File]::ReadAllBytes($gen)
$genBom = ($genBytes.Length -ge 3 -and $genBytes[0] -eq 0xEF -and $genBytes[1] -eq 0xBB -and $genBytes[2] -eq 0xBF)
Assert-True (-not $genBom) '生成的 user-data 不带 BOM'
$genStrict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $null = $genStrict.GetString($genBytes)
    Assert-True $true '生成的 user-data 是合法 UTF-8'
}
catch {
    Assert-True $false "生成的 user-data 不是合法 UTF-8: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 4
Write-Host ''
Write-Host '=== 写出去的文件不带 BOM ==='
$tmp = Join-Path $TestDir '_enc.out'
Write-Utf8Text $tmp "#!/bin/bash`nkubeadm join 10.10.10.11:6444"
$out = [System.IO.File]::ReadAllBytes($tmp)
$hasBom = ($out.Length -ge 3 -and $out[0] -eq 0xEF -and $out[1] -eq 0xBB -and $out[2] -eq 0xBF)
Assert-True (-not $hasBom) 'Write-Utf8Text 不写 BOM'
$firstLine = (Read-Utf8Text $tmp) -split "`r?`n" | Select-Object -First 1
Assert-True ($firstLine -eq '#!/bin/bash') 'join 脚本第一行就是 #!/bin/bash(不会被 BOM 顶掉)'

# 跟 5.1 自带的 Set-Content -Encoding UTF8 比一下,确认差别是真的
$ref = Join-Path $TestDir '_enc_ref.out'
Set-Content -LiteralPath $ref -Value '#!/bin/bash' -Encoding UTF8
$refBytes = [System.IO.File]::ReadAllBytes($ref)
$refBom = ($refBytes.Length -ge 3 -and $refBytes[0] -eq 0xEF -and $refBytes[1] -eq 0xBB -and $refBytes[2] -eq 0xBF)
Assert-True $refBom '对照:5.1 的 Set-Content -Encoding UTF8 确实会加 BOM(所以不能用它)'

# ---------------------------------------------------------------- 5
Write-Host ''
Write-Host '=== .vmx 改写不破坏原有内容 ==='
$vmx = Join-Path $TestDir '_enc.vmx'
Write-Utf8Lines $vmx @(
    '.encoding = "UTF-8"',
    'displayName = "k8s-节点一"',
    'memsize = "2048"'
)
. (Join-Path $WorkDir 'lib\clone.ps1')
Set-VmxValue -VmxPath $vmx -Key 'memsize' -Value '4096'
$vmxText = Read-Utf8Text $vmx
$vmxLines = $vmxText -split "`r?`n"
Assert-True (@($vmxLines | Where-Object { $_ -eq 'displayName = "k8s-节点一"' }).Count -eq 1) '中文 displayName 改写后还在(没被读成乱码)'
Assert-True (@($vmxLines | Where-Object { $_ -eq 'memsize = "4096"' }).Count -eq 1) 'memsize 被改对'
$vmxBytes = [System.IO.File]::ReadAllBytes($vmx)
$vmxBom = ($vmxBytes.Length -ge 3 -and $vmxBytes[0] -eq 0xEF -and $vmxBytes[1] -eq 0xBB -and $vmxBytes[2] -eq 0xBF)
Assert-True (-not $vmxBom) '改写后的 .vmx 不带 BOM'

# ---------------------------------------------------------------- 6
Write-Host ''
Write-Host '=== 生产脚本里不许再出现 Get-Content / Set-Content / Out-File ==='
# 用 AST 找**真正的命令调用**,不靠文本匹配 —— 注释和字符串里提到
# Get-Content 不算,代码里真的调了才算。
# 唯一的例外:lib\packer.ps1 读 SHA256SUMS —— 那是纯 ASCII 的校验文件。
$banned = @('Get-Content', 'Set-Content', 'Out-File', 'Add-Content')
$prod = @(
    'build.ps1',
    'lib\common.ps1',
    'lib\packer.ps1',
    'lib\vmnet.ps1',
    'lib\clone.ps1',
    'lib\base.ps1',
    'lib\k8s.ps1'
)
foreach ($rel in $prod) {
    $path = Join-Path $WorkDir $rel
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errs)
    $cmds = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    $bad = @()
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($banned -notcontains $name) { continue }
        $extent = $c.Extent.Text
        if ($rel -eq 'lib\packer.ps1' -and $extent -match 'sums') { continue }
        $bad += "第 $($c.Extent.StartLineNumber) 行: $($extent.Trim())"
    }
    Assert-True ($bad.Count -eq 0) "$rel 里没有 ANSI 编解码的读写调用"
    foreach ($b in $bad) { Write-Host "       $b" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- 7
Write-Host ''
Write-Host '=== PowerShell 原生参数里的 $var 必须带引号 ==='
# 不带引号时 5.1 不会展开 $var,字面量 "$varsPath" 会被原样传给
# packer,packer 于是报 "Could not guess format of $varsPath"。
$probe = Join-Path $TestDir '_probe.txt'
Write-Utf8Text $probe 'x'
$unquoted = & 'C:\Windows\System32\cmd.exe' /c echo -var-file=$probe
$quoted = & 'C:\Windows\System32\cmd.exe' /c echo "-var-file=$probe"
Assert-True ($unquoted -eq '-var-file=$probe') '不加引号:变量不展开(原样传出)'
Assert-True ($quoted -eq "-var-file=$probe") '加引号:变量正确展开'

# ---------------------------------------------------------------- 清理
foreach ($f in @($tmp, $ref, $vmx, $probe)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
if (Test-Path -LiteralPath (Join-Path $TestDir '_gen')) {
    Remove-Item -LiteralPath (Join-Path $TestDir '_gen') -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
