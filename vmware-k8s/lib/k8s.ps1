# vmware-k8s — 用仓库里现成的 setup-k8s 脚本把集群搭起来
#
# 复用策略:仓库里 setup-k8s/scripts/*.sh 直接拿来用,Windows 这边只做
# main.sh 在 Linux 上做的同一件事 —— 把脚本推过去、用 ssh 跑。
# 唯一区别是传输方式:main.sh 用 rsync,这里用 scp(Windows 自带)。
#
# 例外:仓库脚本只在**用户明确要求**的地方动过(地区判定、拆掉 IPVS、
# 钉死 kube-proxy 代理模式),其余逻辑一个字不改。
#
# 有一处 main.sh 没做的事:装 CNI。main.sh 跑完 join 就结束了,
# 第 57 行还留着 "# todo: which cni plugin to use",集群会停在
# "NotReady"。这里按 $NetworkPlugin 补上这一步。

Set-StrictMode -Version Latest

function New-SshArgs {
    <#
      .SYNOPSIS
        拼出 ssh / scp 的公共参数。
      .DESCRIPTION
        用 accept-new + 自己的一份 known_hosts,而不是
        StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null:
        /dev/null 在 Windows 自带的 OpenSSH 里不存在,Git 自带的那个
        又和系统 ssh 不是一套,混用时行为很怪。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string]$KeyFile,
        [Parameter(Mandatory)][string]$KnownHosts
    )
    @(
        '-i', $KeyFile,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$KnownHosts",
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15',
        '-o', 'LogLevel=ERROR'
    )
}

function Invoke-Ssh {
    <#
      .SYNOPSIS
        在远端跑一条命令,返回退出码和输出。

      .DESCRIPTION
        TimeoutSec 是**远端**超时:命令会被套上 timeout,跑太久就被
        杀掉(退出码 124)。不是掐宿主机上的 ssh 进程 —— 那样远端的
        进程还活着,下次重跑又撞上同一个坑。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 3600
    )
    $target = "$User@$Host_"
    # 走 Invoke-Native,原因见 lib\common.ps1 的说明:
    # ssh 往 stderr 写的东西非常常见(第一次连新机器时的
    # "Warning: Permanently added ... to the list of known hosts."、
    # "REMOTE HOST IDENTIFICATION HAS CHANGED!"、断线原因……),
    # 直接 & 的话在 $ErrorActionPreference='Stop' 下会当场终止脚本,
    # 而后面几处正是靠这些 stderr 文本判断的。
    $remote = Add-RemoteTimeout -Command $Command -TimeoutSec $TimeoutSec
    return (Invoke-Native -Exe $SshExe -Arguments (@($SshArgs) + @($target, $remote)))
}

function Invoke-ScpTo {
    <#
      .SYNOPSIS
        把本地目录/文件拷到远端。
    #>
    param(
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest,
        [switch]$Recurse
    )
    $target = "$User@$Host_"
    $a = @('-P', '22') + $SshArgs
    if ($Recurse) { $a += '-r' }
    return (Invoke-Native -Exe $ScpExe -Arguments ($a + @($Source, "${target}:$Dest")))
}

function Test-NodeSsh {
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_
    )
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ -Command 'echo vmware-k8s-ssh-ok' -TimeoutSec 30
    return ($r.ExitCode -eq 0 -and $r.Output -match 'vmware-k8s-ssh-ok')
}

function Remove-KnownHostEntry {
    <#
      .SYNOPSIS
        把 known_hosts 里某个地址的旧记录删掉。

      .DESCRIPTION
        节点每次克隆都会重新生成 SSH host key(clone-prep 干的),
        所以同一个地址的 key 每轮都不一样。宿主机这边如果不把旧记录
        清掉,连接会直接被拒:

            REMOTE HOST IDENTIFICATION HAS CHANGED!

        刚建好的集群跑得好好的,重跑一次 build 就连不上 —— 而且
        报错长得像"有人劫持了中间人",其实只是自己的旧记录。
    #>
    param(
        [Parameter(Mandatory)][string]$KnownHosts,
        [Parameter(Mandatory)][string]$Host_
    )
    $keygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
    if (-not $keygen) { $keygen = Get-Command 'ssh-keygen' -ErrorAction SilentlyContinue }
    if (-not $keygen) {
        Write-Note '找不到 ssh-keygen,没法清理 known_hosts 的旧记录'
        return
    }
    # 走 Invoke-Native:ssh-keygen 把"已删除哪条记录"写在 stderr 上,
    # 直接 & 的话在 $ErrorActionPreference='Stop' 下会终止脚本。
    $null = Invoke-Native -Exe $keygen.Source -Arguments @('-R', $Host_, '-f', $KnownHosts)
}

function Wait-NodeReady {
    <#
      .SYNOPSIS
        等节点能 ssh,并且 IP 是期望的那个。

      .DESCRIPTION
        只等 ssh 通是不够的:一台机器刚起来、拿到 DHCP 之前,也可能
        恰好有别的地址能连上。必须核对 IP 是我们要的那个,否则后面
        装 k8s 会装到错的机器上。

        节点首启时 clone-prep 会把 DHCP 地址换成静态地址,这个过程要
        一两分钟 —— 中间 ssh 会连不上,这是正常的,一直等就行。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$KnownHosts,
        [int]$TimeoutSec = 600
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = ''
    # 先把旧记录清掉 —— 节点每次克隆都会换 host key
    Remove-KnownHostEntry -KnownHosts $KnownHosts -Host_ $Host_
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
            -Command 'echo vmware-k8s-ssh-ok' -TimeoutSec 30
        if ($r.ExitCode -eq 0 -and $r.Output -match 'vmware-k8s-ssh-ok') {
            # 再核对一下这台机器自己看到的地址
            #
            # 不要在远端跑 `awk '{print $4}'` —— 命令要穿过两层 shell
            # (本地的 ssh 参数 + 远端的 shell),$ 和引号很容易被吃掉,
            # 结果就是 awk 报 "cmd. line:1: {print",核对永远失败。
            # 原始输出拉回宿主机上再解析。
            $ip = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
                -Command 'ip -4 -o addr show scope global' -TimeoutSec 30
            $got = ($ip.Output -split "`n" |
                ForEach-Object { if ($_ -match '\b(\d+\.\d+\.\d+\.\d+)/') { $Matches[1] } } |
                Select-Object -First 1)
            if ($got -and $got.Trim() -eq $Host_) {
                Write-Ok "$Host_ 已就绪 (地址核对通过)"
                return $true
            }
            $last = "ssh 通了,但机器上的地址是 '$($got.Trim())',期望 '$Host_'"
        }
        elseif ($r.Output -match 'REMOTE HOST IDENTIFICATION HAS CHANGED') {
            # 节点换了 host key(每次克隆都会换),把旧记录清掉重来
            Remove-KnownHostEntry -KnownHosts $KnownHosts -Host_ $Host_
            $last = 'host key 变了(节点重新克隆过),已清理 known_hosts'
        }
        else {
            $last = 'ssh 还没通'
        }
        Start-Sleep -Seconds 5
    }
    Write-Fail "$Host_ 在 $TimeoutSec 秒内没就绪: $last"
    return $false
}

