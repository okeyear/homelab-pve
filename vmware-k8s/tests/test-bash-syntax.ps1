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

    # ---- 先找本机已经有的 pyyaml(离线)--------------------------------
    #
    # `uv run --with pyyaml` 每次都要去索引解析依赖,国内 pypi 一抽风
    # 这条校验就整个跳过了 —— 而 YAML 合法性恰恰是最不能省的一条:
    # YAML 写坏了 subiquity 会**静默忽略**整段 late-commands。
    #
    # uv 的缓存里有已经 unpack 好的 pyyaml,把它挂到 PYTHONPATH 上
    # 就能离线用 —— 不碰网络,也就不会因为网络抽风而漏检。
    $cachedSitePkgs = @()
    $uvCache = Join-Path $env:LOCALAPPDATA 'uv\cache'
    if (Test-Path -LiteralPath $uvCache) {
        $cachedSitePkgs = @(Get-ChildItem -Path $uvCache -Recurse -Filter '__init__.py' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\Lib\\site-packages\\yaml\\__init__\.py$' } |
            ForEach-Object { Split-Path -Parent (Split-Path -Parent $_.FullName) } |
            Select-Object -Unique)
    }

    $parsed = $false
    $outText = ''
    $lastOut = $null

    # 方式 A:用 uv 缓存里的 pyyaml(离线)
    foreach ($sp in $cachedSitePkgs) {
        $prevEap = $ErrorActionPreference
        $prevPp = $env:PYTHONPATH
        $ErrorActionPreference = 'Continue'
        $env:PYTHONPATH = $sp
        try {
            $lastOut = & $uv run --python 3.12 --no-project python -c $pyCode $tmp 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
            $env:PYTHONPATH = $prevPp
        }
        $outText = ($lastOut | ForEach-Object { $_.ToString() }) -join "`n"
        if ($code -eq 0) {
            $parsed = $true
            Write-Host "  [.. ] 用 uv 缓存里的 pyyaml($sp)" -ForegroundColor DarkGray
            break
        }
    }

    # 方式 B:联网装。默认源不行就换清华镜像,两次都是网络问题就跳过。
    # 注意:uv 拉不到 pyyaml 时的报错有好几种形态,全都要认出来 ——
    # 认不出来的话,"网络不通"会被当成"YAML 写错了"而报红。
    #   error: No solution found when resolving `--with` dependencies
    #   An index (https://pypi.tuna.tsinghua.edu.cn/simple) returned a 403 Forbidden error
    #   Failed to fetch / Request failed / Temporary failure / SSL
    # 这些都是**网络/索引**问题,跟 YAML 语法无关。
    # YAML 语法错误长什么样:yaml.scanner.ScannerError / ParserError,
    # 上面这些词一个都不会有。
    $netErrPattern = 'No solution found|was not found in the package registry|returned a 40[0-9]|Failed to fetch|Request failed|network|Connection|Temporary failure|SSL|index-url'
    if (-not $parsed) {
        $attempts = @(
            @{ Args = @('run', '--python', '3.12', '--with', 'pyyaml', '--no-project'); Name = '默认 pypi' },
            @{ Args = @('run', '--python', '3.12', '--with', 'pyyaml', '--no-project',
                        '--index-url', 'https://pypi.tuna.tsinghua.edu.cn/simple'); Name = '清华镜像' }
        )
        foreach ($a in $attempts) {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $lastOut = & $uv @($a.Args) python -c $pyCode $tmp 2>&1
                $code = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $prevEap
            }
            $outText = ($lastOut | ForEach-Object { $_.ToString() }) -join "`n"
            if ($code -eq 0) { $parsed = $true; break }
            if ($outText -match $netErrPattern) {
                Write-Host "  [.. ] $($a.Name) 拉不动 pyyaml,换下一个源" -ForegroundColor DarkGray
                continue
            }
            break   # 不是网络问题,就是 YAML 本身错了
        }
    }

    if ($parsed) {
        $total++
        Write-Host "  ok   $outText" -ForegroundColor Green
        # network 段是模板能不能用的关键:它配的是**固定地址**,
        # live 环境和装好的目标系统靠它拿到同一个地址,packer 的
        # ssh_host 才指得对。被注释掉 / 被吞掉的话,subiquity 会
        # 静默跳过,模板看起来装好了,packer 却在另一个地址上白等
        # 40 分钟。
        $total++
        if ($outText -match 'network') {
            Write-Host '  ok   network 段没有被吞进注释里' -ForegroundColor Green
        }
        else {
            Write-Host "  FAIL 解析出的键里没有 network(实际: $outText)" -ForegroundColor Red
            $failed++
        }
    }
    elseif ($outText -match $netErrPattern) {
        Write-Host '  [skip] 两个源都拉不到 pyyaml,跳过 YAML 解析校验(网络问题,不是代码问题)' -ForegroundColor Yellow
        $lastOut | Select-Object -First 3 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        Write-Host '       兜底:packer/http/user-data 的结构检查在 test-userdata.ps1 里(纯文本,不联网)' -ForegroundColor DarkGray
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
