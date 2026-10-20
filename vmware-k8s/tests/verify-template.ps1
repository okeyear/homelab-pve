# vmware-k8s — 模板盘验收
#
# packer build 成功只说明"装完了",不代表装出来的东西是我们要的。
# 这里把模板开机连进去,逐条核对:
#
#   1. late-commands 真的执行了(免密 sudo 在)—— 这条最要紧:
#      autoinstall 的 user-data 是 UTF-8,一旦用 PowerShell 的 Get-Content
#      读(默认按 GBK),`late-commands:` 会被粘到上一行注释后面,
#      subiquity 静默跳过整段 late-commands。系统照样装好、SSH 照样通,
#      但免密 sudo、machine-id 重置、host key 清理全都没做。
#   2. clone-prep 服务装了而且 enable 了(不然克隆出来的节点三台一模一样)
#   3. 模板标记文件在(首启时靠它区分"模板"和"克隆出来的")
#   4. cloud-init 跑完了
#   5. 规格对不对(2C / 2G / 20G)
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-template.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\clone.ps1')

$vmx = Join-Path $WorkDir 'packer\output\ubuntu-template\k8s-template.vmx'
if (-not (Test-Path -LiteralPath $vmx)) {
    Stop-WithError "找不到模板 $vmx"
}
$vmrun = Join-Path (Resolve-VmwareInstallDir) 'vmrun.exe'
$sshExe = Get-SshExe
$key = Join-Path $env:USERPROFILE '.ssh\id_rsa'

$failed = 0
$total = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:total++
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failed++ }
}

Write-Step '启动模板'
$running = & $vmrun -T ws list 2>&1 | Out-String
if ($running -notmatch [regex]::Escape($vmx)) {
    & $vmrun -T ws start $vmx nogui | Out-Null
    Start-Sleep -Seconds 5
}
Write-Ok '模板已启动'

Write-Step '等它拿到 IP'
$ip = $null
for ($i = 0; $i -lt 60; $i++) {
    $r = & $vmrun -T ws getGuestIPAddress $vmx -wait 2>&1 | Out-String
    $m = [regex]::Match($r, '\b(\d+\.\d+\.\d+\.\d+)\b')
    if ($m.Success) { $ip = $m.Groups[1].Value; break }
    Start-Sleep -Seconds 5
}
if (-not $ip) {
    Stop-WithError '模板一直没拿到 IP'
}
Write-Ok "模板 IP: $ip"

$known = Join-Path $WorkDir '.cache\known_hosts'
$sshArgs = @(
    '-i', $key,
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', "UserKnownHostsFile=$known",
    '-o', 'ConnectTimeout=10',
    '-o', 'LogLevel=ERROR'
)

function Invoke-Tpl {
    param([string]$Cmd)
    $out = & $sshExe @sshArgs "vagrant@$ip" $Cmd 2>&1
    return [pscustomobject]@{
        Code = $LASTEXITCODE
        Text = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    }
}

Write-Step '等 SSH'
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    $r = Invoke-Tpl 'true'
    if ($r.Code -eq 0) { $ok = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $ok) {
    Write-Host $r.Text
    Stop-WithError '模板 SSH 连不上'
}
Write-Ok 'SSH 通了'

Write-Host ''
Write-Host '=== 1. late-commands 真的执行了吗 ==='
# 免密 sudo 是 late-commands 装的。如果 encoding 出问题,subiquity 会
# 静默跳过整段 late-commands,这一条就会红。
$r = Invoke-Tpl 'sudo -n true && echo NOPASSWD_OK'
Assert-True ($r.Code -eq 0 -and $r.Text -match 'NOPASSWD_OK') '免密 sudo 生效(late-commands 执行了)'
$r = Invoke-Tpl 'ls -l /etc/sudoers.d/99-vagrant 2>/dev/null | wc -l'
Assert-True ($r.Text.Trim() -eq '1') '/etc/sudoers.d/99-vagrant 在'
$r = Invoke-Tpl 'sudo stat -c %a /etc/sudoers.d/99-vagrant'
Assert-True ($r.Text.Trim() -eq '440') 'sudoers 文件权限是 0440'

Write-Host ''
Write-Host '=== 2. clone-prep 装好并且 enable 了 ==='
$r = Invoke-Tpl 'test -f /usr/local/sbin/vmware-clone-prep.sh && echo CLONEPREP_OK'
Assert-True ($r.Text -match 'CLONEPREP_OK') 'clone-prep.sh 在 /usr/local/sbin'
$r = Invoke-Tpl 'test -f /etc/systemd/system/vmware-clone-prep.service && echo UNIT_OK'
Assert-True ($r.Text -match 'UNIT_OK') 'systemd unit 在'
$r = Invoke-Tpl 'systemctl is-enabled vmware-clone-prep.service 2>/dev/null'
Assert-True ($r.Text.Trim() -eq 'enabled') 'clone-prep 服务是 enabled(克隆首启才会跑)'

Write-Host ''
Write-Host '=== 3. 模板标记 ==='
$r = Invoke-Tpl 'test -f /var/lib/vmware-template-sealed && echo SEALED_OK'
Assert-True ($r.Text -match 'SEALED_OK') '模板标记文件在(克隆首启据此重置 machine-id)'

Write-Host ''
Write-Host '=== 4. cloud-init / machine-id / host key ==='
$r = Invoke-Tpl 'cloud-init status 2>/dev/null || echo UNKNOWN'
Write-Host "       cloud-init: $($r.Text.Trim())"
Assert-True ($r.Text.Trim() -in @('done', 'status: done')) 'cloud-init 跑完了'
$r = Invoke-Tpl 'cat /etc/machine-id'
Assert-True ($r.Text.Trim().Length -ge 32) 'machine-id 存在(首启时 systemd 重新生成过)'
$r = Invoke-Tpl 'ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l'
Assert-True ([int]$r.Text.Trim() -ge 3) 'SSH host key 已在首启时重新生成'
$r = Invoke-Tpl 'cat /var/lib/cloud/instance/instance-id 2>/dev/null'
Assert-True ([string]::IsNullOrWhiteSpace($r.Text)) 'cloud instance-id 已清掉'

Write-Host ''
Write-Host '=== 5. 规格 ==='
$r = Invoke-Tpl 'nproc'
Assert-True ($r.Text.Trim() -eq '2') "CPU 是 2 核(实际 $($r.Text.Trim()))"
$r = Invoke-Tpl "free -m | awk '/^Mem:/{print \$2}'"
Assert-True ([int]$r.Text.Trim() -ge 1900 -and [int]$r.Text.Trim() -le 2100) "内存是 2G(实际 $($r.Text.Trim()) MB)"
$r = Invoke-Tpl 'lsblk -no SIZE /dev/sda 2>/dev/null || lsblk -no SIZE $(ls /dev/sd* | head -1)'
Write-Host "       磁盘: $($r.Text.Trim())"

Write-Host ''
Write-Host '=== 6. 顺带看看装了什么 ==='
$r = Invoke-Tpl 'which open-vm-tools vmware-toolbox 2>/dev/null; systemctl is-active open-vm-tools 2>/dev/null'
Assert-True ($r.Text -match 'active') 'open-vm-tools 在跑(克隆前要靠它拿到 IP)'

Write-Host ''
Write-Host '=== 收工:把模板关掉 ==='
& $vmrun -T ws stop $vmx hard 2>&1 | Out-Null
Write-Ok '模板已关闭'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
