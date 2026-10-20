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

# 仓库的 setup-k8s/scripts 也要拷一份进来。
# 地区判定(detect_region)就住在 functions.sh 里,有些负例要改它;
# 测试里按 "<上一级>/setup-k8s/scripts" 找 —— 副本的上一级正好是 $sandbox。
$repoRoot = Split-Path -Parent $WorkDir
$repoScripts = Join-Path $repoRoot 'setup-k8s\scripts'
if (Test-Path -LiteralPath $repoScripts) {
    $dst = Join-Path $sandbox 'setup-k8s\scripts'
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $rc = & robocopy.exe $repoScripts $dst /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy setup-k8s 失败(退出码 $LASTEXITCODE)" }
}

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
    @{ Path = 'packer\http\user-data';        Bom = $false },
    @{ Path = 'guest\base-setup.sh';          Bom = $false },
    @{ Path = 'guest\region-shim.sh';         Bom = $false },
    # 仓库自己的 functions.sh(地区判定住在里面),路径相对于副本树,
    # ..\ 是副本树的上一级 —— 那里放的是拷进来的 setup-k8s/scripts。
    @{ Path = '..\setup-k8s\scripts\functions.sh'; Bom = $false }
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
# M15:把 Confirm-Tool 的返回值放回输出流。
# 这是 base 阶段真实踩到的坑:Invoke-Preflight 结尾 `return $vmnet`,
# 中间那句 `Confirm-Tool ...` 的返回值(一个字符串路径)没人接,
# 混进返回值之后 $vmnet 变成 [字符串, 对象] 的数组,访问 .Name 时
# 在字符串元素上抛 "The property 'Name' cannot be found on this object",
# 报错里连行号都没有,完全看不出跟 Confirm-Tool 有关。
$m15From = @'
    $null = Confirm-Tool -Path $vmrun -What 'vmrun'
'@
$m15To = @'
    Confirm-Tool -Path $vmrun -What 'vmrun'
'@
# M16:把 ssh 调用改回裸的 & 调用。
# PS 5.1 里原生命令往 stderr 写东西,在 $ErrorActionPreference='Stop' 下
# 会变成终止性错误 —— ssh 第一次连新机器时那句
# "Warning: Permanently added ... to the list of known hosts."
# 就能把 k8s 阶段整个带走。
$m16From = @'
    $remote = Add-RemoteTimeout -Command $Command -TimeoutSec $TimeoutSec
    return (Invoke-Native -Exe $SshExe -Arguments (@($SshArgs) + @($target, $remote)))
'@
$m16To = @'
    $remote = Add-RemoteTimeout -Command $Command -TimeoutSec $TimeoutSec
    $out = & $SshExe @SshArgs $target $remote 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
'@
# M17:把 sed 的分隔符改回 |。
# pattern 里的或运算 (archive|security|...) 跟分隔符撞了,sed 会在
# 第一个 | 处截断命令,报出来的是
#   sed: -e expression #1, char 30: unknown option to `s'
# 这种完全指不到真因的错。bash -n 查不出来(语法是合法的)。
$m17From = @'
    sed -i -E "s#https?://(archive|security|us\.archive|[\w.-]*archive)\.ubuntu\.com/ubuntu#$MIRROR#g" \
'@
$m17To = @'
    sed -i -E "s|https?://(archive|security|us\.archive|[\w.-]*archive)\.ubuntu\.com/ubuntu|$MIRROR|g" \
'@
# M18:把 CNI 兜底的 sed 改回少一个分隔符的写法。
# sed 的 s 命令要三个分隔符:s@模式@替换@标志。少写一个中间的,
# sed 会把 "From+To" 整个当成模式,报
#   sed: -e expression #1, char 69: unterminated `s' command
# 报错里完全看不出是分隔符少了一个 —— 这是第一次实跑 CNI 兜底时踩到的。
$m18From = @'
        "sed -i 's@$From@$To@g' $Manifest && " +
'@
$m18To = @'
        "sed -i 's@$From$To@g' $Manifest && " +
'@
# M19:把地区补丁的"其他调用原样放行"改成无限递归。
# 补丁里的 curl 函数只该拦 ipinfo.io,别的调用必须走 command curl
# 绕开函数本身 —— 写成 curl 就是无限递归,连 gitHub API 都拉不到了。
$m19From = @'
    command curl "$@"
'@
$m19To = @'
    curl "$@"
'@
# M20:把 ipwho.is 的提取模式改回不容忍空格的老写法。
# ipwho.is 返回的是**缩进** JSON("country_code": "CN",),冒号后面
# 有一个空格,老的 '"country_code":"[A-Z]+"' 匹配不到 —— 那个源等于
# 白问。这是照着用户给的实现时实测发现的。
$m20From = @'
        region=$(curl_probe 'https://ipwho.is/' | grep -oE '"country_code":[[:space:]]*"[A-Z]+"' | head -n1 | cut -d'"' -f4)
'@
$m20To = @'
        region=$(curl_probe 'https://ipwho.is/' | grep -oE '"country_code":"[A-Z]+"' | head -n1 | cut -d'"' -f4)
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
    @{
        Name  = 'M15 Confirm-Tool 的返回值没人接(Invoke-Preflight 的返回值被污染)'
        File  = 'build.ps1'
        From  = $m15From
        To    = $m15To
        Test  = 'tests\test-return-purity.ps1'
        # 这个检查要指定扫哪棵树(检查的是副本,不是仓库)
        Args  = @('-Root', $tree)
        Expect = 'FAIL RETURN_VALUE_LEAK'
    }
    @{
        Name  = 'M16 ssh 调用改回裸的 & (stderr 会变成终止性错误,把 k8s 阶段带走)'
        File  = 'lib\k8s.ps1'
        From  = $m16From
        To    = $m16To
        Test  = 'tests\test-ps-syntax.ps1'
        Expect = '里的外部程序调用都走 Invoke-Native'
    }
    @{
        Name  = 'M17 sed 的分隔符跟 pattern 里的或运算撞了(bash -n 查不出来)'
        File  = 'guest\base-setup.sh'
        From  = $m17From
        To    = $m17To
        Test  = 'tests\test-bash-syntax.ps1'
        Expect = '里的 sed 分隔符没问题'
    }
    @{
        Name  = 'M18 CNI 兜底的 sed 少一个分隔符(sed 会报 unterminated s command)'
        File  = 'lib\k8s.ps1'
        From  = $m18From
        To    = $m18To
        Test  = 'tests\test-remote-cmd.ps1'
        Expect = 'sed 表达式是 s@模式@替换@标志 的形式(三个分隔符)'
    }
    @{
        Name  = 'M19 地区补丁的 curl 无限递归(其他调用没有原样放行)'
        File  = 'guest\region-shim.sh'
        From  = $m19From
        To    = $m19To
        Test  = 'tests\test-remote-cmd.ps1'
        Expect = '其他调用用 command curl 原样放行'
    }
    @{
        Name  = 'M20 ipwho.is 的提取不容忍空格(缩进 JSON 匹配不到,那个源白问)'
        File  = '..\setup-k8s\scripts\functions.sh'
        From  = $m20From
        To    = $m20To
        Test  = 'tests\test-remote-cmd.ps1'
        Expect = 'ipwho.is 的提取要容忍冒号后的空格'
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
    # 有些检查需要额外参数(比如让它扫副本目录而不是仓库)
    $testArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testPath)
    if ($m.ContainsKey('Args') -and $m.Args) { $testArgs += @($m.Args) }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $psExe @testArgs 2>&1
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
