# vmware-k8s — 函数返回值污染检查
#
# 语法检查、参数绑定检查都抓不到这一类错:函数**正常返回**了,
# 只是返回值里**多带了别的东西**。
#
# 实际踩过:Invoke-Preflight 里有一句
#
#     Confirm-Tool -Path $vmrun -What 'vmrun'
#
# Confirm-Tool 结尾是 `return $Path`(一个字符串),而 Invoke-Preflight
# 结尾是 `return $vmnet`(一个对象)。前一句的返回值没人接,于是它
# 混进了后一句的返回值里:
#
#     $vmnet = Invoke-Preflight
#     # $vmnet 其实是 [ 'D:\...\vmrun.exe', <对象> ] 一个**数组**
#
# 接下来 $vmnet.Name 走的是 PowerShell 的成员枚举,枚举到那个字符串
# 元素时炸:
#
#     The property 'Name' cannot be found on this object.
#
# 报错信息里**没有行号**,也完全看不出跟 Confirm-Tool 有关 ——
# 而 Confirm-Tool 跟"Name"这个词一点关系都没有。
#
# 规则:一个函数如果自己会返回值,那么它内部**语句位置**上调用别的
# 有返回值的函数时,必须把返回值接住(赋值 / $null = / 管道给
# Out-Null),否则外层的返回值就被污染了。
#
# "语句位置" = 那条命令的结果直接进了函数的输出流。赋值
# ($x = Foo)、函数参数 (-Path (Foo))、if 条件 (if (Foo)) 都**不是**
# 语句位置 —— 那些地方的返回值是被用掉的,不会污染外层。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-return-purity.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-return-purity.ps1 -Root <别的目录>

param(
    # 要检查的 vmware-k8s 根目录(默认就是本文件的上级目录)。
    # 否定测试会把整棵树复制到临时目录再改坏,所以这里要能指定。
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $TestDir }

$failed = 0
$total = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

# ---------------------------------------------------------------- 无声函数名单
#
# 这些函数**不往输出流里写东西**,在语句位置调用它们是安全的。
# 名单之外的仓库函数一律按"会返回值"处理 —— 宁可多报,不能漏报。
#
# 新加函数时:如果它只干副作用(写文件、启停服务、打印日志),就加进
# 这个名单;如果它会返回值,不用动 —— 默认就是"会返回值"。
$silentFns = @(
    'Write-Step', 'Write-Ok', 'Write-Info', 'Write-Note', 'Write-Fail',
    'Write-Utf8Text', 'Write-Utf8Lines',
    'Set-VmxValue', 'Remove-VmxKey', 'Remove-IsoAttachments',
    'Expand-NodeDisk', 'Start-NodeVm', 'Stop-NodeVm',
    'Invoke-Download', 'Expand-ZipTo', 'Stop-WithError',
    'Remove-KnownHostEntry', 'Invoke-DestroyNodes', 'Invoke-CloneNodes',
    'Invoke-BootNodes', 'Select-Sha256Line',
    'Install-RegionShim'
)

# 管道里丢掉输出的命令
$discardCmds = @('Out-Null', 'Out-Host', 'Write-Host', 'Write-Verbose',
    'Write-Debug', 'Write-Information', 'Write-Progress')

# ---------------------------------------------------------------- 收集函数
$files = @()
$build = Join-Path $Root 'build.ps1'
if (Test-Path -LiteralPath $build) { $files += $build }
$libDir = Join-Path $Root 'lib'
if (Test-Path -LiteralPath $libDir) {
    # 必须取 .FullName:FileInfo.ToString() 只给文件名("clone.ps1"),
    # 解析器会拿它当相对路径去找,结果报 "未能找到文件"、一个函数都
    # 收集不到 —— 而且不抛异常,静悄悄地少检查了 6 个文件。
    $files += @(Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File |
            Sort-Object Name | ForEach-Object { $_.FullName })
}

Write-Host "=== 扫描 $($files.Count) 个文件 ==="

$defs = @{}
foreach ($f in $files) {
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $f, [ref]$tokens, [ref]$errs)
    $fns = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($fn in $fns) {
        # 这个函数自己会不会往输出流里写东西?
        # 两种写法:
        #   1. 有一句 `return <值>`
        #   2. 函数体最后一句是个裸表达式(管道末尾的 [pscustomobject]@{...}、
        #      @(...)、字符串……)—— PowerShell 会把它当返回值
        $hasValue = $false
        $rets = $fn.Body.FindAll({
                param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
            }, $true)
        foreach ($r in $rets) {
            if ($null -ne $r.Pipeline) { $hasValue = $true }
        }
        if (-not $hasValue -and $fn.Body.EndBlock -and $fn.Body.EndBlock.Statements.Count -gt 0) {
            $last = $fn.Body.EndBlock.Statements[$fn.Body.EndBlock.Statements.Count - 1]
            if ($last -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $hasValue = $true
            }
        }
        $defs[$fn.Name] = @{
            Ast      = $fn
            File     = (Split-Path -Leaf $f)
            HasValue = $hasValue
        }
    }
}
Assert-True ($defs.Count -ge 20) ("收集到 $($defs.Count) 个函数定义")

# ---------------------------------------------------------------- 找污染
Write-Host ''
Write-Host '=== 返回值有没有被别的东西混进去 ==='

