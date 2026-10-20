# vmware-k8s — PowerShell 语法与编码检查
#
# 两个必查项:
#   1. 语法能过 Parser
#   2. 文件带 UTF-8 BOM
#
# 第 2 条不是洁癖:Windows PowerShell 5.1 读 .ps1 时,没有 BOM 就按
# ANSI(简体中文机器上是 GBK)解释字节。UTF-8 的中文注释被按 GBK 拆开
# 之后,某些多字节序列会变成引号,直接把语法结构打散 —— 报出来的是
# 一堆莫名其妙的"字符串缺少终止符",和真正的问题完全对不上。
# build.cmd 调的就是 5.1,所以 BOM 是硬要求。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

# .cache 是运行时产物(装好的 packer、生成的 user-data、临时诊断脚本),
# 不进版本库,也不该参与检查 —— 否则本地多几个临时脚本,测试结果就不一样了。
function Get-CheckedScripts {
    return @(Get-ChildItem $WorkDir -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notlike '*\.cache\*' })
}

Write-Host '=== 语法 ==='
Get-CheckedScripts | ForEach-Object {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        Write-Host "  FAIL $($_.Name) 语法错误:" -ForegroundColor Red
        $errs | Select-Object -First 5 | ForEach-Object {
            Write-Host ("       L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
        }
        $script:total++
        $script:failed++
    }
    else {
        Assert-True $true "$($_.Name) 语法 OK"
    }
}

Write-Host ''
Write-Host '=== UTF-8 BOM ==='
Get-CheckedScripts | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    Assert-True $hasBom ("{0} 带 BOM" -f $_.Name)
}

Write-Host ''
Write-Host '=== 相邻字符串字面量 ==='
# PowerShell 不会像 C 那样自动拼接相邻的字符串字面量。'a\'"b" 会被当成
# **两个参数**传给命令 —— 写 Join-Path 的话就是收到三个参数,报
# "A positional parameter cannot be found that accepts argument 'b'"。
#
# 这个坑很难靠读代码看出来(看着挺像拼接),但一跑就炸,而且往往炸在
# 流程的最后一步。这里用 AST 找"紧挨着的两个字符串字面量参数"。
Get-CheckedScripts | ForEach-Object {
    $path = $_.FullName
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errs)
    $hits = @()
    $cmds = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    foreach ($c in $cmds) {
        $elems = $c.CommandElements
        for ($i = 1; $i -lt $elems.Count; $i++) {
            $a = $elems[$i - 1]
            $b = $elems[$i]
            $aIsStr = ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                      ($a -is [System.Management.Automation.Language.ExpandableStringExpressionAst])
            $bIsStr = ($b -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                      ($b -is [System.Management.Automation.Language.ExpandableStringExpressionAst])
            if (-not ($aIsStr -and $bIsStr)) { continue }
            # 中间一个空格都没有才算 —— 有空格的可能是故意传两个参数
            if ($a.Extent.EndOffset -ne $b.Extent.StartOffset) { continue }
            $hits += "第 $($b.Extent.StartLineNumber) 行: $($c.Extent.Text.Trim())"
        }
    }
    Assert-True ($hits.Count -eq 0) ("{0} 里没有相邻的字符串字面量" -f $_.Name)
    foreach ($h in $hits) { Write-Host "       $h" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '=== 原生命令必须走 Invoke-Native ==='
# PowerShell 5.1 里,原生命令往 **stderr** 写东西,在
# $ErrorActionPreference='Stop' 下会变成**终止性错误** —— 脚本当场
# 退出,退出码和输出一个都拿不到。
#
# 实际踩过两次:
#   1. vmware-vdiskmanager 报 "One of the parameters supplied is
#      invalid (0x3e80)"(其实只是盘已经是 20G、不用再扩),
#      把整个 base 阶段带走了。
#   2. ssh 第一次连新机器时会写 "Warning: Permanently added ... to
#      the list of known hosts." —— 每个新节点都会出现一次,
#      照直写就会让 k8s 阶段在第一台节点上就死掉。
#
# 仓库里统一用 lib\common.ps1 的 Invoke-Native 包一层,
# 这个检查保证以后不会有人再写裸的 & 调用。
$prodScripts = @(Get-ChildItem (Join-Path $WorkDir 'lib') -Filter '*.ps1' -File |
    ForEach-Object { $_.FullName })
$prodScripts += (Join-Path $WorkDir 'build.ps1')

foreach ($path in $prodScripts) {
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errs)
    $cmds = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true)
    $hits = @()
    foreach ($c in $cmds) {
        if ($c.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand) {
            continue
        }
        $first = $c.CommandElements[0]
        # & $run 'stage' —— 阶段分发器,不是外部程序
        if ($first -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $first.VariablePath.UserPath -eq 'run') { continue }
        # 找它属于哪个函数
        $owner = '(脚本顶层)'
        $p = $c.Parent
        while ($null -ne $p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $owner = $p.Name
                break
            }
            $p = $p.Parent
        }
        if ($owner -eq 'Invoke-Native') { continue }
        $hits += "第 $($c.Extent.StartLineNumber) 行($owner): $($c.Extent.Text.Trim())"
    }
    Assert-True ($hits.Count -eq 0) `
        ("{0} 里的外部程序调用都走 Invoke-Native" -f (Split-Path -Leaf $path))
    foreach ($h in $hits) { Write-Host "       $h" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '=== 行尾 ==='
# .ps1 用 CRLF 或 LF 都可以(PowerShell 两个都吃),但同一目录里
# 混着会让 git diff 很难看。这里只报告,不失败。
Get-CheckedScripts | ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName)
    $crlf = ([regex]::Matches($t, "`r`n")).Count
    $lf = ([regex]::Matches($t, "`n")).Count
    $kind = if ($crlf -gt 0 -and $lf -eq $crlf) { 'CRLF' } elseif ($crlf -eq 0) { 'LF' } else { '混合' }
    Write-Host ("  {0,-28} {1}" -f $_.Name, $kind)
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
