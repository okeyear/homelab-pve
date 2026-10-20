# vmware-k8s — guest 脚本的 bash 语法检查
#
# guest/clone-prep.sh 是要在 Ubuntu 里跑的,但语法错误只有到那台机器上
# 才暴露 —— 那时候模板都建好了,重来一次要十几分钟。这里本地先过一遍
# bash -n。
#
# 用 Git for Windows 的 bash(它把 /usr/bin 放进 PATH,sed/cat/seq 都在)。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir

$bash = $null
foreach ($p in @(
        'D:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\bin\bash.exe',
        'D:\bin\PortableGit\bin\bash.exe')) {
    if (Test-Path -LiteralPath $p) { $bash = $p; break }
}
if (-not $bash) {
    Write-Host '[skip] 找不到 bash,跳过' -ForegroundColor Yellow
    exit 0
}
Write-Host "bash: $bash"

$failed = 0
$total = 0

Get-ChildItem (Join-Path $WorkDir 'guest') -Filter '*.sh' -File | ForEach-Object {
    $total++
    $out = & $bash -n $_.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL $($_.Name)" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "       $_" }
        $failed++
    }
    else {
        Write-Host "  ok   $($_.Name)" -ForegroundColor Green
    }
}

# autoinstall 的 user-data 是 YAML,不是 bash,单独验一下 YAML 能解析
Write-Host ''
Write-Host '=== user-data 是合法 YAML ==='
$userData = Join-Path $WorkDir 'packer\http\user-data'
# 必须显式按 UTF-8 读。Get-Content -Raw 在 5.1 上走系统 ANSI(GBK),
# 中文变乱码,还会把行尾吃掉 —— `late-commands:` 会被粘到上一行注释
# 后面,YAML 照样能解析,但那一整段 late-commands 就没人执行了。
$text = [System.IO.File]::ReadAllText($userData, [System.Text.Encoding]::UTF8)
foreach ($ph in @('__SSH_AUTHORIZED_KEY__', '__PASSWORD_HASH__', '__HOSTNAME__')) {
    $total++
    if ($text.Contains($ph)) {
        Write-Host "  ok   user-data 保留了占位符 $ph" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL user-data 里找不到占位符 $ph" -ForegroundColor Red
        $failed++
    }
}

# 占位符被替换之后必须是合法 YAML —— build.ps1 是这么干的
Write-Host ''
Write-Host '=== 替换占位符后仍是合法 YAML ==='
$sample = $text.
    Replace('__SSH_AUTHORIZED_KEY__', 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQtest@example').
    Replace('__PASSWORD_HASH__', '$6$abc$defghijklmnopqrstuv').
    Replace('__HOSTNAME__', 'k8s-template')
$tmp = Join-Path $TestDir '_user-data.sample.yaml'
[System.IO.File]::WriteAllText($tmp, $sample, (New-Object System.Text.UTF8Encoding($false)))

# uv 往 stderr 写任何东西(下载进度、警告、Python 的 traceback)都会在
# $ErrorActionPreference='Stop' 下变成终止性错误,连退出码都拿不到。
# 这里临时放宽,拿到退出码和输出之后再判成败。
$uv = 'C:\Users\JackPeng\.local\bin\uv.exe'
if (-not (Test-Path -LiteralPath $uv)) {
    $uv = (Get-Command uv -ErrorAction SilentlyContinue)
    if ($uv) { $uv = $uv.Source }
}
if (-not $uv) {
    Write-Host '  [skip] 找不到 uv,跳过 YAML 解析校验' -ForegroundColor Yellow
}
else {
    $pyCode = "import sys,yaml; d=yaml.safe_load(open(sys.argv[1],encoding='utf-8')); print('|'.join(sorted(d['autoinstall'].keys())))"

    # 这个检查要现装 pyyaml,离不开 pypi。国内直连 pypi 经常抽风,
    # 所以:先走默认源,失败了换清华镜像再来一次。
    # 两次都是网络问题,就跳过这一项(不算失败)—— 网络不通不是代码的锅。
    # 但要是 YAML 真的解析错了,照样红。
    $attempts = @(
        @{ Args = @('run', '--python', '3.12', '--with', 'pyyaml', '--no-project'); Name = '默认 pypi' },
        @{ Args = @('run', '--python', '3.12', '--with', 'pyyaml', '--no-project',
                    '--index-url', 'https://pypi.tuna.tsinghua.edu.cn/simple'); Name = '清华镜像' }
    )

    $parsed = $false
    $outText = ''
    $lastOut = $null
    foreach ($a in $attempts) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lastOut = & $uv @($a.Args) python -c $pyCode $tmp 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prev
        }
        $outText = ($lastOut | ForEach-Object { $_.ToString() }) -join "`n"
        if ($code -eq 0) { $parsed = $true; break }
        if ($outText -match 'Failed to fetch|Request failed|network|Connection|Temporary failure|SSL') {
            Write-Host "  [.. ] $($a.Name) 拉不动 pyyaml,换下一个源" -ForegroundColor DarkGray
            continue
        }
        break   # 不是网络问题,就是 YAML 本身错了
    }

    if ($parsed) {
        $total++
        Write-Host "  ok   $outText" -ForegroundColor Green
        # late-commands 是模板能不能用的关键:它负责免密 sudo、
        # machine-id / SSH host key 重置。被注释掉的话,subiquity 会
        # 静默跳过,模板看起来装好了,克隆出来的节点全是废的。
        $total++
        if ($outText -match 'late-commands') {
            Write-Host '  ok   late-commands 没有被吞进注释里' -ForegroundColor Green
        }
        else {
            Write-Host "  FAIL 解析出的键里没有 late-commands(实际: $outText)" -ForegroundColor Red
            $failed++
        }
    }
    elseif ($outText -match 'Failed to fetch|Request failed|network|Connection|Temporary failure|SSL') {
        Write-Host '  [skip] 两个源都拉不到 pyyaml,跳过 YAML 解析校验(网络问题,不是代码问题)' -ForegroundColor Yellow
        $lastOut | Select-Object -First 3 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    }
    else {
        $total++
        Write-Host '  FAIL YAML 解析失败:' -ForegroundColor Red
        $lastOut | ForEach-Object { Write-Host "       $_" }
        $failed++
    }
}
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
