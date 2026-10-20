# vmware-k8s

在 Windows 上用 **Packer + VMware Workstation** 搭一个本地 k8s 集群:
1 master + 2 worker,节点跑 Ubuntu LTS,IP 固定在 `10.10.10.0/24`。

集群内部的组件安装**全部复用仓库里现成的 `setup-k8s/scripts/*.sh`**,一个字符都没改。

---

## 一分钟上手

```cmd
:: 管理员身份运行
vmware-k8s\build.cmd

:: 先看看环境行不行(不下载、不克隆、不改配置)
vmware-k8s\build.cmd -Stage preflight
```

`build.cmd` 会依次做:

| 阶段 | 做什么 | 耗时 |
|---|---|---|
| preflight | 体检 VMware / SSH / 磁盘 / 网段 | 秒级 |
| packer | 下载并校验 Packer,装到 `vmware-k8s\.cache\packer\` | 1-2 分钟 |
| iso | 从镜像站下 Ubuntu LTS live-server ISO(2.7 GB),校验 SHA256 | 5-30 分钟 |
| template | `packer build` 出一张 2C/2G/20G 的模板盘 | 10-20 分钟 |
| network | 给三个节点的 MAC 写静态 DHCP 租约,IP 钉死 | 秒级 |
| clone | `vmrun full clone` 出 1 master + 2 worker | 2-5 分钟 |
| boot | 启动并等三个节点 ssh 可用、地址核对无误 | 2-5 分钟 |
| k8s | 复用 `setup-k8s` 脚本装集群 | 15-30 分钟 |

---

## 改配置

所有可调项都集中在 **`build.ps1` 顶部的变量区**,不用翻别的文件:

```powershell
# ---- 网络 ----
$NetSubnet      = '10.10.10.0/24'
$MasterIP       = '10.10.10.11'
$WorkerIPs      = @('10.10.10.101', '10.10.10.102')
$LoadBalancerIP = '10.10.10.10'   # apiserver 证书 SAN,不是真 VIP

# ---- 模板 ----
$TemplateCpu    = 2
$TemplateMemMB  = 2048
$TemplateDiskGB = 20

# ---- 节点规格 ----
$NodeCpu        = 2
$NodeMemMB      = 4096
$NodeDiskGB     = 20

# ---- 操作系统 ----
$UbuntuVersion  = '26.04'
$IsoMirror      = 'https://mirrors.ustc.edu.cn/ubuntu-releases'

# ---- k8s ----
$K8sMinor       = '1.34'
$NetworkPlugin  = 'calico'        # calico / flannel / cilium
$PodCidr        = '10.244.0.0/16'
$ServiceCidr    = '10.96.0.0/12'

