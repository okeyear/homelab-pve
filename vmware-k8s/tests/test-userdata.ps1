# vmware-k8s — autoinstall user-data 的结构检查
#
# 这里的每一条断言都对应一个**实跑踩出来的坑**:
#
#   * network 段必须是**固定地址**,不能是 DHCP
#     packer 找 guest IP 的唯一办法是读 VMware 的 DHCP 租约文件,按
#     MAC 挑出还没过期的条目,取**最早**的一条去连。而 live 环境和
#     装好的目标系统用的是两种不同的 DHCP client-id(networkd 的
#     ff:... vs dhclient 的 01:<mac>),于是两边拿到不同地址,packer
#     死死连着 live 环境那个地址,一路撞到 ssh_timeout 耗尽(40 分钟)。
#     写死固定地址就绕开了这一切 —— 官方文档写明 network 段
#     "is applied during installation as well as in the installed system"。
#
#   * 固定地址只能来自占位符,不能写死在文件里
#     同一个地址要同时出现在 user-data 的 network 段和 packer 的
#     ssh_host 里。两处各写一份,早晚会写歪 —— 写歪了的表现是
#     packer 连了 40 分钟连不上,而两边看起来都"有地址"。
#
#   * 网卡必须按 name 通配符匹配,不能写死 ens33
#     VMware 的网卡名在不同硬件版本 / 不同内核上是 ens33 / ens160 /
#     enp0s3 都可能,写死名字是最容易翻车的地方。
#
#   * packages 里必须有 sudo 和 open-vm-tools
#     ubuntu-minimal 不带 sudo,少了它 /etc/sudoers.d 目录都不存在,
#     base 阶段写免密 sudo 那步必然失败。没有 open-vm-tools 的话
#     vmrun getGuestIPAddress 拿不到地址,base 阶段没法等机器就绪。
#
#   * 刻意**不写** late-commands
#     之前写过,踩过两个坑:一是 curtin 压根没有 curt-installer 这个
#     子命令(正确的是 `curtin in-target -- <cmd>`),二是 late-commands
#     失败不重试、直接中止整场安装。
#
# 断言写在文件里没用,关键是"改坏了它会不会报红"。
# tests\test-negative.ps1 里的 M8 ~ M12 干的就是这件事:分别把上面
# 每一条改坏,要求这个测试**必须**报红。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-userdata.ps1
#
# 纯文本检查,不走网络(YAML 能不能解析在 test-bash-syntax.ps1 里查,
# 那条需要 pyyaml,可能要联网)。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
$userData = Join-Path $WorkDir 'packer\http\user-data'
$buildPs1 = Join-Path $WorkDir 'build.ps1'

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

