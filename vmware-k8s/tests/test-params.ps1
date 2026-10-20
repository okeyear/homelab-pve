# vmware-k8s — 跨文件函数调用的参数绑定检查
#
# 语法检查抓不到这一类错:函数定义在 lib\base.ps1,调用在 build.ps1,
# 两边对不上的时候,PowerShell 要到**运行时**才报
# "Cannot bind argument to parameter 'X' because it is an empty string"。
#
# 实际踩过:base 阶段要给 sudo 喂密码,Invoke-BuildBase 加了
# -Password 参数,build.ps1 的调用点忘了传 —— 结果是跑到 base 阶段
# 才炸,前面模板白等了 20 分钟。
#
# 这个测试用 AST 把每个函数的参数名抠出来,再跟所有命令调用点比对:
#   - 传了函数里没有的参数 -> 报错
#   - 必填参数没传         -> 报错
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-params.ps1

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

function Write-Fail {
    param([string]$Message)
    Write-Host "  FAIL $Message" -ForegroundColor Red
}

# 生产脚本 + 会被它们调用的库
$files = @(
    'build.ps1',
    'lib\common.ps1',
    'lib\packer.ps1',
    'lib\vmnet.ps1',
    'lib\clone.ps1',
    'lib\base.ps1',
    'lib\k8s.ps1'
)

function Get-Ast {
    param([string]$Path)
    $tokens = $null
    $errs = $null
    return [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errs)
}

# ---------------------------------------------------------------- 1
Write-Host '=== 收集所有函数的参数 ==='
$defs = @{}
foreach ($f in $files) {
    $ast = Get-Ast (Join-Path $WorkDir $f)
    $fns = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($fn in $fns) {
        $names = @()
        $mandatory = @()
        if ($fn.Body.ParamBlock) {
            foreach ($prm in $fn.Body.ParamBlock.Parameters) {
                $names += $prm.Name.VariablePath.UserPath
                $isMandatory = $false
                foreach ($attr in $prm.Attributes) {
                    if ($attr.TypeName.Name -ne 'Parameter') { continue }
                    foreach ($na in $attr.NamedArguments) {
                        if ($na.ArgumentName -eq 'Mandatory' -and
                            $na.Argument -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                            $na.Argument.Value -eq $true) {
                            $isMandatory = $true
                        }
                    }
                }
                if ($isMandatory) { $mandatory += $prm.Name.VariablePath.UserPath }
            }
        }
        $defs[$fn.Name] = @{ Names = $names; Mandatory = $mandatory; File = $f }
    }
}
Assert-True ($defs.Count -ge 20) ("收集到 $($defs.Count) 个函数定义")

# ---------------------------------------------------------------- 2
Write-Host ''
Write-Host '=== 调用点的参数对不对 ==='
$bad = 0
foreach ($f in $files) {
    $ast = Get-Ast (Join-Path $WorkDir $f)
    $cmds = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if (-not $defs.ContainsKey($name)) { continue }

        $given = @()
        # 数位置参数。CommandElements 里,具名参数是
        #   [CommandParameterAst '-Path'][变量 $p]
        # 两块 —— 变量那一块是**这个具名参数的值**,不是位置参数。
        # 所以要边走边看:碰到具名参数就把它的值吃掉。
        $positional = 0
        $els = @($c.CommandElements)
        for ($i = 1; $i -lt $els.Count; $i++) {
            $el = $els[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                $n = $el.ParameterName
                if ($n -match '^[A-Za-z_][A-Za-z0-9_]*$') { $given += $n }
                # 下一个元素是它的值,跳过
                $i++
                continue
            }
            $positional++
        }

        foreach ($g in $given) {
            if ($defs[$name].Names -notcontains $g) {
                Write-Fail ("{0} 里调用 {1} 传了不存在的参数 -{2}(这个函数的参数是: {3})" -f `
                        $f, $name, $g, ($defs[$name].Names -join ', '))
                $bad++
            }
        }

        # 位置参数按声明顺序填进**没被具名占用**的那些参数里
        $bound = @($given)
        $pool = @($defs[$name].Names | Where-Object { $bound -notcontains $_ })
        for ($i = 0; $i -lt $positional -and $i -lt $pool.Count; $i++) {
            $bound += $pool[$i]
        }

        foreach ($m in $defs[$name].Mandatory) {
            if ($bound -notcontains $m) {
                Write-Fail ("{0} 里调用 {1} 没传必填参数 -{2}(位置参数 {3} 个,已绑: {4})" -f `
                        $f, $name, $m, $positional, ($bound -join ', '))
                $bad++
            }
        }
    }
}
Assert-True ($bad -eq 0) '所有调用点的参数都对得上'

# ---------------------------------------------------------------- 3
Write-Host ''
Write-Host '=== 几个关键调用点单独盯一下 ==='
$buildText = [System.IO.File]::ReadAllText(
    (Join-Path $WorkDir 'build.ps1'), [System.Text.Encoding]::UTF8)
Assert-True ($buildText -match '-Password\s+\$VagrantPassword') `
    'build.ps1 调 Invoke-BuildBase 时传了 -Password(base 阶段要靠它喂 sudo 密码)'
Assert-True ($buildText -match '-BaseVmx\s+\$baseVmx') `
    'build.ps1 调 Invoke-CloneNodes 时传的是 base 的 vmx(不是模板的)'
Assert-True ($buildText -match '-KnownHosts\s+\$KnownHosts') `
    'build.ps1 调 Wait-NodeReady 时传了 -KnownHosts(节点每次克隆都换 host key)'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
