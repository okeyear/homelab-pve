# vmware-k8s — 用仓库里现成的 setup-k8s 脚本把集群搭起来
#
# 复用策略:setup-k8s/scripts/*.sh 一个字都不改,Windows 这边只做
# main.sh 在 Linux 上做的同一件事 —— 把脚本推过去、用 ssh 跑。
# 唯一区别是传输方式:main.sh 用 rsync,这里用 scp(Windows 自带)。
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
    $out = & $SshExe @SshArgs $target $Command 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Output   = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    }
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
    $out = & $ScpExe @a $Source "$target`:$Dest" 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Output   = (($out | ForEach-Object { $_.ToString() }) -join "`n")
    }
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
    $null = & $keygen.Source -R $Host_ -f $KnownHosts 2>&1
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
            $ip = Invoke-Ssh -SshExe $SshExe -SshArgs $SshArgs -User $User -Host_ $Host_ `
                -Command "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1" -TimeoutSec 30
            $got = ($ip.Output -split "`n" | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+\.\d+$' } |
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
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$K8sMinor,        # 1.34
        [Parameter(Mandatory)][string]$NetworkPlugin,   # calico / flannel / cilium
        [Parameter(Mandatory)][string]$PodCidr,
        [Parameter(Mandatory)][string]$ServiceCidr,
        [Parameter(Mandatory)][string]$LoadBalancer,
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

    # ---- 2. 基础包 / containerd / kubelet ----
    #
    # 这三个脚本在 base 阶段已经在 k8s-base 上装过了,节点是从 base
    # 克隆来的,东西都在。这里**先探一下**,已经有了就跳过 ——
    # 02-2-containerd.sh 每次都要重新下载 containerd / runc / cni
    # 三个包,三台节点重跑一遍要多花好几分钟,没必要。
    #
    # 但不能简单地"默认跳过":单独跑 -Stage k8s 的时候,节点可能是
    # 别的方式来的,那就得老老实实装一遍。所以是**探测**,不是假设。
    $pkgScripts = @(
        @{ Name = '01-base-pkgs.sh'; Env = '' },
        @{ Name = '02-2-containerd.sh'; Env = '' },
        @{ Name = '03-kubelet.sh'; Env = "k8sver=v$K8sMinor" }
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
        foreach ($s in $pkgScripts) {
            Write-Info "$($n.Address): $($s.Name)"
            $cmd = "bash /tmp/setup-k8s/scripts/$($s.Name)"
            if ($s.Env) { $cmd = "$($s.Env) $cmd" }
            $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $n.Address -Command $cmd
            if ($r.ExitCode -ne 0) {
                Write-Fail "$($n.Address) 上 $($s.Name) 失败,输出尾部:"
                ($r.Output -split "`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "        $_" }
                Stop-WithError "节点 $($n.Address) 装基础组件失败"
            }
            Write-Ok "$($n.Address): $($s.Name) 完成"
        }
    }

    # ---- 3. kubeadm init ----
    Write-Step "kubeadm init (master: $($master.Address))"
    $masterList = ($masters | ForEach-Object { $_.Address }) -join ','
    $initCmd = "MASTER_NODES=$masterList VIP=$LoadBalancer POD_CIDR=$PodCidr SERVICE_CIDR=$ServiceCidr " +
               "bash /tmp/setup-k8s/scripts/04-kubeadm-init.sh"
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address -Command $initCmd
    if ($r.ExitCode -ne 0) {
        ($r.Output -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "        $_" }
        Stop-WithError 'kubeadm init 失败'
    }
    Write-Ok 'kubeadm init 完成'

    # ---- 4. 生成 join 命令 ----
    Write-Step '生成 worker join 命令'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Command 'sudo kubeadm token create --print-join-command'
    $join = ($r.Output -split "`n" | Where-Object { $_.Trim() -match 'kubeadm join' } | Select-Object -First 1)
    if (-not $join) {
        Stop-WithError "拿不到 join 命令:`n$($r.Output)"
    }
    Write-Ok "join 命令: $($join.Trim())"

    # 写成脚本再分发 —— 命令里有引号,直接 ssh 传过去很容易被 shell 吃掉一层。
    # 必须不带 BOM:5.1 的 Set-Content -Encoding UTF8 会加 BOM,而
    # BOM 紧挨着 "#!/bin/bash" 时,bash 会把第一行当成命令去执行,
    # 报 "command not found" 再往下跑 —— 看着像成功,其实是碰运气。
    $joinFile = Join-Path $env:TEMP '07-k8s-worker.sh'
    Write-Utf8Text $joinFile ("#!/bin/bash`n" + $join.Trim())
    foreach ($w in $workers) {
        $rr = Invoke-ScpTo -ScpExe $ScpExe -SshArgs $sshArgs -User $User -Host_ $w.Address `
            -Source $joinFile -Dest '/tmp/07-k8s-worker.sh'
        if ($rr.ExitCode -ne 0) {
            Stop-WithError "分发 join 脚本到 $($w.Address) 失败:`n$($rr.Output)"
        }
        Write-Info "$($w.Address): 加入集群"
        $rj = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $w.Address `
            -Command 'sudo bash /tmp/07-k8s-worker.sh'
        if ($rj.ExitCode -ne 0) {
            ($rj.Output -split "`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "        $_" }
            Stop-WithError "节点 $($w.Address) 加入集群失败"
        }
        Write-Ok "$($w.Address) 已加入"
    }

    # ---- 5. CNI ----
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
        $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
            -Command "cd /tmp/setup-k8s/scripts && bash $cniScript"
        if ($r.ExitCode -ne 0) {
            ($r.Output -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "        $_" }
            Stop-WithError 'CNI 安装失败'
        }
        Write-Ok 'CNI 安装完成'
    }

    # ---- 6. 写 config.sh,把这次的实际配置留在仓库里 ----
    Write-Step '写出 setup-k8s/config.sh'
    $configPath = Join-Path $setupDir 'config.sh'
    $fullVersion = Resolve-K8sFullVersion -Minor $K8sMinor
    $cfg = New-K8sConfigContent -Masters $masters -Workers $workers `
        -K8sVersion $fullVersion -PodCidr $PodCidr -ServiceCidr $ServiceCidr `
        -LoadBalancer $LoadBalancer -User $User -NetworkPlugin $NetworkPlugin
    Write-Utf8Text $configPath $cfg
    Write-Ok "已写出 $configPath"

    # ---- 7. 收尾:看节点状态 ----
    Write-Step '节点状态'
    $r = Invoke-Ssh -SshExe $SshExe -SshArgs $sshArgs -User $User -Host_ $master.Address `
        -Command 'kubectl get nodes -o wide'
    Write-Host ($r.Output)

    return $true
}