# 必须显式按 UTF-8 读。Get-Content 在 5.1 上走系统 ANSI(GBK),
# 中文变乱码,某些多字节序列被误解后还会把行尾吃掉 ——
# `network:` 会被粘到上一行注释后面,YAML 照样能解析,
# 但 subiquity 会静默跳过整段(然后 packer 连 40 分钟连不上)。
$text = [System.IO.File]::ReadAllText($userData, [System.Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"

# 注释行单独剔掉再判断。
# 否则本文件顶部的说明(里面明明白白写着 curt-installer 这个错法)
# 会被自己当成"代码里出现了 curt-installer"而误报。
$codeLines = @($lines | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
$codeText = ($codeLines -join "`n")

# ---------------------------------------------------------------- 1
Write-Host '=== network 段存在,而且是固定地址 ==='
$netIdx = -1
for ($i = 0; $i -lt $codeLines.Count; $i++) {
    if ($codeLines[$i] -match '^\s{0,2}network\s*:\s*$') { $netIdx = $i; break }
}
Assert-True ($netIdx -ge 0) 'NO_NETWORK_SECTION: user-data 里有 network: 这一节'

# 收集 network 段里的内容(到下一个同级键为止)
$netBody = @()
if ($netIdx -ge 0) {
    $indent = ($codeLines[$netIdx] -replace '^(\s*).*', '$1').Length
    for ($i = $netIdx + 1; $i -lt $codeLines.Count; $i++) {
        $l = $codeLines[$i]
        if ($l -match '^\s*(\S.*)$' -and ($l -replace '^(\s*).*', '$1').Length -le $indent) { break }
        $netBody += $l
    }
}
$netText = ($netBody -join "`n")

Assert-True ($netText -match 'dhcp4\s*:\s*false') 'NO_STATIC_IP: network 段里 dhcp4 是 false(固定地址,不是 DHCP)'
Assert-True ($netText -match 'dhcp6\s*:\s*false') 'network 段里 dhcp6 是 false'

# ---------------------------------------------------------------- 2
Write-Host ''
Write-Host '=== 固定地址来自占位符,不是写死的 ==='
Assert-True ($text.Contains('__TEMPLATE_CIDR__')) 'user-data 保留了占位符 __TEMPLATE_CIDR__'
Assert-True ($text.Contains('__GATEWAY__')) 'user-data 保留了占位符 __GATEWAY__'
Assert-True ($text.Contains('__DNS_PRIMARY__')) 'user-data 保留了占位符 __DNS_PRIMARY__'
Assert-True ($text.Contains('__DNS_SECONDARY__')) 'user-data 保留了占位符 __DNS_SECONDARY__'

# user-data 里不许出现任何写死的 10.10.10.x 地址 —— 那个地址必须
# 只有一处来源(build.ps1 的 $TemplateIP),否则两处对不上,
# packer 会在一个没人听的地址上等 40 分钟。
$hardIp = @($codeLines | Where-Object { $_ -match '\b\d+\.\d+\.\d+\.\d+' })
Assert-True ($hardIp.Count -eq 0) 'NO_HARDCODED_IP: user-data 里没有写死的 IP 地址'
if ($hardIp.Count -gt 0) {
    $hardIp | ForEach-Object { Write-Host "       错的: $_" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- 3
Write-Host ''
Write-Host '=== 网卡按 name 通配符匹配,不写死接口名 ==='
Assert-True ($netText -match 'match\s*:') 'network 段里用了 match: 定位网卡'
Assert-True ($netText -match 'name\s*:\s*"?en\*"?') 'match 用的是 name 通配符 "en*"'
# 这些名字在不同机器 / 不同内核上都有可能,写死必翻车
foreach ($bad in @('ens33', 'ens160', 'enp0s3', 'eth0')) {
    Assert-True (-not ($netText -match ("\b" + $bad + "\b"))) ("NO_HARDCODED_IFNAME: network 段里没有写死的接口名 " + $bad)
}

# ---------------------------------------------------------------- 4
Write-Host ''
Write-Host '=== packages 里有 sudo 和 open-vm-tools ==='
$pkgIdx = -1
for ($i = 0; $i -lt $codeLines.Count; $i++) {
    if ($codeLines[$i] -match '^\s{0,2}packages\s*:\s*$') { $pkgIdx = $i; break }
}
$pkgs = @()
if ($pkgIdx -ge 0) {
    for ($i = $pkgIdx + 1; $i -lt $codeLines.Count; $i++) {
        $l = $codeLines[$i]
        if ($l -match '^\s*-\s+(.*)$') { $pkgs += $Matches[1].Trim(); continue }
        break
    }
}
Assert-True ($pkgs -contains 'sudo') 'NO_SUDO_PACKAGE: packages 里显式装了 sudo(ubuntu-minimal 不带它)'
Assert-True ($pkgs -contains 'open-vm-tools') 'NO_VMWARE_TOOLS: packages 里显式装了 open-vm-tools(vmrun 要靠它)'

# ---------------------------------------------------------------- 5
Write-Host ''
Write-Host '=== 刻意不写 late-commands ==='
Assert-True (-not ($codeText -match '(?m)^\s*late-commands\s*:')) 'NO_LATE_COMMANDS: user-data 里没有 late-commands 这一节'
Assert-True (-not $codeText.Contains('curtin-installer')) 'NO_CURTIN_INSTALLER: 代码里没有 curt-installer(这个子命令不存在)'
Assert-True (-not $codeText.Contains('--shell=sh')) 'NO_SHELL_SH: 代码里没有 --shell=sh(那是 curt-installer 的写法)'

# ---------------------------------------------------------------- 6
Write-Host ''
Write-Host '=== 占位符还在 ==='
foreach ($ph in @('__SSH_AUTHORIZED_KEY__', '__PASSWORD_HASH__', '__HOSTNAME__')) {
    Assert-True $text.Contains($ph) "user-data 保留了占位符 $ph"
}

# ---------------------------------------------------------------- 7
Write-Host ''
Write-Host '=== build.ps1 那边用的是同一个地址 ==='
# user-data 里的固定地址和 packer 的 ssh_host 必须是**同一个**。
# 两边各写一份,早晚会写歪 —— 写歪了 packer 会在一个没人听的
# 地址上白等 40 分钟,而两边看起来都"有地址"。
$build = [System.IO.File]::ReadAllText($buildPs1, [System.Text.Encoding]::UTF8)
Assert-True ($build -match 'ssh_host\s*=\s*\$TemplateIP') 'NO_SSH_HOST_MISMATCH: build.ps1 里 packer 的 ssh_host 用的是 $TemplateIP'
Assert-True ($build -match '-TemplateCidr\s+\$TemplateCidr') 'NO_SSH_HOST_MISMATCH: build.ps1 生成 user-data 时传的是 $TemplateCidr'
Assert-True ($build -match '(?m)^\$TemplateCidr\s*=\s*["'']\$TemplateIP/') 'NO_SSH_HOST_MISMATCH: $TemplateCidr 是从 $TemplateIP 拼出来的'
Assert-True ($build -match 'ssh_handshake_attempts') 'NO_HANDSHAKE_ATTEMPTS: build.ps1 调大了 ssh_handshake_attempts(装系统要十几分钟)'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
