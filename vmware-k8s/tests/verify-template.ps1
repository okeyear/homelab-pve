# vmware-k8s — 镜像盘验收
#
# packer build 成功只说明"装完了",不代表装出来的东西是我们要的。
# 这个脚本把镜像开机连进去,逐条核对。
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-template.ps1 -Kind template
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-template.ps1 -Kind base
#
# template 那一层要验的:
#   1. **固定地址是 10.10.10.9** —— 这条最要紧。autoinstall 的 user-data
#      是 UTF-8,一旦用 PowerShell 的 Get-Content 读(默认按 GBK),
#      `network:` 会被粘到上一行注释后面,subiquity 静默跳过整段。
#      系统照样装好、SSH 照样通,但地址不是固定的那个,packer 的
#      ssh_host 指过来就是没人接 —— 白等 40 分钟。
#   2. 模板是**薄**的:没有免密 sudo、没有 clone-prep、没有封存标记。
#      这些都在 base 层做,模板里多一样都是多一个失败面。
#   3. cloud-init 在、open-vm-tools 在、规格对。
#
# base 那一层要验的:
#   1. 免密 sudo 生效(base-setup.sh 装的)
#   2. clone-prep 装了而且 enable 了
#   3. 封存标记在(克隆出来的机器靠它区分身份)
#   4. netplan 已经换成 DHCP(克隆体首启才不会三台抢同一个 IP)
#   5. 基础组件在(kubeadm / containerd)

[CmdletBinding()]
param(
    [ValidateSet('template', 'base')]
    [string]$Kind = 'template'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WorkDir 'lib\common.ps1')
. (Join-Path $WorkDir 'lib\clone.ps1')

if ($Kind -eq 'template') {
    $vmx = Join-Path $WorkDir 'packer\output\k8s-template.vmx'
    $expectIp = '10.10.10.9'
}
else {
    $vmx = Join-Path 'D:\vmware-k8s\k8s-base' 'k8s-base.vmx'
    $expectIp = ''      # base 走 DHCP,地址不固定
}

if (-not (Test-Path -LiteralPath $vmx)) {
    Stop-WithError "找不到镜像 $vmx"
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

Write-Step "启动($Kind)"
$running = & $vmrun -T ws list 2>&1 | Out-String
if ($running -notmatch [regex]::Escape($vmx)) {
    & $vmrun -T ws start $vmx nogui | Out-Null
    Start-Sleep -Seconds 5
}
Write-Ok '已启动'

Write-Step '等它拿到 IP'
$ip = $null
for ($i = 0; $i -lt 60; $i++) {
    $r = & $vmrun -T ws getGuestIPAddress $vmx -wait 2>&1 | Out-String
    $m = [regex]::Match($r, '\b(\d+\.\d+\.\d+\.\d+)\b')
    if ($m.Success) { $ip = $m.Groups[1].Value; break }
    Start-Sleep -Seconds 5
}
if (-not $ip) {
    Stop-WithError '一直没拿到 IP'
}
Write-Ok "IP: $ip"

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
    Stop-WithError 'SSH 连不上'
}
Write-Ok 'SSH 通了'