# 判断一个节点是不是"语句位置":它的结果会直接进函数的输出流。
#
# 做法:从语句往上走,跳过"透明"的包装节点(它们只是把语句装进去,
# 输出照样往上冒),看**第一个卡住**的祖先是谁:
#
#   ScriptBlockAst             函数体 / 脚本体 -> 是语句位置  -> 查
#   ScriptBlockExpressionAst   某个命令的参数 { } -> 输出被那个命令用掉了 -> 不查
#   AssignmentStatementAst     赋值右边        -> 被接住了    -> 不查
#   ParenExpressionAst 等      括号 / 类型转换 -> 被接住了    -> 不查
#
# 透明节点:PipelineAst(管道)、NamedBlockAst(函数的 begin/end 块)、
# StatementBlockAst(if / foreach 的 {} 块)、以及各种循环和 try 的
# 包装节点 —— 它们的输出都会继续往上冒。
function Test-StatementPosition {
    param($Ast, $Owner)
    $transparent = @(
        [System.Management.Automation.Language.PipelineAst],
        [System.Management.Automation.Language.NamedBlockAst],
        [System.Management.Automation.Language.StatementBlockAst],
        [System.Management.Automation.Language.ScriptBlockAst],
        [System.Management.Automation.Language.IfStatementAst],
        [System.Management.Automation.Language.WhileStatementAst],
        [System.Management.Automation.Language.DoWhileStatementAst],
        [System.Management.Automation.Language.DoUntilStatementAst],
        [System.Management.Automation.Language.ForEachStatementAst],
        [System.Management.Automation.Language.ForStatementAst],
        [System.Management.Automation.Language.SwitchStatementAst],
        [System.Management.Automation.Language.TrapStatementAst],
        [System.Management.Automation.Language.TryStatementAst],
        [System.Management.Automation.Language.CatchClauseAst]
    )
    $p = $Ast.Parent
    while ($null -ne $p -and ($transparent -contains $p.GetType())) {
        $p = $p.Parent
    }
    if ($null -eq $p) { return $false }
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        # 走到函数定义了:语句在函数体里。
        # 但如果是**别的**函数(嵌套定义),不算在本函数头上。
        return ($null -ne $Owner -and $p -eq $Owner)
    }
    # 停在别的地方:
    #   ScriptBlockExpressionAst  命令参数用的 { } -> 输出被那个命令用掉了
    #   AssignmentStatementAst    赋值右边          -> 被接住了
    #   ParenExpressionAst 等     括号 / 类型转换   -> 被接住了
    return $false
}

$violations = @()
foreach ($name in ($defs.Keys | Sort-Object)) {
    $info = $defs[$name]
    if (-not $info.HasValue) { continue }   # 自己不返回值的函数,污染了也没人受害

    $fn = $info.Ast
    $pipes = $fn.Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.PipelineAst]
        }, $true)

    foreach ($p in $pipes) {
        if (-not (Test-StatementPosition -Ast $p -Owner $fn)) { continue }
        $els = @($p.PipelineElements)
        if ($els.Count -eq 0) { continue }
        # 管道里**最后**一个命令的输出才是这条语句的输出。
        # 前面那些的输出被下一个命令用掉了,不污染外层。
        $last = $els[$els.Count - 1]
        if (-not ($last -is [System.Management.Automation.Language.CommandAst])) { continue }
        $callee = $last.GetCommandName()
        if (-not $callee) { continue }
        if ($discardCmds -contains $callee) { continue }
        if ($callee -eq $name) { continue }        # 递归调用自己不算
        if (-not $defs.ContainsKey($callee)) { continue }   # 不是仓库里的函数
        if ($silentFns -contains $callee) { continue }      # 无声函数,安全

        $violations += [pscustomobject]@{
            File     = $info.File
            Function = $name
            Callee   = $callee
            Line     = $last.Extent.StartLineNumber
            Text     = $last.Extent.Text
        }
    }
}

foreach ($v in $violations) {
    Write-Host ("  FAIL RETURN_VALUE_LEAK {0}:{1}  函数 {2} 里调用 {3} 的返回值没接住" -f `
            $v.File, $v.Line, $v.Function, $v.Callee) -ForegroundColor Red
    Write-Host ("       {0}" -f $v.Text) -ForegroundColor DarkGray
    Write-Host ("       -> 这一句的返回值会混进 {0} 的返回值里。" -f $v.Function) -ForegroundColor DarkGray
    $failed++
    $total++
}

Assert-True ($violations.Count -eq 0) '没有函数被返回值污染'

# ---------------------------------------------------------------- 几个关键点单独盯一下
Write-Host ''
Write-Host '=== 几个关键调用点单独盯一下 ==='
$buildText = ''
if (Test-Path -LiteralPath $build) {
    $buildText = [System.IO.File]::ReadAllText($build, [System.Text.Encoding]::UTF8)
}
Assert-True ($buildText -match '\$null\s*=\s*Confirm-Tool') `
    'build.ps1 里 Confirm-Tool 的返回值被 $null = 接住了(它 return $Path)'
Assert-True ($buildText -match '\$vmnet\s*=\s*Invoke-Preflight') `
    'build.ps1 里 Invoke-Preflight 的返回值是整个接住的'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
