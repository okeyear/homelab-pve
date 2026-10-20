# vmware-k8s — 否定测试
#
# 断言写在哪儿都没用,关键在于它**会咬**。
# 这个测试故意把生产代码改坏(改在一份临时副本上,不动仓库里的文件),
# 然后要求对应的检查**必须报失败**。如果改坏了检查还是绿的,说明那条
# 断言是摆设,这里就会红。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-negative.ps1
#
# 慢一点(要复制一份目录、跑好几次子进程),所以默认不在 run-all.ps1 里,
# 改了编码相关的代码之后手动跑一次。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

# ---------------------------------------------------------------- 准备工作
$sandbox = Join-Path $env:TEMP ("vmware-k8s-neg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$tree = Join-Path $sandbox 'vmware-k8s'
Write-Host "临时副本: $tree"
Write-Host ''

New-Item -ItemType Directory -Path $tree -Force | Out-Null
# 复制一份不带 .cache 的树(.cache 里有 100MB 的 packer.exe,只单独拷一次)
$rc = & robocopy.exe $WorkDir $tree /E /XD '.cache' /NFL /NDL /NJH /NJS /NP /R:1 /W:1
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败(退出码 $LASTEXITCODE)" }

# packer 校验那条负例要用到 packer.exe,单独拷一份进去
$packerSrc = Join-Path $WorkDir '.cache\packer\packer.exe'
if (Test-Path -LiteralPath $packerSrc) {
    $packerDst = Join-Path $tree '.cache\packer'
    New-Item -ItemType Directory -Path $packerDst -Force | Out-Null
    Copy-Item -LiteralPath $packerSrc -Destination (Join-Path $packerDst 'packer.exe') -Force
}

# 每个会被改动的文件,先存一份原样,跑完一个负例就还原。
#
# Bom = $true 表示还原时要写 BOM —— .ps1 在 PowerShell 5.1 下没 BOM 会被
# 按系统 ANSI(GBK)读,中文全变乱码。user-data 恰恰相反:它不能有 BOM,
# 因为那是直接喂给 cloud-init 的 YAML,BOM 会顶掉开头的 #cloud-config。
$mutatedFiles = @(
    @{ Path = 'build.ps1';                    Bom = $true },
    @{ Path = 'lib\packer.ps1';               Bom = $true },
    @{ Path = 'lib\clone.ps1';                Bom = $true },
    @{ Path = 'lib\k8s.ps1';                  Bom = $true },
    @{ Path = 'lib\common.ps1';               Bom = $true },
    @{ Path = 'tests\test-packer-validate.ps1'; Bom = $true },
    @{ Path = 'packer\http\user-data';        Bom = $false }
)
$pristine = @{}
foreach ($f in $mutatedFiles) {
    $p = Join-Path $tree $f.Path
    $pristine[$f.Path] = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
}

function Restore-Tree {
    foreach ($f in $mutatedFiles) {
        $p = Join-Path $tree $f.Path
        [System.IO.File]::WriteAllText($p, $pristine[$f.Path], (New-Object System.Text.UTF8Encoding($f.Bom)))
    }
}

# M6/M7 要改的原文里带单引号和双引号,手写转义太容易出错(反引号 + ${ 在
# PowerShell 里有歧义),所以用单引号 here-string 原样带过来。
$m6From = @'
'CLUSTER_NAME=${CLUSTER_NAME:-"devops-k8s"}'
'@
$m6To = @'
"CLUSTER_NAME=${CLUSTER_NAME:-""devops-k8s""}"
'@
$m7From = @'
$templateVmx = Join-Path $WorkDir ('packer\output\' + $TemplateName + '.vmx')
'@
$m7To = @'
$templateVmx = Join-Path $WorkDir 'packer\output\'"$TemplateName.vmx"
'@
# M8:把 network 段改回 DHCP。
# 这是实跑时最贵的一个坑:packer 靠读 VMware 的 DHCP 租约文件找
# guest IP,而 live 环境和目标系统的 DHCP client-id 不同,两边拿到
# 不同地址,packer 死死连着 live 环境那个地址,40 分钟连不上。
$m8From = @'
        dhcp4: false
'@
$m8To = @'
        dhcp4: true
'@
# M10:把按 name 通配符匹配网卡改成写死接口名。
# VMware 的网卡名在不同硬件版本 / 不同内核上是 ens33 / ens160 /
# enp0s3 都可能,写死名字是最容易翻车的地方。
$m10From = @'
          name: "en*"
'@
$m10To = @'
          name: "ens33"
'@
# M11:把 late-commands 加回来。
# curtin 没有 curt-installer 这个子命令,而且 late-commands 失败
# **不重试、直接中止整场安装** —— 模板越薄,失败面越小。
$m11From = @'
  storage:
'@
$m11To = @'
  late-commands:
    - curtin-installer --target=/target --shell=sh -c "echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/99-vagrant"

  storage:
'@
# M12:从 packages 里删掉 sudo。
# ubuntu-minimal 不带 sudo,少了它 /etc/sudoers.d 目录都不存在,
# base 阶段写免密 sudo 那步必然失败。
$m12From = @'
    - sudo
'@
$m12To = ''
# M13:把固定地址写死在 user-data 里,不用占位符。
# 同一个地址要同时出现在 user-data 的 network 段和 packer 的
# ssh_host 里。两处各写一份,早晚会写歪 —— 写歪了 packer 会在一个
# 没人听的地址上白等 40 分钟,而两边看起来都"有地址"。
$m13From = @'
          - __TEMPLATE_CIDR__
'@
$m13To = @'
          - 10.10.10.9/24
'@
# M14:让 packer 的 ssh_host 和 user-data 里的地址对不上。
$m14From = @'
        ssh_host             = $TemplateIP
'@
$m14To = @'
        ssh_host             = "10.10.10.99"
'@

# ---------------------------------------------------------------- 负例清单
#
# From / To 是要在临时副本里做的替换。
# Expect  是这次失败**应该**出现的字样 —— 用来确认它是"因为改坏而失败",
#         而不是因为别的原因(比如脚本自己崩了)失败。
$muts = @(
    @{
        Name  = 'M1a user-data 改回 Get-Content(检查靠"生产脚本禁用 ANSI 读写"这条规则咬)'
        File  = 'lib\packer.ps1'
        From  = '$tpl = Read-Utf8Text $TemplatePath'
        To    = '$tpl = Get-Content -LiteralPath $TemplatePath -Raw'
        Test  = 'tests\test-encoding.ps1'
        Expect = 'lib\packer.ps1 里没有 ANSI 编解码的读写调用'
    }
    @{
        Name  = 'M1b user-data 改成按 GBK 解码(检查靠"network 必须单独成行"这条规则咬)'
        File  = 'lib\packer.ps1'
        From  = '$tpl = Read-Utf8Text $TemplatePath'
        To    = '$tpl = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::GetEncoding(936))'
        Test  = 'tests\test-encoding.ps1'
        Expect = '生成的 user-data 里 network: 单独成行'
    }
    @{
        Name  = 'M2 .vmx 改回 Get-Content(中文 displayName 会被读成乱码)'
        File  = 'lib\clone.ps1'
        From  = 'Read-Utf8Lines $VmxPath'
        To    = 'Get-Content -LiteralPath $VmxPath'
        Test  = 'tests\test-encoding.ps1'
        Expect = '中文 displayName 改写后还在'
    }
    @{
        Name  = 'M3 join 脚本改回 Set-Content -Encoding UTF8(会带 BOM)'
        File  = 'lib\k8s.ps1'
        From  = 'Write-Utf8Text $joinFile ("#!/bin/bash`n" + $join.Trim())'
        To    = 'Set-Content -LiteralPath $joinFile -Value ("#!/bin/bash`n" + $join.Trim()) -Encoding UTF8'
        Test  = 'tests\test-encoding.ps1'
        Expect = 'k8s.ps1'
    }
    @{
        Name  = 'M4 packer 的 -var-file 不加引号($varsPath 不会展开)'
        File  = 'tests\test-packer-validate.ps1'
        From  = '"-var-file=$varsPath"'
        To    = '-var-file=$varsPath'
        Test  = 'tests\test-packer-validate.ps1'
        Expect = 'packer validate 通过'
    }
    @{
        Name  = 'M5 Write-Utf8Text 改回 Set-Content -Encoding UTF8(会带 BOM)'
        File  = 'lib\common.ps1'
        From  = '[System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))'
        To    = 'Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8'
        Test  = 'tests\test-encoding.ps1'
        Expect = 'Write-Utf8Text 不写 BOM'
    }
    @{
        Name  = 'M6 config.sh 的 CLUSTER_NAME 改回可展开 here-string(shell 默认值被吃掉)'
        File  = 'lib\k8s.ps1'
        From  = $m6From
        To    = $m6To
        Test  = 'tests\test-k8s-config.ps1'
        Expect = 'CLUSTER_NAME'
    }
    @{
        Name  = 'M7 相邻字符串字面量(Join-Path 会收到三个参数)'
        File  = 'build.ps1'
        From  = $m7From
        To    = $m7To
        Test  = 'tests\test-ps-syntax.ps1'
        Expect = '相邻的字符串字面量'
    }
    @{
        Name  = 'M8 network 段改回 DHCP(packer 会连着 live 环境那个地址,40 分钟连不上)'
        File  = 'packer\http\user-data'
        From  = $m8From
        To    = $m8To
        Test  = 'tests\test-userdata.ps1'
        # 用断言上的英文标记来匹配,不用中文 —— 中文那串一旦跟被测
        # 脚本里的措辞差一个字,负例就会"因为别的原因失败"而失去意义。
        Expect = 'FAIL NO_STATIC_IP'
    }
    @{
        Name  = 'M9 user-data 的 YAML 语法写坏(YAML 坏了 subiquity 会静默丢掉整段配置)'
        File  = 'packer\http\user-data'
        From  = '  version: 1'
        To    = '  version: [1, 2'
        Test  = 'tests\test-bash-syntax.ps1'
        Expect = 'FAIL YAML 解析失败'
    }
    @{
        Name  = 'M10 网卡匹配改成写死 ens33(换个硬件版本/内核就翻车)'
        File  = 'packer\http\user-data'
        From  = $m10From
        To    = $m10To
        Test  = 'tests\test-userdata.ps1'
        Expect = 'FAIL NO_HARDCODED_IFNAME'
    }
    @{
        Name  = 'M11 把 late-commands 加回来(失败不重试,直接中止整场安装)'
        File  = 'packer\http\user-data'
        From  = $m11From
        To    = $m11To
        Test  = 'tests\test-userdata.ps1'
        Expect = 'FAIL NO_LATE_COMMANDS'
    }
    @{
        Name  = 'M12 packages 里删掉 sudo(ubuntu-minimal 不带它,免密 sudo 那步必失败)'
        File  = 'packer\http\user-data'
        From  = $m12From
        To    = $m12To
        Test  = 'tests\test-userdata.ps1'
        Expect = 'FAIL NO_SUDO_PACKAGE'
    }
    @{
        Name  = 'M13 固定地址写死在 user-data 里(和 packer 的 ssh_host 对不上)'
        File  = 'packer\http\user-data'
        From  = $m13From
        To    = $m13To
        Test  = 'tests\test-userdata.ps1'
        Expect = 'FAIL NO_HARDCODED_IP'
    }
    @{
        Name  = 'M14 packer 的 ssh_host 和 user-data 里的地址对不上'
        File  = 'build.ps1'
        From  = $m14From
        To    = $m14To
        Test  = 'tests\test-userdata.ps1'
        Expect = 'FAIL NO_SSH_HOST_MISMATCH'
    }
)

# ---------------------------------------------------------------- 跑
foreach ($m in $muts) {
    Write-Host "--- $($m.Name) ---"

    Restore-Tree
    $path = Join-Path $tree $m.File
    $src = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if (-not $src.Contains($m.From)) {
        Assert-True $false "改不动:在 $($m.File) 里找不到要替换的片段"
        Write-Host ''
        continue
    }
    $src = $src.Replace($m.From, $m.To)
    # BOM 按文件来:.ps1 要 BOM,user-data 不能有(BOM 会顶掉 #cloud-config)
    $bom = $true
    foreach ($f in $mutatedFiles) {
        if ($f.Path -eq $m.File) { $bom = $f.Bom; break }
    }
    [System.IO.File]::WriteAllText($path, $src, (New-Object System.Text.UTF8Encoding($bom)))

    $testPath = Join-Path $tree $m.Test
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $testPath 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"

    $total++
    if ($code -eq 0) {
        Assert-True $false '改坏之后检查居然还是绿的(断言不会咬)'
        Write-Host '       ---- 检查的完整输出 ----' -ForegroundColor DarkGray
        ($text -split "`n") | Select-Object -First 60 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    }
    else {
        Write-Host "  ok   检查报失败(退出码 $code)" -ForegroundColor Green
    }

    $total++
    if ($text.Contains($m.Expect)) {
        Write-Host "  ok   失败原因是预期的那个: $($m.Expect)" -ForegroundColor Green
    }
    else {
        Assert-True $false "是别的原因失败(不是预期中的: $($m.Expect))"
        Write-Host '       ---- 检查的完整输出 ----' -ForegroundColor DarkGray
        ($text -split "`n") | Select-Object -First 60 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

Restore-Tree

# ---------------------------------------------------------------- 清理
if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "临时副本已删除: $sandbox"
Write-Host ''

if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
