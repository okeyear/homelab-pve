# vmware-k8s — 把模板做成 k8s 基础镜像(k8s-base)
#
# 分层克隆:
#
#   packer 出的最小化模板  ->  k8s-base  ->  三个 k8s 节点
#                            (装好 cloud-init / 换源 / 基础包 /
#                             containerd / k8s 组件)
#
# 这一层干的活:
#   1. 从模板 full clone 出 k8s-base
#   2. 启动,等它拿到地址、等 SSH 通
#   3. 推 guest/base-setup.sh 过去跑(换 apt 源、确认 cloud-init、
#      装 clone-prep、写免密 sudo、打封存标记)
#   4. 推仓库里现成的 setup-k8s/scripts 过去跑(基础包、containerd、
#      k8s 组件)—— 只在用户明确要求的地方改过(地区判定、拆 IPVS)
#   5. 关机。关掉的这台就是"k8s 基础镜像",后面三个节点从它克隆
#
# 为什么要有这一层:
#   - 三个节点从同一张盘克隆,天然一致
#   - 重活失败只要重跑 base 阶段(几分钟),不用重装系统(20 分钟)
#   - 模板保持极薄,packer 阶段失败面最小

Set-StrictMode -Version Latest

function Invoke-GuestRoot {
    <#
      .SYNOPSIS
        在远端以 root 身份跑一条命令。

      .DESCRIPTION
        免密 sudo 这件事是 base-setup.sh 装的 —— 也就是说**第一条**
        root 命令必须自己带密码,之后的都能免密。

        所以这里先探一次 `sudo -n true`:
          - 退出码 0  -> 已经能免密,用 `sudo -n <cmd>`
          - 退出码非 0 -> 还没免密,把密码喂给 `sudo -S`

        为什么非要用 sudo 不可:autoinstall 的 late-commands 失败会
        **中止整场安装**,所以免密 sudo 这步挪到了 base 阶段用 SSH 做;
        而 base 阶段是**非交互**的,sudo 弹密码提示会直接失败
        ("sudo: a terminal is required to read the password")。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Password
    )

    $probe = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command 'sudo -n true' -TimeoutSec 60
    if ($probe.ExitCode -eq 0) {
        $full = "sudo -n $Command"
    }
    else {
        if ($Password.Contains("'")) {
            Stop-WithError "密码里有单引号,没法安全地拼进 sudo 命令: $Password"
        }
        # -S 从标准输入读密码,-p '' 把提示语去掉(否则输出里全是
        # "[sudo] password for xxx:" 这种噪音)。密码从 printf 喂进去。
        $full = "printf '%s\n' '$Password' | sudo -S -p '' $Command"
    }
    return (Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ -Command $full)
}

