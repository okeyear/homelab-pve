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