# ---- 路径 ----
$VmRoot         = 'D:\vmware-k8s' # VM 放这儿(三个节点 + 模板差不多 80G)
```

---

## 网络是怎么处理的

宿主机上 `vmnet8`(NAT)已经是 `10.10.10.1/24`,DHCP 池 `10.10.10.10-200`,
网关 `10.10.10.2`。节点就挂在 vmnet8 上:

- 宿主机能**直连** `10.10.10.11 / .101 / .102`
- 节点能**出网**(apt、containerd 镜像、k8s 镜像都要)

节点要固定地址,因为仓库里 `setup-k8s/config.sh` 的 `MASTER_NODES` /
`WORKER_NODES` 就是写死的这几 个 IP。做法是**在 VMware 的 DHCP 里写静态租约**:

```
host k8s-master {
    hardware ethernet 00:50:56:0A:0A:0B;
    fixed-address 10.10.10.11;
}
```

guest 那边保持是一个普通的 DHCP 客户端,什么都不用改。这比"往 guest 里写静态 IP"
干净得多 —— 不用担心克隆之后 cloud-init 不重跑、IP 没被改的问题。

MAC 是**写死在 .vmx 里**的(`ethernet0.addressType = static`),因为节点要靠 MAC
拿固定 IP,开机之前就必须已经知道它。末位直接对应 IP 末位:

```
00:50:56:0A:0A:0B  ->  10.10.10.11
00:50:56:0A:0A:65  ->  10.10.10.101
```

---

## 克隆出来的机器怎么变成"三台不同的机器"

`vmrun full clone` 出来的是模板的完整副本,三台机器会带着同一份身份信息:

| 文件 | 不处理会怎样 |
|---|---|
| `/etc/machine-id` | k8s 用它当节点唯一标识。三台一样,集群根本起不来 |
| `/etc/ssh/ssh_host_*` | 从宿主机 ssh 第二台会报 `REMOTE HOST IDENTIFICATION HAS CHANGED` |
| `/var/lib/cloud/instance` | cloud-init 认为这机器已经初始化过,不再跑一遍 |

PVE 那边是用 `--ciupgrade 1` 达到同样效果的,VMware 没有对应的开关,所以在系统里
埋了一个开机服务 `vmware-clone-prep.service`:

```
guest/clone-prep.sh
guest/clone-prep.service
```

它靠一个标记文件区分"模板自己"和"克隆出来的":模板里留着
`/var/lib/vmware-template-sealed`(packer 装的),克隆出来的机器带着这个标记,
首启时重置 machine-id 和 host key,然后把标记删掉 —— 之后每次开机都不会再重置。

---

## 复用了仓库的哪些东西

`setup-k8s/scripts/*.sh` **一个字都没改**,Windows 侧只是把 `main.sh` 在 Linux 上
做的事换了个传输方式(main.sh 用 rsync,这里用 scp):

```
01-base-pkgs.sh        基础包、chrony、内核模块、sysctl
02-2-containerd.sh     containerd
03-kubelet.sh          kubelet / kubectl / kubeadm
04-kubeadm-init.sh     kubeadm init(master)
07-k8s-worker.sh       join(现场生成)
08-2-cni-calico.sh     CNI
```

**补了 `main.sh` 漏掉的一步**:装 CNI。`main.sh` 跑完 join 就结束了,第 57 行还留着
`# todo: which cni plugin to use`,集群会一直停在 `NotReady`。这边按
`$NetworkPlugin` 补上。

装完之后会写出 `setup-k8s/config.sh`,记录这次的 IP 和参数,之后想在一台 Linux 上
接着用 `setup-k8s/main.sh` 管理这个集群也有据可依。

---

## 目录

```
vmware-k8s/
├── build.cmd                    一键入口(检查管理员权限后调 build.ps1)
├── build.ps1                    主脚本:变量区 + 阶段编排
├── lib/
│   ├── common.ps1               日志、下载(断点续传)、SHA256、工具探测
│   ├── packer.ps1               下载 Packer + 解析 ISO 地址
│   ├── vmnet.ps1                vmnet 探测 + 静态 DHCP 租约
│   ├── clone.ps1                full clone + .vmx 调整 + MAC/地址生成
│   └── k8s.ps1                 scp/ssh 复用 setup-k8s 脚本
├── packer/
│   ├── ubuntu-template.pkr.hcl  Packer 模板
│   └── http/
│       ├── user-data            Ubuntu autoinstall 配置
│       └── meta-data
├── guest/
│   ├── clone-prep.sh            克隆首启:重置 machine-id / host key
│   └── clone-prep.service
├── tests/
│   ├── run-all.ps1              一键跑全部离线测试
│   ├── test-ps-syntax.ps1       语法 + UTF-8 BOM
│   ├── test-encoding.ps1        编码回归(见下)
│   ├── test-bash-syntax.ps1     guest 脚本 bash -n + user-data YAML
│   ├── test-vmnet-lease.ps1     静态租约写入器(在副本上做)
│   ├── test-node-defs.ps1       节点定义 / MAC 推导 / .vmx 改写
│   ├── test-k8s-config.ps1      生成的 setup-k8s/config.sh 对不对
│   ├── test-packer-validate.ps1 packer validate + fmt
│   └── test-negative.ps1        否定测试:把代码改坏,要求检查必须报错
└── .cache/                      运行时生成:packer、ISO、known_hosts、状态
```

---

## 跑测试

改完代码先跑一遍,不用管理员权限,不会碰宿主机上的 VMware 配置:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\run-all.ps1
```

改了编码相关的代码,再跑一次否定测试:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File vmware-k8s\tests\test-negative.ps1
```

`test-negative.ps1` 会在临时目录里复制一份代码,**故意改坏**(比如把 UTF-8 读法改回
`Get-Content`),然后要求对应的检查必须报失败。改坏了检查还是绿的,就说明那条断言
是摆设 —— 这个仓库以前栽过"检查是绿的但其实什么都没验"的跟头,所以每次加断言
都要先证明它会咬。

---

## 踩过的坑(改代码前先看一眼)

**PowerShell 5.1 的编码**:5.1 里 `Get-Content` / `Set-Content` 的默认编码是**系统 ANSI
代码页**(中文 Windows 上是 GBK),不是 UTF-8。拿它们读写 UTF-8 文件,中文会变乱码;
更阴的是某些多字节序列被 GBK 误解后会把行尾吃掉,把下一行粘到上一行末尾。

实际后果:`packer/http/user-data` 是 UTF-8,一旦用 `Get-Content -Raw` 读再写回去,
`late-commands:` 会变成

```
  # 涓変釜鑺傜偣鐨勫湴鍧€鐢ㄩ潤鎬佺绾﹂拤姝汇€?  late-commands:
```

—— 粘在注释后面了。YAML 照样能解析,但 subiquity 会**静默忽略**整段 late-commands:
免密 sudo、machine-id 重置、SSH host key 清理全都不做。模板看着装好了,克隆出来的
节点全是废的,而且要等到真跑起来才发现。

所以规矩定死:**读用 `Read-Utf8Text` / `Read-Utf8Lines`,写用 `Write-Utf8Text` /
`Write-Utf8Lines`(一律不带 BOM)**。`test-encoding.ps1` 会用 AST 扫生产脚本,
发现真的调了 `Get-Content` / `Set-Content` 就报错。

**`.ps1` 文件必须带 UTF-8 BOM**:5.1 读没有 BOM 的 `.ps1` 会按 ANSI 解释,中文注释被
拆成引号,报出来的是一堆"字符串缺少终止符",跟真正的问题完全对不上。

**`.ps1` 里的 `$var` 在原生参数里要加引号**:`-var-file=$varsPath` 不加引号时 5.1
**不会展开**变量,字面量 `$varsPath` 会被原样传给程序。写成 `"-var-file=$varsPath"`。

**`.ps1` 方法链不能跨行以 `.` 开头**:那是 PowerShell 7 的写法,5.1 会报
"意外的标记 .Replace"。把括号打在行尾,点跟在后面。

**`Set-Content -Encoding UTF8` 会写 BOM**:BOM 紧挨着 `#!/bin/bash` 时,bash 会把第一行
当成命令去执行,报 `command not found` 再往下跑 —— 看着像成功,其实是碰运气。

**shell 脚本会被 CRLF 毁掉**:仓库在 Windows 上 `core.autocrlf=true`,checkout 出来的
`.sh` 每个行尾都是 `\r\n`,推到 Linux 上执行就是一堆 `command not found`。所以推过去
之后在 guest 上统一 `sed -i 's/\r$//'`(仓库根目录的 `.gitattributes` 也把
`vmware-k8s` 下这几个文件钉成 LF,但脚本里还是兜了一道)。

**PowerShell 可展开 here-string 会吃掉 shell 语法**:`@"..."@` 里的
`${CLUSTER_NAME:-"devops-k8s"}` 会被当成变量引用,输出变成 `CLUSTER_NAME=`。写
config.sh 这种要给 bash source 的文件,要么用单引号 here-string,要么逐行拼。

---

## 常见问题

**Hyper-V 开着,VMware 很慢**
Hyper-V/VBS 开着时 VMware 走 WHP 后端,性能明显不如原生。
控制面板里关掉"Windows Hypervisor 平台"和"虚拟机平台"可以恢复。

**端口占用 / vmnet 找不到**
先跑 `-Stage preflight`,它会把宿主机上所有 VMware 网卡和地址列出来。
`vmnetcfg.exe`(VMware 安装目录下)可以改网段。

**k8s 装完节点是 NotReady**
CNI 没装或没装完。等 CNI 的 pod 都 Running 再看:
`ssh vagrant@10.10.10.11 'kubectl get pods -A'`

**想重来**
```
vmware-k8s\build.cmd -Stage destroy     # 删掉三个节点
vmware-k8s\build.cmd -Stage template -ForceTemplate
```