function Invoke-BuildBase {
    <#
      .SYNOPSIS
        从模板克隆出 k8s-base,在上面装好 k8s 需要的东西,然后关机。
      .OUTPUTS
        k8s-base 的 .vmx 完整路径。三个节点从它克隆。
    #>
    param(
        [Parameter(Mandatory)][string]$VmrunExe,
        [Parameter(Mandatory)][string]$TemplateVmx,
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$KeyFile,
        [Parameter(Mandatory)][string]$KnownHosts,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$RepoRoot,
        # 宿主机上缓存安装包的地方(containerd / runc / CNI 在宿主机下,
        # 再推给 guest —— 见 Initialize-ContainerdArtifacts 的说明)
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][object]$Base,
        [Parameter(Mandatory)][string]$Vnet,
        [Parameter(Mandatory)][string]$K8sMinor
    )

    $sshArgs = New-SshArgs -SshExe $SshExe -KeyFile $KeyFile -KnownHosts $KnownHosts

    # ---- 1. 克隆 ----
    Write-Step "从模板克隆出 $($Base.Name)"
    $null = Copy-TemplateToNode -VmrunExe $VmrunExe -TemplateVmx $TemplateVmx `
        -VmRoot $VmRoot -Node $Base -Vnet $Vnet
    Write-Ok "$($Base.Name) 已克隆"

    # ---- 2. 启动 ----
    Write-Step "启动 $($Base.Name)"
    Start-NodeVm -VmrunExe $VmrunExe -Node $Base

    # ---- 3. 等它拿到地址 ----
    # 模板里装了 open-vm-tools,所以能直接问 VMware 要地址。
    # (节点那一层不用这个 —— 节点的 IP 由 clone-prep 按 guestinfo 写
    #  死在 netplan 里,地址是已知的。)
    Write-Step "等 $($Base.Name) 拿到地址"
    $ip = $null
    for ($i = 0; $i -lt 120; $i++) {
        $ip = Get-NodeGuestIp -VmrunExe $VmrunExe -Node $Base
        if ($ip) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $ip) {
        Stop-WithError "$($Base.Name) 一直拿不到 IP"
    }
    Write-Ok "$($Base.Name) 的地址: $ip"

    # ---- 4. 等 SSH ----
    Write-Step '等 SSH'
    # 先把 known_hosts 里这个地址的旧记录清掉。
    # base 是模板的克隆体,host key 跟模板一样 —— 但如果之前跑过
    # base 阶段(那时模板可能被重新 build 过,host key 变了),
    # 旧记录就会让 ssh 直接拒绝连接:
    #     REMOTE HOST IDENTIFICATION HAS CHANGED!
    Remove-KnownHostEntry -KnownHosts $KnownHosts -Host_ $ip
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip `
            -Command 'echo vmware-k8s-ssh-ok' -TimeoutSec 30
        if ($r.ExitCode -eq 0 -and $r.Output -match 'vmware-k8s-ssh-ok') { $ok = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $ok) {
        Stop-WithError "$($Base.Name) 的 SSH 连不上($ip)"
    }
    Write-Ok 'SSH 通了'

    # ---- 5. 推脚本 ----
    #
    # 目录名要跟 base-setup.sh 里写死的 GUEST_DIR 对上。
    # 之前一个写 /tmp/guest、一个写 /tmp/vmware-k8s-guest,结果
    # base-setup.sh 找不到 clone-prep.sh,**静默跳过**装 clone-prep
    # —— 三个节点克隆出来首启什么都不做,IP 也配不上。
    $guestDir = Join-Path $WorkDir 'guest'
    $remoteGuestDir = '/tmp/vmware-k8s-guest'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Command "rm -rf $remoteGuestDir /tmp/setup-k8s"
    if ($r.ExitCode -ne 0) {
        Stop-WithError "清理远端临时目录失败:`n$($r.Output)"
    }
    $r = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Source $guestDir -Dest $remoteGuestDir -Recurse
    if ($r.ExitCode -ne 0) {
        Stop-WithError "推 guest 脚本失败:`n$($r.Output)"
    }
    $setupDir = Join-Path $RepoRoot 'setup-k8s'
    $r = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Source $setupDir -Dest '/tmp/' -Recurse
    if ($r.ExitCode -ne 0) {
        Stop-WithError "推 setup-k8s 失败:`n$($r.Output)"
    }
    # 去掉 CR 再跑。仓库是在 Windows 上 checkout 的(core.autocrlf
    # = true),推过去的 .sh 每个行尾都是 \r\n。bash 读进去之后,
    # 每行末尾都多个 \r,于是 set 选项不认、变量名对不上,
    # 报出来的是 "command not found" 这种完全指不到真因的错。
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Command "find /tmp/setup-k8s $remoteGuestDir -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"
    if ($r.ExitCode -ne 0) {
        Stop-WithError "归一化换行符失败:`n$($r.Output)"
    }
    Write-Ok '脚本已推送并归一化换行符'

    # ---- 6. 换源 + cloud-init + clone-prep + 免密 sudo ----
    Write-Step '配置基础镜像(换源 / cloud-init / clone-prep / 免密 sudo)'
    $r = Invoke-GuestRoot -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Password $Password -Command "bash $remoteGuestDir/base-setup.sh $User"
    if ($r.ExitCode -ne 0) {
        ($r.Output -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "        $_" }
        Stop-WithError 'base-setup.sh 失败'
    }
    Write-Ok '基础镜像配置完成'

    # ---- 7. 基础包 / containerd / k8s 组件 ----
    # 复用仓库里现成的脚本(只在用户明确要求的地方改过)。
    #
    # 这些脚本内部自己会调 sudo。base-setup.sh 已经把免密 sudo 配好
    # 了,所以这里不用再喂密码 —— 就算 base-setup.sh 没配成功,
    # 也会在这里明确报出来,而不是让脚本卡在密码提示上。
    Write-Step '装基础包 / containerd / k8s 组件'
    # 02-2-containerd.sh 开头就 `cd /tmp/setup-k8s/pkgs/`,而仓库里
    # 没有这个目录(它只是脚本下载 containerd / runc / cni 的落脚点)。
    # cd 失败之后脚本**不会停**(它没有 set -e),而是接着在当前目录
    # 里下载 —— 能跑通,但文件散在 scripts/ 下面,后面找起来很麻烦。
    # 在宿主机这边把目录建出来,仓库里的脚本一个字都不用改。
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip `
        -Command 'mkdir -p /tmp/setup-k8s/pkgs'
    if ($r.ExitCode -ne 0) {
        Stop-WithError "建 /tmp/setup-k8s/pkgs 失败:`n$($r.Output)"
    }

    # 先把 containerd / runc / CNI 的包在**宿主机上**下好推过去。
    # 仓库里的 02-2-containerd.sh 见到文件已经在了就跳过下载
    # (`[ -s <file> ] || wget ...`),所以脚本一个字都不用改。
    # 不这么做的话,VMware 的 NAT 传大文件只有几十 KB/s,
    # 三个包 100MB 要磨好几十分钟。详见 lib\k8s.ps1 里
    # Initialize-ContainerdArtifacts 的说明。
    $null = Initialize-ContainerdArtifacts -SshExe $SshExe -SshArgs $sshArgs -ScpExe $ScpExe `
        -User $User -Host_ $ip -CacheDir $CacheDir

    $pkgScripts = @(
        @{ Name = '01-base-pkgs.sh'; Env = '' },
        @{ Name = '02-2-containerd.sh'; Env = '' },
        @{ Name = '03-kubelet.sh'; Env = "k8sver=v$K8sMinor" }
    )
    # 脚本失败**不立刻中止**,先记下来,最后统一按实际状态判定。
    # 原因见 lib\k8s.ps1 里 Test-K8sPrepReady 的说明:这些脚本
    # 没有 set -e,退出码取自最后一条命令,而最后一条经常是
    # "lsmod | grep ..." 或者"拉个测试镜像"这种跟成败无关的东西。
    $failedScripts = @()
    foreach ($s in $pkgScripts) {
        Write-Info $s.Name
        $cmd = "bash /tmp/setup-k8s/scripts/$($s.Name)"
        if ($s.Env) { $cmd = "$($s.Env) $cmd" }
        $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip -Command $cmd
        if ($r.ExitCode -ne 0) {
            Write-Note "$($s.Name) 退出码 $($r.ExitCode)(先记下,最后看实际状态)"
            ($r.Output -split "`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "        $_" }
            $failedScripts += $s.Name
        }
        else {
            Write-Ok "$($s.Name) 完成"
        }
    }

    # 按实际状态判定:组件齐不齐、内核参数生效没有
    if (-not (Test-K8sPrepReady -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $ip)) {
        Stop-WithError ("基础组件没装好" +
            $(if ($failedScripts.Count) { "(失败/可疑的脚本: $($failedScripts -join ', '))" } else { '' }) +
            "`n    缺 kubeadm / containerd / chronyc 里的哪个,或者" +
            "`n    ip_forward / bridge-nf-call-iptables 没生效。")
    }
    Write-Ok '基础组件已就位(kubeadm / containerd / chronyc + 内核参数)'

    # ---- 8. 关机 ----
    Write-Step "关掉 $($Base.Name)(关掉之后它就是 k8s 基础镜像)"
    Stop-NodeVm -VmrunExe $VmrunExe -Node $Base -Hard
    Start-Sleep -Seconds 3
    Write-Ok "$($Base.Name) 已关机"

    return $Base.Vmx
}
