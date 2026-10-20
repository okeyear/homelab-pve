# vmware-k8s — 离线测试
#
# 这些测试不需要管理员权限,也不会碰宿主机上的 VMware 配置
# (唯一碰真实文件的那一步是在副本上做,测完就删)。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\run-all.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$WorkDir = Split-Path -Parent $TestDir

$failed = 0
$total = 0

function Invoke-TestFile {
    param([string]$Name, [string]$Path)
    Write-Host ''
    Write-Host "########## $Name ##########" -ForegroundColor White
    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -NoProfile -ExecutionPolicy Bypass -File $Path
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  -> $Name 失败" -ForegroundColor Red
        $script:failed++
    }
    $script:total++
}

# ---- 1. PowerShell 语法 + BOM ----
Invoke-TestFile 'ps-syntax' (Join-Path $TestDir 'test-ps-syntax.ps1')
# ---- 1.5 跨文件函数调用的参数绑定 ----
Invoke-TestFile 'params' (Join-Path $TestDir 'test-params.ps1')
# ---- 2. 编码回归(UTF-8 读写 / BOM / $var 展开)----
Invoke-TestFile 'encoding' (Join-Path $TestDir 'test-encoding.ps1')
# ---- 3. guest 脚本的 bash 语法 ----
Invoke-TestFile 'bash-syntax' (Join-Path $TestDir 'test-bash-syntax.ps1')
# ---- 3.5 autoinstall user-data 的结构(离线,不依赖网络)----
Invoke-TestFile 'userdata' (Join-Path $TestDir 'test-userdata.ps1')
# ---- 4. 静态 DHCP 租约写入器(在副本上做)----
Invoke-TestFile 'vmnet-lease' (Join-Path $TestDir 'test-vmnet-lease.ps1')
# ---- 5. 节点定义 / MAC 推导 ----
Invoke-TestFile 'node-defs' (Join-Path $TestDir 'test-node-defs.ps1')
# ---- 6. setup-k8s/config.sh 生成 ----
Invoke-TestFile 'k8s-config' (Join-Path $TestDir 'test-k8s-config.ps1')
# ---- 7. packer 模板(需要 .cache\packer\packer.exe)----
$packerExe = Join-Path $WorkDir '.cache\packer\packer.exe'
if (Test-Path -LiteralPath $packerExe) {
    Invoke-TestFile 'packer-validate' (Join-Path $TestDir 'test-packer-validate.ps1')
}
else {
    Write-Host ''
    Write-Host '[skip] 没装 packer,跳过模板校验(先跑一次 build.cmd -Stage packer)' -ForegroundColor Yellow
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "全部通过 ($total 组)" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failed / $total 组失败" -ForegroundColor Red
    exit 1
}