function Test-K8sPrepReady {
    <#
      .SYNOPSIS
        探测一台机器上"装集群需要的基础组件"是不是真的到位了。

      .DESCRIPTION
        setup-k8s/scripts/*.sh 一个字都没改,直接复用。但这些脚本
        **没有 set -e**,它们的退出码 = 最后一条命令的退出码。

        01-base-pkgs.sh 的最后一条是:

            sudo rm -f /etc/modules-load.d/ipvs.conf

        (以前是 `lsmod | grep -e ip_vs -e nf_conntrack_ipv4` —— 新内核里
        nf_conntrack_ipv4 已经被并进 nf_conntrack(没有这个模块文件了),
        ip_vs 在某些内核上是**编进内核**而不是做成模块。这两种情况下
        grep 什么都匹配不到,退出码就是 1 —— 可该装的包一个都不少。
        IPVS 那部分拆掉之后换成一条 rm,退出码倒是稳了,但仍然不能
        只看退出码。)

        02-2-containerd.sh 的最后一条是拉一个 busybox 测试镜像,
        镜像站抽风就非零退出,可 containerd 本身装得好好的。

        所以**不看退出码,看实际状态** —— 这些才是真正决定集群能不能
        起来的东西:
          - kubeadm / containerd / chronyc 装上了吗
          - ip_forward 和 bridge-nf-call-iptables 生效了吗

      .OUTPUTS
        $true / $false
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_
    )
    # 命令里**不带双引号**:命令要穿过 ssh 客户端的引号处理,
    # 内层双引号会被转义,远端 shell 看到的东西就不对了。
    $cmd = 'command -v kubeadm >/dev/null 2>&1 && ' +
    'command -v containerd >/dev/null 2>&1 && ' +
    'command -v chronyc >/dev/null 2>&1 && ' +
    'sysctl -n net.ipv4.ip_forward | grep -qx 1 && ' +
    'sysctl -n net.bridge.bridge-nf-call-iptables | grep -qx 1 && ' +
    'echo k8s-prep-ok'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $cmd -TimeoutSec 120
    return ($r.ExitCode -eq 0 -and $r.Output -match 'k8s-prep-ok')
}

function Initialize-ContainerdArtifacts {
    <#
      .SYNOPSIS
        把 containerd / runc / CNI / containerd.service 的安装包在**宿主机上**
        下好,再推到机器上去。

      .DESCRIPTION
        仓库里 setup-k8s/scripts/02-2-containerd.sh 是这么下包的:

            [ -s containerd-<ver>-linux-amd64.tar.gz ] || wget -c "${GHPROXY}https://github.com/..."
            [ -s runc.amd64 ]                              || wget -c ...
            [ -s cni-plugins-linux-amd64-<ver>.tgz ]     || wget -c ...
            [ -s containerd.service ]                    || sudo wget -c ...

        文件已经在了就**跳过下载** —— 所以我们把包下好推过去,
        仓库里的脚本一个字都不用改。

        为什么非得在宿主机上下:VMware 的 NAT(WHP 后端)传大文件只有
        几十 KB/s。实测同一个包:
            guest 里    5.5 MB 下了 4 分钟(约 23 KB/s)
            同一台宿主机 1.6 MB/s(走代理)、5.6 MB/s(直连)
        三个包加起来 100MB,差着几十分钟。

        版本号**由 guest 自己算** —— 用仓库自己的 functions.sh 里的
        get_github_latest_release,跟脚本会挑的版本保证一致(不自己查
        GitHub API,免得两边查到不同版本)。

        下载地址给两个候选:先直连 GitHub,不行再走 ghfast.top 代理
        (跟 functions.sh 在国内时的选择一致)。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$CacheDir,
        [string]$RemoteDir = '/tmp/setup-k8s/pkgs'
    )

    Write-Info '在宿主机上准备 containerd / runc / CNI 的安装包'

    # ---- 1. 问 guest 要版本号和文件名(用仓库自己的 functions.sh)----
    $probe = @'
cd /tmp/setup-k8s/scripts && source ./functions.sh >/dev/null 2>&1
cv=$(get_github_latest_release containerd/containerd); cv=${cv/v/}
rv=$(get_github_latest_release opencontainers/runc)
nv=$(get_github_latest_release containernetworking/plugins)
printf 'ARTIFACT|containerd|containerd-%s-linux-amd64.tar.gz|https://github.com/containerd/containerd/releases/download/v%s/containerd-%s-linux-amd64.tar.gz\n' "$cv" "$cv" "$cv"
printf 'ARTIFACT|runc|runc.amd64|https://github.com/opencontainers/runc/releases/download/%s/runc.amd64\n' "$rv"
printf 'ARTIFACT|cni|cni-plugins-linux-amd64-%s.tgz|https://github.com/containernetworking/plugins/releases/download/%s/cni-plugins-linux-amd64-%s.tgz\n' "$nv" "$nv" "$nv"
printf 'ARTIFACT|service|containerd.service|https://raw.githubusercontent.com/containerd/containerd/main/containerd.service\n'
'@
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $probe -TimeoutSec 180
    $lines = @($r.Output -split "`n" | Where-Object { $_ -match '^ARTIFACT\|' })
    if ($lines.Count -eq 0) {
        Write-Note "问不到版本号(输出: $($r.Output)),让脚本自己下载"
        return
    }
    $artifacts = @()
    foreach ($l in $lines) {
        $p = $l.Trim() -split '\|'
        if ($p.Count -lt 4) { continue }
        $artifacts += @{ Kind = $p[1]; Name = $p[2]; Url = $p[3] }
    }
    Write-Ok ("版本号: " + (($artifacts | ForEach-Object { "$($_.Kind)=$($_.Name)" }) -join ', '))

    # ---- 2. 宿主机上下载 ----
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    $local = @()
    foreach ($a in $artifacts) {
        $dest = Join-Path $CacheDir $a.Name
        if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 0) {
            Write-Ok "$($a.Name) 已经在本地缓存里"
            $local += $dest
            continue
        }
        # 先直连,不行再走代理
        $urls = @($a.Url, ("https://ghfast.top/" + $a.Url))
        $got = $false
        foreach ($u in $urls) {
            try {
                Invoke-Download -Uri $u -OutFile $dest -TimeoutSec 1800
                if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 0) {
                    $got = $true
                    break
                }
            }
            catch {
                Write-Note "下载失败($u): $($_.Exception.Message)"
            }
        }
        if (-not $got) {
            Stop-WithError "下不到 $($a.Name),让脚本自己去试试(可能会很慢)"
        }
        $local += $dest
    }

    # ---- 3. 推过去 ----
    foreach ($f in $local) {
        $rr = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
            -Source $f -Dest "$RemoteDir/"
        if ($rr.ExitCode -ne 0) {
            Stop-WithError "推送 $(Split-Path -Leaf $f) 失败:`n$($rr.Output)"
        }
    }
    Write-Ok ("安装包已推送到 {0}(脚本会跳过下载)" -f $RemoteDir)
}

function Get-NotReadySystemPods {
    <#
      .SYNOPSIS
        从 `kubectl get pods -A --no-headers` 的输出里，挑出
        kube-system 里**还没真正跑起来**的 pod。

      .DESCRIPTION
        单独拎出来是为了能直接测(不需要连集群)。

        为什么要单独看 pod:节点显示 Ready **不等于**集群可用。
        节点 Ready 是 kubelet 自己报的,跟网络插件没关系 —— 2026-10-20
        实跑就撞到过:calico-node 三个 pod 全卡在 Init:ErrImagePull,
        节点却三个都是 Ready,阶段于是报"成功"退出,可集群根本没网。

        判据(pod 那一行是: NAMESPACE NAME READY STATUS RESTARTS AGE ...):
          - STATUS 必须是 Running
          - READY 必须是 N/N(全就绪),不是 0/1
          - Completed 的 pod 跳过(跑完就走的,不是常驻的)
    #>
    param([string[]]$PodLines)

    $bad = @()
    foreach ($line in $PodLines) {
        if ($line -notmatch '^kube-system\s') { continue }
        $p = @($line -split '\s+' | Where-Object { $_ -ne '' })
        if ($p.Count -lt 4) { $bad += $line; continue }
        $readyCol = $p[2]
        $statusCol = $p[3]
        if ($statusCol -eq 'Completed') { continue }
        if ($statusCol -ne 'Running') { $bad += $line; continue }
        # READY 必须是 N/N,0/1 也不算就绪
        if ($readyCol -notmatch '^(\d+)/\1$') { $bad += $line; continue }
    }
    return $bad
}

function Get-ClusterState {
    <#
      .SYNOPSIS
        看一眼集群现在的状态:节点有没有全 Ready、pod 有没有卡在拉镜像、
        kube-system 的 pod 有没有都跑起来。

      .DESCRIPTION
        两条命令都是 --no-headers 的纯文本输出,拉回宿主机上解析 ——
        别在远端跑 awk(命令要穿过两层 shell,$ 和引号很容易被吃掉)。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_
    )
    $nodes = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers' `
        -TimeoutSec 120
    $pods = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A --no-headers' `
        -TimeoutSec 120
    $nodeLines = @($nodes.Output -split "`n" | Where-Object { $_.Trim() -ne '' })
    $podLines = @($pods.Output -split "`n" | Where-Object { $_.Trim() -ne '' })

    $notReady = @($nodeLines | Where-Object { $_ -notmatch '\sReady\s' })
    $pullFail = @($podLines | Where-Object { $_ -match 'ImagePullBackOff|ErrImagePull|ImagePullError' })
    $sysBad = @(Get-NotReadySystemPods -PodLines $podLines)
    [pscustomobject]@{
        NodeLines = $nodeLines
        PodLines  = $podLines
        # 节点这一行是: NAME STATUS ROLES AGE VERSION
        AllReady  = ($nodeLines.Count -gt 0 -and $notReady.Count -eq 0)
        PullFailed = ($pullFail.Count -gt 0)
        PullFailing = $pullFail
        # 节点 Ready 只是 kubelet 自己报的,跟网络插件没关系 ——
        # 集群"真能用"还得看 kube-system 的 pod 有没有都跑起来。
        SystemPodsReady = ($sysBad.Count -eq 0)
        SystemBadPods   = $sysBad
    }
}

function Wait-ClusterReady {
    <#
      .SYNOPSIS
        等集群真的可用(所有节点 Ready)。
      .OUTPUTS
        'READY' / 'PULL_FAILED' / 'TIMEOUT'

      .DESCRIPTION
        IgnorePullFailure 是给"已经修过镜像源"之后的那一轮用的:
        改完 DaemonSet 的镜像,老 pod 会在被替换掉之前**继续挂着**
        ImagePullBackOff 状态。这时候立刻返回 PULL_FAILED 就是误判 ——
        所以那一轮忽略这个信号,一直等到节点真的 Ready 或者超时。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [int]$TimeoutSec = 900,
        [switch]$IgnorePullFailure
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = ''
    $lastPull = @()
    $lastBad = @()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $st = Get-ClusterState -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_
        if ($st.PullFailed) {
            $lastPull = @($st.PullFailing | Select-Object -First 6)
            if (-not $IgnorePullFailure) {
                Write-Fail '有 pod 卡在拉镜像:'
                $lastPull | ForEach-Object { Write-Host "       $_" }
                return 'PULL_FAILED'
            }
            Write-Info '还有 pod 在拉镜像(已忽略这个信号,继续等)'
        }
        # 判据是"节点全 Ready **而且** kube-system 的 pod 都跑起来"。
        # 只看节点会误判:节点 Ready 是 kubelet 自己报的,calico 没装好
        # 的时候三个节点照样都是 Ready,可集群根本没有网络。
        if ($st.AllReady -and $st.SystemPodsReady) { return 'READY' }
        $lastBad = @($st.SystemBadPods | Select-Object -First 6)
        $last = ($st.NodeLines -join ' | ')
        Start-Sleep -Seconds 10
    }
    Write-Fail "集群在 $TimeoutSec 秒内没就绪: $last"
    if ($lastBad.Count -gt 0) {
        Write-Fail 'kube-system 里还没跑起来的 pod:'
        $lastBad | ForEach-Object { Write-Host "       $_" }
    }
    if ($lastPull.Count -gt 0) {
        Write-Fail '最后看到的拉镜像失败:'
        $lastPull | ForEach-Object { Write-Host "       $_" }
    }
    return 'TIMEOUT'
}

function New-CniRepairCommand {
    <#
      .SYNOPSIS
        生成"把 CNI manifest 的镜像地址换回官方源再 apply"的命令。

      .DESCRIPTION
        单独拎出来是为了能直接测。sed 的 s 命令要**三个**分隔符:

            s<分隔符><模式><分隔符><替换><分隔符><标志>

        少写一个中间的分隔符,sed 会把 "From+To" 整个当成模式,然后报

            sed: -e expression #1, char 69: unterminated `s' command

        —— 报错里完全看不出是分隔符少了一个,实际是 2026-10-20
        第一次实跑 CNI 兜底时踩到的。
    #>
    param(
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    return ("cd /tmp/setup-k8s/scripts && " +
        "sed -i 's@$From@$To@g' $Manifest && " +
        "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f $Manifest")
}

function Repair-CniImageRegistry {
    <#
      .SYNOPSIS
        CNI 的镜像拉不下来时,把镜像地址换回官方源再 apply 一次。

      .DESCRIPTION
        仓库里的 08-2-cni-calico.sh 有一行:

            sed -i 's@image: quay.io/calico/@image: registry.cn-beijing.aliyuncs.com/my-dockermirrors/@g' calico.yaml

        registry.cn-beijing.aliyuncs.com/my-dockermirrors/ 是个
        **Docker Hub** 的拉取缓存,而 calico 的官方镜像在 **quay.io**
        上 —— 缓存里根本没有,于是 pod 全卡在 ImagePullBackOff,
        节点一直 NotReady。(08-3-cni-cilium.sh 里 MIRRORS 指向同一个
        地方,同样的问题。)

        仓库里的脚本一个字都不改 —— 这里在它跑完之后,把生成出来的
        manifest 里的镜像地址换回去,再 apply 一次。

        实测从这台机器的 guest 拉 quay.io 有 2.9MB/s,完全够用。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    Write-Info ("把 {0} 里的镜像地址换回 {1}" -f $From, $To)
    # sed 的 s 命令是 s<分隔符><模式><分隔符><替换><分隔符><标志>,
    # **三个**分隔符。这里用 @ 当分隔符,所以 From 后面必须还有一个 @。
    # 少写一个的后果很隐蔽:sed 会把 "From+To" 整个当成模式,报
    #   sed: -e expression #1, char 69: unterminated `s' command
    # —— 报错里完全看不出是分隔符少了一个。
    $cmd = New-CniRepairCommand -Manifest $Manifest -From $From -To $To
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $cmd -TimeoutSec 300
    if ($r.ExitCode -ne 0) {
        Write-Fail "换镜像地址后 apply 失败:`n$($r.Output)"
        return $false
    }
    Write-Ok '已用官方源重新 apply'
    return $true
}

function Resolve-K8sFullVersion {
    <#
      .SYNOPSIS
        问 dl.k8s.io 要这个小版本的最新补丁号。
      .DESCRIPTION
        config.sh 里的 K8S_VERSION 要的是**完整**版本号 —— 仓库的
        main.sh 用 ${K8S_VERSION%.*} 取 major.minor,所以光有
        "1.34" 不够(那会变成空)。

        dl.k8s.io/release/stable-<minor>.txt 是 kubernetes 自己的
        机器可读端点,纯文本,仓库里 10-setup-kubeadm-cluster.yml
        用的也是它。拿不到就退化成 <minor>.0,总比空着强。
    #>
    param([Parameter(Mandatory)][string]$Minor)
    try {
        $r = Invoke-WebRequest -Uri "https://dl.k8s.io/release/stable-$Minor.txt" `
            -UseBasicParsing -TimeoutSec 30
        $v = ($r.Content -split "`n" | Where-Object { $_.Trim() -match '^v\d+\.\d+\.\d+$' } |
            Select-Object -First 1)
        if ($v) { return ($v.Trim() -replace '^v', '') }
    }
    catch {
        Write-Note "查不到 k8s $Minor 的完整版本号,按 $Minor.0 处理: $($_.Exception.Message)"
    }
    return "$Minor.0"
}

function New-K8sConfigContent {
    <#
      .SYNOPSIS
        生成 setup-k8s/config.sh 的内容。
      .DESCRIPTION
        单独拎出来是为了能直接测 —— 这段内容以前是写在
        Invoke-K8sStage 里的一个可展开 here-string,里面藏着两个坑:

          1. ${CLUSTER_NAME:-"devops-k8s"} 这种 shell 默认值语法会被
             PowerShell 当成变量引用吃掉 —— 实测输出变成 "CLUSTER_NAME=",
             下次用 main.sh 管这个集群就少一个变量。
          2. 同一个 here-string 里写的 $K8sVersion 根本没定义,严格模式下
             直接抛错。而这行偏偏是集群装完之后才执行的 —— 报错的时候
             集群已经起来了,最让人难受。

        所以:单引号字符串保持字面量(shell 语法原样保留),要插值的
        地方单独用双引号,并且把 shell 自己的 $ 用反引号转义。
    #>
    param(
        [Parameter(Mandatory)][object[]]$Masters,
        [Parameter(Mandatory)][object[]]$Workers,
        [Parameter(Mandatory)][string]$K8sVersion,
        [Parameter(Mandatory)][string]$PodCidr,
        [Parameter(Mandatory)][string]$ServiceCidr,
        [Parameter(Mandatory)][string]$LoadBalancer,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$NetworkPlugin
    )
    $lines = @(
        "# 由 vmware-k8s/build.ps1 自动生成 —— $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        'CLUSTER_NAME=${CLUSTER_NAME:-"devops-k8s"}'
        "K8S_VERSION=`${K8S_VERSION:-$K8sVersion}"
        "POD_CIDR=$PodCidr"
        "SERVICE_CIDR=$ServiceCidr"
        'NODE_PORT_RANGE=30000-32767'
        'IMAGE_REPO=registry.aliyuncs.com/google_containers'
        ('MASTER_NODES=(' + (($Masters | ForEach-Object { '"' + $_.Address + '"' }) -join ' ') + ')')
        "LoadBalancer='$LoadBalancer'"
        ('WORKER_NODES=(' + (($Workers | ForEach-Object { '"' + $_.Address + '"' }) -join ' ') + ')')
        "NODE_USER=$User"
        'SSH_KEY_PATH=~/.ssh/id_rsa'
        "NETWORK_PLUGIN=`"$NetworkPlugin`""
        'ENABLE_METALLB=false'
    )
    # 强制 LF:这个文件要被 Linux 当 shell 脚本 source,CRLF 会让
    # MASTER_NODES=("10.10.10.11") 变成 "10.10.10.11") 之类的怪东西。
    return ((($lines -join "`n") -replace "`r", '') + "`n")
}

# ---------------------------------------------------------------- 地区判定

function Resolve-Region {
    <#
      .SYNOPSIS
        判定这台机器算不算"在国内",返回国家代码(默认 CN)。

      .DESCRIPTION
        **直接问 guest 上仓库自己的 detect_region()** —— 不另写一套探测
        逻辑,免得两边判出不一样的结果。

        仓库的 setup-k8s/scripts/functions.sh 里现在有 detect_region():
        一家一家问过去(ipinfo.io / ipwho.is / sysad.win / ip-api.com),
        谁先答出合法国家码就用谁。这已经比"只问 ipinfo.io"稳得多,
        但仍然是看运气 —— 四家全挂时 REGION 是空,脚本会走 else 分支
        改用 registry.k8s.io 拉控制面镜像。

        而 registry.k8s.io 的 manifest 请求会 307 跳到
        europe-west3-docker.pkg.dev —— 这个域名在国内是
        "connection refused",containerd 会一直重试,kubeadm init
        永远不返回,节点则因为拿不到 /var/lib/kubelet/config.yaml
        一直崩溃重启。

        所以这里问一次,把结果**固定**下来,再用 BASH_ENV 注入给
        仓库脚本(见 guest/region-shim.sh)。
        问不到就用缓存,再问不到就默认 CN —— 阿里云的镜像源在
        境外也能用,当 CN 处理不会把流程卡死。

        顺序:guest 实测 -> 缓存 -> 默认。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [string]$CacheDir = ''
    )

    $cacheFile = ''
    if ($CacheDir) {
        $stateDir = Join-Path $CacheDir 'state'
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        $cacheFile = Join-Path $stateDir 'region.txt'
    }

    # ---- 1. 问 guest:跑仓库自己的 detect_region ----
    #
    # source 的输出全部丢掉(它里面还有 color_echo 之类的东西),
    # 只留 detect_region 打印出来的那两三个字母。
    # 命令里不带双引号(远端命令要穿过 ssh 客户端的引号处理)。
    $cmd = 'cd /tmp/setup-k8s/scripts && source ./functions.sh >/dev/null 2>&1 && detect_region'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $cmd -TimeoutSec 300
    $m = [regex]::Match([string]$r.Output, '(?m)^([A-Z]{2})\s*$')
    if ($m.Success) {
        $region = $m.Groups[1].Value.ToUpperInvariant()
        Write-Ok "地区判定: $region(guest 上跑仓库的 detect_region)"
        if ($cacheFile) { Write-Utf8Text $cacheFile $region }
        return $region
    }

    # ---- 2. 缓存 ----
    if ($cacheFile -and (Test-Path -LiteralPath $cacheFile)) {
        $cached = (Read-Utf8Text $cacheFile).Trim().ToUpperInvariant()
        if ($cached -match '^[A-Z]{2}$') {
            Write-Note "guest 上问不到地区,用缓存里的 $cached"
            return $cached
        }
    }

    # ---- 3. 默认 ----
    Write-Note '问不到地区,按 CN 处理(国内镜像源在境外也能用)'
    return 'CN'
}

function Install-RegionShim {
    <#
      .SYNOPSIS
        把地区补丁和地区结果推到节点上。

      .DESCRIPTION
        补丁脚本是 guest/region-shim.sh,它会用 shell 函数把
        `curl ipinfo.io` 拦下来,返回固定的国家代码。
        仓库的脚本一个都不用改 —— 补丁是通过 BASH_ENV 注入的。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$ShimFile,
        [Parameter(Mandatory)][string]$Region,
        [string]$RemoteDir = '/tmp/vmware-k8s'
    )
    if (-not (Test-Path -LiteralPath $ShimFile)) {
        Stop-WithError "找不到地区补丁脚本: $ShimFile"
    }
    $null = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command "mkdir -p $RemoteDir" -TimeoutSec 60
    $r = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Source $ShimFile -Dest "$RemoteDir/region-shim.sh"
    if ($r.ExitCode -ne 0) {
        Stop-WithError "推地区补丁到 $Host_ 失败:`n$($r.Output)"
    }
    # region.txt 用 printf 写,不用 echo —— echo 在某些 shell 里
    # 会把反斜杠当转义处理。
    $null = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command "printf '%s' '$Region' > $RemoteDir/region.txt" -TimeoutSec 60
}

function Invoke-RepoScript {
    <#
      .SYNOPSIS
        在远端跑仓库里的 setup-k8s/scripts/*.sh。

      .DESCRIPTION
        和直接 ssh 跑的区别只有两点:

          1. 注入 BASH_ENV=地区补丁 —— 让 functions.sh 的地区判断
             变确定(见 Resolve-Region)。
          2. 套上 timeout —— 仓库脚本没有 set -e,而且里面全是
             没有超时的 wget/curl。实测 kubeadm init 因为拉不到
             镜像整整挂了 15 分钟,整个 build 干等着。

        仓库里的脚本一个字都不改。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$ScriptEnv = @{},
        [int]$TimeoutSec = 900,
        [string]$RemoteDir = '/tmp/vmware-k8s',
        # 跑脚本之前先 cd 到哪儿。仓库里的 CNI 脚本用 curl -O 把
        # manifest 下载到**当前目录**,后面的修补步骤按
        # /tmp/setup-k8s/scripts 去找它,所以这里必须保持一致。
        [string]$WorkingDir = ''
    )
    $assign = @()
    foreach ($k in $ScriptEnv.Keys) { $assign += "$k=$($ScriptEnv[$k])" }
    $assign += "BASH_ENV=$RemoteDir/region-shim.sh"
    $cmd = ($assign -join ' ') + " bash $Script"
    if ($WorkingDir) {
        $cmd = "cd $WorkingDir && $cmd"
    }
    return (Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $cmd -TimeoutSec $TimeoutSec)
}

# ---------------------------------------------------------------- 集群重置

function Reset-K8sNode {
    <#
      .SYNOPSIS
        把一台节点上残留的集群痕迹清干净。

      .DESCRIPTION
        这一步是"k8s 阶段能重跑"的前提。重跑一次 build 时,节点上还
        留着上一次的 /etc/kubernetes(kubelet.conf、admin.conf)和
        旧集群的成员关系,直接 kubeadm init 会报
        "the cluster already exists",worker 也会报
        "This node has already joined the cluster"。

        顺带解决另一个坑:上一次如果是在 kubeadm init 挂死的状态下
        被掐掉的,机器上还留着那个挂死的 kubeadm init 进程。它会
        一直占着,新的 kubeadm init 起来之后互相打架。

        pkill 的模式写成 'kubeadm ini[t]' —— 方括号让模式匹配不到
        pkill 自己那条命令行,否则 pkill 会先把执行它的 shell 干掉。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string[]]$SshArgs,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host_
    )
    $cmd = 'sudo pkill -f kubeadm\ ini[t] >/dev/null 2>&1 ; ' +
           'sudo pkill -x kubelet >/dev/null 2>&1 ; ' +
           'sudo systemctl stop kubelet >/dev/null 2>&1 ; ' +
           'sudo kubeadm reset -f >/tmp/kubeadm-reset.log 2>&1 ; ' +
           'sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd ; ' +
           'sudo systemctl start kubelet >/dev/null 2>&1 ; ' +
           'echo RESET-DONE'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
        -Command $cmd -TimeoutSec 300
    if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'RESET-DONE') {
        Write-Note "$Host_ 重置返回异常(先记下,继续): $($r.Output)"
        return $false
    }
    return $true
}

function Invoke-K8sStage {
    <#
      .SYNOPSIS
        完整的 k8s 集群搭建流程。
    #>
    param(
        [Parameter(Mandatory)][string]$SshExe,
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$KeyFile,
        [Parameter(Mandatory)][string]$KnownHosts,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$RepoRoot,
        # 宿主机上缓存安装包的地方(见 Initialize-ContainerdArtifacts)
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$K8sMinor,        # 1.34
        [Parameter(Mandatory)][string]$NetworkPlugin,   # calico / flannel / cilium
        [Parameter(Mandatory)][string]$PodCidr,
        [Parameter(Mandatory)][string]$ServiceCidr,
        [Parameter(Mandatory)][string]$LoadBalancer,
        # 地区补丁脚本(guest/region-shim.sh)的宿主机路径
        [Parameter(Mandatory)][string]$ShimFile,
        [switch]$SkipCni
    )

    $sshArgs = New-SshArgs -SshExe $SshExe -KeyFile $KeyFile -KnownHosts $KnownHosts
    $setupDir = Join-Path $RepoRoot 'setup-k8s'
    if (-not (Test-Path -LiteralPath $setupDir)) {
        Stop-WithError "找不到 $setupDir"
    }

    $masters = @($Nodes | Where-Object { $_.Role -eq 'master' })
    $workers = @($Nodes | Where-Object { $_.Role -eq 'worker' })
    if ($masters.Count -ne 1) {
        Stop-WithError "需要正好 1 个 master,现在是 $($masters.Count) 个"
    }
    $master = $masters[0]

    # ---- 1. 把 setup-k8s 推到每个节点 ----
    #
    # 顺序有讲究:地区判定要靠仓库自己的 detect_region(),而它就在
    # setup-k8s/scripts/functions.sh 里 —— 所以得先把脚本推上去。
    Write-Step '推送 setup-k8s 到各节点'
    foreach ($n in $Nodes) {
        $r = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $sshArgs -User $User -Host_ $n.Address `
            -Source $setupDir -Dest '/tmp/' -Recurse
        if ($r.ExitCode -ne 0) {
            Stop-WithError "推送到 $($n.Address) 失败:`n$($r.Output)"
        }
        # 去掉 CR 再跑。仓库是在 Windows 上 checkout 的(core.autocrlf
        # = true),推过去的 .sh 每个行尾都是 \r\n。bash 读进去之后,
        # 每行末尾都多个 \r,于是 set 选项不认、变量名对不上,
        # 报出来的是 "command not found" 这种完全指不到真因的错。
        # 在宿主机上 normalize 不靠谱(git 怎么 checkout 说了算),
        # 在 guest 上兜住才稳。
        $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address `
            -Command "find /tmp/setup-k8s -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"
        if ($r.ExitCode -ne 0) {
            Stop-WithError "在 $($n.Address) 上归一化换行符失败:`n$($r.Output)"
        }
        Write-Ok "已推送 -> $($n.Address)"
    }

    # ---- 2. 地区判定 + 注入补丁 ----
    #
    # 仓库的 functions.sh 用 detect_region() 判断自己在不在国内(问四家,
    # 谁先答出国家码就用谁)。它已经比"只问 ipinfo.io"稳,但仍然是
    # 看运气 —— 四家全挂时 REGION 是空,脚本会改用 registry.k8s.io 拉
    # 控制面镜像,而那个地址的 manifest 请求会 307 跳到
    # europe-west3-docker.pkg.dev,国内是 connection refused,
    # containerd 无限重试,kubeadm init 永远不返回。
    #
    # 这里先在 guest 上真的问一次(问不到就用缓存/默认 CN),再用
    # BASH_ENV 把结果固定下来注入给仓库脚本。
    Write-Step '判定地区并注入补丁'
    $region = Resolve-Region -SshExe $SshExe -SshArgs $sshArgs -User $User `
        -Host_ $master.Address -CacheDir $CacheDir
    if (-not (Test-Path -LiteralPath $ShimFile)) {
        Stop-WithError "找不到地区补丁脚本: $ShimFile"
    }
    foreach ($n in $Nodes) {
        $null = Install-RegionShim -SshExe $SshExe -SshArgs $sshArgs -ScpExe $ScpExe `
            -User $User -Host_ $n.Address -ShimFile $ShimFile -Region $region
    }

    # ---- 2. 清掉上一次留下的集群痕迹 ----
    #
    # 没有这一步,-Stage k8s 就只能跑一次:第二次 init 会报
    # "the cluster already exists",worker 会报 "This node has
    # already joined the cluster"。
    #
    # 顺带把上一次挂死的 kubeadm init 进程杀掉 —— 它会占着不放,
    # 新的 init 起来之后两个进程互相打架。
    Write-Step '重置各节点上的集群状态'
    foreach ($n in $Nodes) {
        $resetOk = Reset-K8sNode -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address
        if ($resetOk) {
            Write-Ok "$($n.Address): 已重置"
        }
    }

    # ---- 3. 基础包 / containerd / kubelet ----
    #
    # 这三个脚本在 base 阶段已经在 k8s-base 上装过了,节点是从 base
    # 克隆来的,东西都在。这里**先探一下**,已经有了就跳过 ——
    # 02-2-containerd.sh 每次都要重新下载 containerd / runc / cni
    # 三个包,三台节点重跑一遍要多花好几分钟,没必要。
    #
    # 但不能简单地"默认跳过":单独跑 -Stage k8s 的时候,节点可能是
    # 别的方式来的,那就得老老实实装一遍。所以是**探测**,不是假设。
    $pkgScripts = @(
        @{ Name = '01-base-pkgs.sh'; Env = @{} },
        @{ Name = '02-2-containerd.sh'; Env = @{} },
        @{ Name = '03-kubelet.sh'; Env = @{ k8sver = "v$K8sMinor" } }
    )
    foreach ($n in $Nodes) {
        $have = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address `
            -Command 'command -v kubeadm >/dev/null 2>&1 && command -v containerd >/dev/null 2>&1 && echo k8s-prep-ok' `
            -TimeoutSec 60
        if ($have.ExitCode -eq 0 -and $have.Output -match 'k8s-prep-ok') {
            Write-Ok ("{0}: 基础组件已就位(kubeadm + containerd),跳过重装" -f $n.Address)
            continue
        }
        Write-Info ("{0}: 缺基础组件,补装" -f $n.Address)
        # 02-2-containerd.sh 开头就 `cd /tmp/setup-k8s/pkgs/`,而仓库里
        # 没有这个目录(它只是脚本下载 containerd / runc / cni 的落脚点)。
        # cd 失败之后脚本**不会停**(它没有 set -e),而是接着在当前目录
        # 里下载 —— 能跑通,但文件散在 scripts/ 下面。在宿主机这边把目录
        # 建出来,仓库里的脚本一个字都不用改。
        $null = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address `
            -Command 'mkdir -p /tmp/setup-k8s/pkgs'
        # 安装包在宿主机上准备,再推过去 —— 见 Initialize-ContainerdArtifacts
        # 的说明(NAT 传大文件只有几十 KB/s)。
        $null = Initialize-ContainerdArtifacts -SshExe $SshExe -SshArgs $sshArgs -ScpExe $ScpExe `
            -User $User -Host_ $n.Address -CacheDir $CacheDir
        # 脚本失败**不立刻中止**:这些脚本没有 set -e,退出码取自最后
        # 一条命令(常见的是 "lsmod | grep ..." 或拉个测试镜像),
        # 跟实际成败无关。真正的判据是装完之后的状态,见
        # Test-K8sPrepReady。
        $scriptFails = @()
        foreach ($s in $pkgScripts) {
            Write-Info "$($n.Address): $($s.Name)"
            $r = Invoke-RepoScript -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address `
                -Script "/tmp/setup-k8s/scripts/$($s.Name)" -ScriptEnv $s.Env -TimeoutSec 1800
            if ($r.ExitCode -ne 0) {
                Write-Note "$($n.Address): $($s.Name) 退出码 $($r.ExitCode)(先记下,最后看实际状态)"
                ($r.Output -split "`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "        $_" }
                $scriptFails += $s.Name
            }
            else {
                Write-Ok "$($n.Address): $($s.Name) 完成"
            }
        }
        if (-not (Test-K8sPrepReady -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address)) {
            Write-Fail "$($n.Address) 基础组件没装好,输出尾部:"
            ($r.Output -split "`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "        $_" }
            Stop-WithError ("节点 $($n.Address) 装基础组件失败" +
                $(if ($scriptFails.Count) { "(失败/可疑的脚本: $($scriptFails -join ', '))" } else { '' }))
        }
        Write-Ok "$($n.Address): 基础组件已就位"
    }

    # ---- 4. kubeadm init ----
    Write-Step "kubeadm init (master: $($master.Address))"
    $masterList = ($masters | ForEach-Object { $_.Address }) -join ','
    # 走 Invoke-RepoScript:注入地区补丁(让 functions.sh 稳定地选国内
    # 镜像源)+ 套上 timeout(拉不到镜像时 kubeadm init 会一直挂着)。
    $r = Invoke-RepoScript -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Script '/tmp/setup-k8s/scripts/04-kubeadm-init.sh' -TimeoutSec 1200 `
        -ScriptEnv @{
            MASTER_NODES = $masterList
            VIP          = $LoadBalancer
            POD_CIDR     = $PodCidr
            SERVICE_CIDR = $ServiceCidr
        }
    if ($r.ExitCode -ne 0) {
        # 脚本的最后一句是
        #     cp /etc/kubernetes/admin.conf ~/.kube/config
        # 而 admin.conf 是 root 权限 600 —— 用普通用户跑必然
        # "Permission denied",于是退出码非 0。kubeadm init 本身
        # 成没成功,看下面能不能签发 join token 才知道。
        # 仓库里的脚本一个字都不改,这一段在宿主机这边补上。
        Write-Note "04-kubeadm-init.sh 退出码 $($r.ExitCode)(最后那句 cp 需要 root,不代表 init 失败)"
        ($r.Output -split "`n" | Select-Object -Last 12) | ForEach-Object { Write-Host "        $_" }
    }
    # 补上脚本没做成的那一步:把 admin.conf 放到 vagrant 用户下,
    # 这样 vagrant 也能直接跑 kubectl(CNI 脚本里的
    # `kubectl apply -f calico.yaml` 就是普通用户跑的)。
    #
    # 用 `sudo cat > 文件` 而不是 `sudo cp`:重定向是**用户的 shell**
    # 做的,文件归 vagrant;sudo cp 建出来的文件归 root,普通用户
    # 读不了(admin.conf 本身是 600)。
    $null = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Command 'mkdir -p ~/.kube && sudo cat /etc/kubernetes/admin.conf > ~/.kube/config && chmod 600 ~/.kube/config'

    # ---- 5. 生成 join 命令 ----
    # 这一步同时也是 kubeadm init 到底成没成功的判据:
    # 签发 token 需要 apiserver 已经在跑。
    Write-Step '生成 worker join 命令'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Command 'sudo kubeadm token create --print-join-command'
    $join = ($r.Output -split "`n" | Where-Object { $_.Trim() -match 'kubeadm join' } | Select-Object -First 1)
    if (-not $join) {
        Write-Fail '拿不到 join 命令,kubeadm init 应该是没成功。输出尾部:'
        ($r.Output -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "        $_" }
        Stop-WithError 'kubeadm init 失败'
    }
    Write-Ok "join 命令: $($join.Trim())"

    # 写成脚本再分发 —— 命令里有引号,直接 ssh 传过去很容易被 shell 吃掉一层。
    # 必须不带 BOM:5.1 的 Set-Content -Encoding UTF8 会加 BOM,而
    # BOM 紧挨着 "#!/bin/bash" 时,bash 会把第一行当成命令去执行,
    # 报 "command not found" 再往下跑 —— 看着像成功,其实是碰运气。
    $joinFile = Join-Path $env:TEMP '07-k8s-worker.sh'
    Write-Utf8Text $joinFile ("#!/bin/bash`n" + $join.Trim())
    foreach ($w in $workers) {
        # 已经在集群里的节点跳过 —— 重跑一次 k8s 阶段不该因为
        # "This node has already joined the cluster" 就失败。
        $st = Get-ClusterState -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address
        $already = @($st.NodeLines | Where-Object { $_ -match [regex]::Escape($w.Address) })
        if ($already.Count -gt 0) {
            Write-Ok ("{0} 已经在集群里,跳过 join" -f $w.Address)
            continue
        }
        $rr = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $sshArgs -User $User -Host_ $w.Address `
            -Source $joinFile -Dest '/tmp/07-k8s-worker.sh'
        if ($rr.ExitCode -ne 0) {
            Stop-WithError "分发 join 脚本到 $($w.Address) 失败:`n$($rr.Output)"
        }
        Write-Info "$($w.Address): 加入集群"
        $rj = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $w.Address `
            -Command 'sudo bash /tmp/07-k8s-worker.sh' -TimeoutSec 600
        if ($rj.ExitCode -ne 0) {
            ($rj.Output -split "`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "        $_" }
            Stop-WithError "节点 $($w.Address) 加入集群失败"
        }
        Write-Ok "$($w.Address) 已加入"
    }

    # ---- 6. CNI ----
    # main.sh 漏了这一步,集群会一直停在 NotReady。
    if (-not $SkipCni) {
        $cniScript = switch ($NetworkPlugin) {
            'flannel' { '08-1-cni-flannel.sh' }
            'calico'  { '08-2-cni-calico.sh' }
            'cilium'  { '08-3-cni-cilium.sh' }
            default   { $null }
        }
        if (-not $cniScript) {
            Stop-WithError "未知的 CNI: $NetworkPlugin(可选 flannel / calico / cilium)"
        }
        Write-Step "安装 CNI: $NetworkPlugin ($cniScript)"
        # CNI 脚本要 curl raw.githubusercontent.com 拿 manifest,
        # 走地区补丁里的 GHPROXY,所以也用 Invoke-RepoScript。
        #
        # 为什么要重试:2026-10-20 实跑时,ghfast.top 把连接 reset 了
        # (curl: (56) Recv failure),manifest 下了 0 字节。仓库脚本
        # 没有 set -e,于是它接着往下跑,最后报出来的是
        #     error: the path "calico.yaml" does not exist
        # —— 看着像路径写错了,真凶是下载。换成别的代理、或者过几分钟
        # 再试,就又好了。
        #
        # 所以这里重跑整个脚本(apply 是幂等的,重跑没有副作用),
        # 并且每次重跑之前先把上一次的半截文件删掉 —— 拿一个只下了
        # 一半的 manifest 去 apply,报错会指向完全不相干的地方。
        $cniAttempts = 3
        $cniOk = $false
        for ($i = 1; $i -le $cniAttempts; $i++) {
            if ($NetworkPlugin -eq 'calico') {
                $null = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
                    -Command 'rm -f /tmp/setup-k8s/scripts/calico.yaml /tmp/setup-k8s/scripts/calico.yaml.bak' `
                    -TimeoutSec 60
            }
            if ($i -gt 1) {
                Write-Note "CNI 安装没成功,重试(第 $i 次 / 共 $cniAttempts 次)"
            }
            $r = Invoke-RepoScript -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
                -Script "/tmp/setup-k8s/scripts/$cniScript" -TimeoutSec 900 `
                -WorkingDir '/tmp/setup-k8s/scripts'
            if ($r.ExitCode -eq 0) {
                $cniOk = $true
                break
            }
            ($r.Output -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "        $_" }
        }
        if (-not $cniOk) {
            Stop-WithError "CNI 安装失败(重试 $cniAttempts 次都是这个结果)"
        }
        Write-Ok 'CNI 安装完成'

        # ---- 6.1 等集群真的可用 ----
        #
        # kubectl apply 成功**不代表**集群能用:CNI 的 pod 还在拉镜像,
        # 节点会一直停在 NotReady。必须等到所有节点都 Ready。
        Write-Step '等节点 Ready'
        $state = Wait-ClusterReady -SshExe $SshExe -SshArgs $sshArgs -User $User `
            -Host_ $master.Address -TimeoutSec 900

        if ($state -eq 'PULL_FAILED') {
            # 镜像拉不下来 —— 仓库的 CNI 脚本把 quay.io 的镜像地址
            # 换成了 Docker Hub 的拉取缓存,那里没有这些镜像。
            # 换回官方源再 apply 一次(仓库脚本一个字都不改)。
            $fallback = switch ($NetworkPlugin) {
                'calico' {
                    @{
                        Manifest = 'calico.yaml'
                        From     = 'registry.cn-beijing.aliyuncs.com/my-dockermirrors/'
                        To       = 'quay.io/calico/'
                    }
                }
                default { $null }
            }
            if (-not $fallback) {
                Stop-WithError "$NetworkPlugin 的镜像拉不下来,而且没有配好的兜底镜像源"
            }
            $ok = Repair-CniImageRegistry -SshExe $SshExe -SshArgs $sshArgs -User $User `
                -Host_ $master.Address -Manifest $fallback.Manifest `
                -From $fallback.From -To $fallback.To
            if (-not $ok) { Stop-WithError '换镜像源之后还是没拉下来' }
            # 改完镜像之后,老 pod 还会挂着 ImagePullBackOff 一小会儿
            # (DaemonSet 的 pod 模板变了,新的 pod 起来之前老的还在),
            # 这一轮不能再拿这个当失败信号。
            $state = Wait-ClusterReady -SshExe $SshExe -SshArgs $sshArgs -User $User `
                -Host_ $master.Address -TimeoutSec 900 -IgnorePullFailure
        }

        if ($state -ne 'READY') {
            Stop-WithError "集群没能就绪(状态 $state)"
        }
        Write-Ok '所有节点已 Ready'
    }

    # ---- 7. 写 config.sh,把这次的实际配置留在仓库里 ----
    Write-Step '写出 setup-k8s/config.sh'
    $configPath = Join-Path $setupDir 'config.sh'
    $fullVersion = Resolve-K8sFullVersion -Minor $K8sMinor
    $cfg = New-K8sConfigContent -Masters $masters -Workers $workers `
        -K8sVersion $fullVersion -PodCidr $PodCidr -ServiceCidr $ServiceCidr `
        -LoadBalancer $LoadBalancer -User $User -NetworkPlugin $NetworkPlugin
    Write-Utf8Text $configPath $cfg
    Write-Ok "已写出 $configPath"

    # ---- 8. 收尾:看节点状态 ----
    Write-Step '节点状态'
    # 用 admin.conf 显式指定,别依赖 ~/.kube/config 有没有配好
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Command 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide'
    Write-Host ($r.Output)

    return $true
}