if ($Kind -eq 'template') {
    Write-Host ''
    Write-Host '=== 1. 固定地址生效了吗 ==='
    # 这条最要紧:地址不是固定的那个,packer 的 ssh_host 就指不到。
    Assert-True ($ip -eq $expectIp) "地址是固定的 $expectIp(实际 $ip)"
    $r = Invoke-Tpl 'ip -4 -o addr show scope global | awk "{print \$4}"'
    Write-Host "       机器上的地址: $($r.Text.Trim())"
    $r = Invoke-Tpl 'grep -rl "10.10.10.9" /etc/netplan/ 2>/dev/null | wc -l'
    Assert-True ([int]$r.Text.Trim() -ge 1) 'netplan 里写着这个固定地址'

    Write-Host ''
    Write-Host '=== 2. 模板是薄的:base 层的东西不该在这儿 ==='
    $r = Invoke-Tpl 'test -f /etc/sudoers.d/99-vagrant && echo HAS_SUDOERS'
    Assert-True (-not ($r.Text -match 'HAS_SUDOERS')) '没有免密 sudo(那是 base 层的事)'
    $r = Invoke-Tpl 'test -f /usr/local/sbin/vmware-clone-prep.sh && echo HAS_CLONEPREP'
    Assert-True (-not ($r.Text -match 'HAS_CLONEPREP')) '没有 clone-prep(那是 base 层的事)'
    $r = Invoke-Tpl 'test -f /var/lib/vmware-k8s-base && echo HAS_MARKER'
    Assert-True (-not ($r.Text -match 'HAS_MARKER')) '没有封存标记(那是 base 层的事)'

    Write-Host ''
    Write-Host '=== 3. 该有的有 ==='
    $r = Invoke-Tpl 'command -v sudo >/dev/null && echo SUDO_OK'
    Assert-True ($r.Text -match 'SUDO_OK') 'sudo 装了(免密还没配,但得在)'
    $r = Invoke-Tpl 'command -v vmware-rpctool >/dev/null && echo TOOLS_OK'
    Assert-True ($r.Text -match 'TOOLS_OK') 'open-vm-tools 装了'
    $r = Invoke-Tpl 'systemctl is-active open-vm-tools 2>/dev/null'
    Assert-True ($r.Text.Trim() -eq 'active') 'open-vm-tools 在跑'
    $r = Invoke-Tpl 'command -v cloud-init >/dev/null && echo CLOUDINIT_OK'
    Assert-True ($r.Text -match 'CLOUDINIT_OK') 'cloud-init 在'
    $r = Invoke-Tpl 'cat /etc/machine-id'
    Assert-True ($r.Text.Trim().Length -ge 32) 'machine-id 存在'
    $r = Invoke-Tpl 'ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l'
    Assert-True ([int]$r.Text.Trim() -ge 3) 'SSH host key 在'
}
else {
    Write-Host ''
    Write-Host '=== 1. 免密 sudo 生效了吗 ==='
    $r = Invoke-Tpl 'sudo -n true && echo NOPASSWD_OK'
    Assert-True ($r.Code -eq 0 -and $r.Text -match 'NOPASSWD_OK') '免密 sudo 生效'
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
    Write-Host '=== 3. 封存标记 ==='
    $r = Invoke-Tpl 'test -f /var/lib/vmware-k8s-base && echo SEALED_OK'
    Assert-True ($r.Text -match 'SEALED_OK') '封存标记在(克隆出来的机器靠它重置身份)'

    Write-Host ''
    Write-Host '=== 4. netplan 已经换成 DHCP ==='
    # 模板的 netplan 配的是固定地址 10.10.10.9。三个节点是从本机克隆
    # 出来的,带着那个地址就会三台抢同一个 IP。base-setup.sh 把它换成
    # DHCP,clone-prep 随后再写死各自的静态 IP。
    $r = Invoke-Tpl 'ls /etc/netplan/ 2>/dev/null | tr "\n" " "'
    Write-Host "       netplan 文件: $($r.Text.Trim())"
    Assert-True ($r.Text -notmatch '00-installer-config.yaml') '模板那个固定地址的配置已经删掉了'
    $r = Invoke-Tpl 'grep -l "dhcp4: true" /etc/netplan/*.yaml 2>/dev/null | wc -l'
    Assert-True ([int]$r.Text.Trim() -ge 1) 'netplan 里改成 DHCP 了'

    Write-Host ''
    Write-Host '=== 5. 基础组件装了吗 ==='
    $r = Invoke-Tpl 'command -v kubeadm >/dev/null && echo KUBEADM_OK'
    Assert-True ($r.Text -match 'KUBEADM_OK') 'kubeadm 在(base 层装的)'
    $r = Invoke-Tpl 'command -v containerd >/dev/null && echo CONTAINERD_OK'
    Assert-True ($r.Text -match 'CONTAINERD_OK') 'containerd 在'
    $r = Invoke-Tpl 'systemctl is-active containerd 2>/dev/null'
    Assert-True ($r.Text.Trim() -eq 'active') 'containerd 在跑'
}

Write-Host ''
Write-Host '=== 规格 ==='
$r = Invoke-Tpl 'nproc'
Assert-True ($r.Text.Trim() -eq '2') "CPU 是 2 核(实际 $($r.Text.Trim()))"
$r = Invoke-Tpl "free -m | awk '/^Mem:/{print \$2}'"
Assert-True ([int]$r.Text.Trim() -ge 1900 -and [int]$r.Text.Trim() -le 2100) "内存是 2G(实际 $($r.Text.Trim()) MB)"

Write-Host ''
Write-Host '=== 收工:把它关掉 ==='
& $vmrun -T ws stop $vmx hard 2>&1 | Out-Null
Write-Ok '已关闭'

Write-Host ''
if ($failed -eq 0) { Write-Host "全部通过 ($total 项)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failed / $total 项失败" -ForegroundColor Red; exit 1 }
