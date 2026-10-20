# vmware-k8s — packer 模板校验
#
# packer validate 会把整个模板连插件一起校验:变量有没有声明、
# 参数名对不对、必填项给没给,全在里面。这比读代码靠谱 ——
# 上一版模板里的 vmware_path 就是被 validate 揪出来的
# (插件 v2.x 已经不接受这个参数)。
#
# 需要先装 packer:build.cmd -Stage packer

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir
$packer = Join-Path $WorkDir '.cache\packer\packer.exe'
if (-not (Test-Path -LiteralPath $packer)) {
    Write-Host '[skip] 没装 packer,跳过' -ForegroundColor Yellow
    exit 0
}

$failed = 0
$total = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

# 变量文件:用真实的路径和真实的 ISO 校验值,免得因为格式问题误判
$varsPath = Join-Path $TestDir '_validate.pkrvars.hcl'
$vars = @(
    'iso_url              = "https://mirrors.ustc.edu.cn/ubuntu-releases/26.04/ubuntu-26.04.1-live-server-amd64.iso"',
    'iso_checksum         = "sha256:cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927"',
    'vm_name              = "k8s-template"',
    'cpus                 = 2',
    'memory_mb            = 2048',
    'disk_gb              = 20',
    'vmware_version       = "25"',
    'ssh_username         = "vagrant"',
    'ssh_password         = "vagrant"',
    "ssh_private_key_file = `"$($env:USERPROFILE -replace '\\','/')/.ssh/id_rsa`"",
    "guest_scripts_dir    = `"$(($WorkDir -replace '\\','/') + '/guest')`"",
    "http_dir             = `"$(($WorkDir -replace '\\','/') + '/.cache/http/http')`""
) -join "`n"
[System.IO.File]::WriteAllText($varsPath, $vars, (New-Object System.Text.UTF8Encoding($false)))

Push-Location (Join-Path $WorkDir 'packer')
try {
    Write-Host '=== packer validate ==='
    # 参数值一定要带引号。不带引号时 PowerShell 5.1 不会展开 $varsPath,
    # 而是把字面量 "$varsPath" 传给 packer,packer 于是报
    # "Could not guess format of $varsPath"。
    $out = & $packer validate "-var-file=$varsPath" '.' 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    $total++
    Assert-True ($code -eq 0) 'packer validate 通过'

    Write-Host ''
    Write-Host '=== packer fmt(规范格式)==='
    $before = Get-Content -LiteralPath (Join-Path $WorkDir 'packer\ubuntu-template.pkr.hcl') -Raw
    & $packer fmt (Join-Path $WorkDir 'packer\ubuntu-template.pkr.hcl') | Out-Null
    $after = Get-Content -LiteralPath (Join-Path $WorkDir 'packer\ubuntu-template.pkr.hcl') -Raw
    $total++
    Assert-True ($before -eq $after) '模板已经是 packer fmt 的规范格式'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $varsPath -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
