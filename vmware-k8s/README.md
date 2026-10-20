# vmware-k8s

在 Windows 上用 **Packer + VMware Workstation** 搭一个本地 k8s 集群:
1 master + 2 worker,节点跑 Ubuntu LTS,IP 固定在 `10.10.10.0/24`。

集群内部的组件安装**全部复用仓库里现成的 `setup-k8s/scripts/*.sh`**,一个字符都没改。

**全流程不需要管理员权限** —— 节点 IP 由 guest 自己写 netplan 配好,宿主机一个字的
全局配置都不用改。

---

## 分三层克隆

```
        packer build
             │
             ▼
   ┌──────────────────┐
   │  模板 k8s-template │  最小化 Ubuntu(2C/2G/20G)
   │  固定地址 10.10.10.9│  只装 SSH + sudo + open-vm-tools
   └────────┬─────────┘
            │ vmrun full clone
            ▼
   ┌──────────────────┐
   │   k8s-base       │  换 apt 源 / 装 cloud-init / 装 clone-prep
   │  (k8s 基础镜像)   │  装基础包 / containerd / k8s 组件
   └────────┬─────────┘  打好封存标记后关机
            │ vmrun full clone ×3
            ▼
   ┌──────────────────┐
   │ k8s-master       │  首启时 clone-prep 配静态 IP
   │ k8s-worker1/2    │  重置 machine-id / SSH host key
   └──────────────────┘  然后 kubeadm init / join / 装 CNI
```

分层的三个好处:

- **三个节点从同一张盘克隆,天然一致** —— 不会出现"这台装了 calico 那台没装"。
- **重活失败只要重跑 base 阶段(几分钟)**,不用重装系统(20 分钟)。
- **模板越薄,packer 阶段失败面越小**。模板只负责"装起来并且能 SSH 进来",
  别的什么都不干;`late-commands` 失败会**中止整场安装**,所以模板里一个都不写。

---

## 一分钟上手

```cmd
vmware-k8s\build.cmd

:: 先看看环境行不行(不下载、不克隆、不改配置)
vmware-k8s\build.cmd -Stage preflight
```

`build.cmd` 会依次做:

| 阶段 | 做什么 | 耗时 |
|---|---|---|
| preflight | 体检 VMware / SSH / 磁盘 / 网段 / **IP 有没有和 DHCP 池撞** | 秒级 |
| packer | 下载并校验 Packer,装到 `vmware-k8s\.cache\packer\` | 1-2 分钟 |
| iso | 从镜像站下 Ubuntu LTS live-server ISO(2.7 GB),校验 SHA256 | 5-30 分钟 |
| template | `packer build` 出一张 2C/2G/20G 的**最小化**模板盘 | 10-20 分钟 |
| base | 从模板克隆出 k8s-base,装好 cloud-init / 换源 / 基础包 / containerd / k8s 组件 | 10-20 分钟 |
| clone | 从 k8s-base 克隆出 1 master + 2 worker | 2-5 分钟 |
| boot | 启动三个节点,等它们配好静态 IP、ssh 可用 | 3-8 分钟 |
| k8s | 复用 `setup-k8s` 脚本装集群 | 10-20 分钟 |

单跑某一阶段:`build.cmd -Stage base` / `-Stage clone` / `-Stage k8s` ……
机器放在 `D:\vmware-k8s\` 下(改 `build.ps1` 的 `$VmRoot`)。默认是用
`vmrun` **静默**启动的(`nogui`),所以在 VMware Workstation 的库里
**看不到**它们。想看着它们跑:

```cmd
vmware-k8s\build.cmd -Stage boot -ShowConsole
```

这台机器会带控制台重启(已经在跑的就先停掉),之后三台都会出现在
VMware Workstation 的库里,并且有实时画面。

---

## 改配置

所有可调项都集中在 **`build.ps1` 顶部的变量区**,不用翻别的文件:

```powershell
# ---- 固定地址 vs DHCP 池 ----
$TemplateIP        = '10.10.10.9'        # 模板 / k8s-base
$TemplateCidr      = '10.10.10.9/24'
$TemplateGateway   = '10.10.10.2'        # VMware NAT 的网关
$TemplateDnsPrimary   = '10.10.10.2'
$TemplateDnsSecondary = '223.5.5.5'

$MasterIP       = '10.10.10.201'
$WorkerIPs      = @('10.10.10.202', '10.10.10.203')
$LoadBalancerIP = '10.10.10.250'   # apiserver 证书 SAN,不是真 VIP

# ---- 中间产物:k8s 基础镜像 ----
$BaseName = 'k8s-base'
$BaseCpu = 2; $BaseMemMB = 2048; $BaseDiskGB = 20

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
$VmRoot         = 'D:\vmware-k8s' # VM 放这儿(base + 三个节点差不多 80G)
```

> **静态地址必须落在 VMware 的 DHCP 池(`10.10.10.10-200`)外面。**
> 池里的地址随时可能被派给别的机器,IP 一撞,表现是"偶尔 SSH 上的是另一台机器" ——
> 极难查。`preflight` 会读 `vmnetdhcp.conf` 里的 `range` 行,发现冲突直接报出来。

---

## 网络是怎么处理的

宿主机上 `vmnet8`(NAT)是 `10.10.10.1/24`,DHCP 池 `10.10.10.10-200`,网关 `10.10.10.2`。

**模板用固定地址 `10.10.10.9`。** 这一条是整条流水线能跑通的关键,原因见下面
"踩过的坑"里的 *packer 找不到 guest IP*。

**节点用固定地址 `.201 / .202 / .203`,由 guest 自己配。** 做法是:

1. 宿主机克隆时把 IP / 网关 / DNS 写进 `.vmx` 的 `guestinfo`:
   ```
   guestinfo.ip = "10.10.10.201"
   guestinfo.gateway = "10.10.10.2"
   guestinfo.nameserver = "10.10.10.2,223.5.5.5"
   ```
2. guest 里的开机服务 `vmware-clone-prep.service` 用 `vmware-rpctool` 读回来,
   写进 `/etc/netplan/99-k8s-node.yaml`,然后 `netplan apply`。

netplan 用 `match: macaddress` 定位网卡 —— **不认接口名**。接口名在不同硬件版本 /
不同内核上是 `ens33` / `ens160` / `enp0s3` 都可能,写死名字是最容易翻车的地方。

MAC 也是**写死在 `.vmx` 里**的(`ethernet0.addressType = static`),末位直接对应 IP 末位:

```
00:50:56:0A:0A:C9  ->  10.10.10.201
00:50:56:0A:0A:CA  ->  10.10.10.202
00:50:56:0A:0A:CB  ->  10.10.10.203
```

---

## 克隆出来的机器怎么变成"三台不同的机器"

`vmrun full clone` 出来的是源盘的完整副本,三台机器会带着同一份身份信息:

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

它靠一个标记文件区分"源"和"克隆出来的":`k8s-base` 里留着
`/var/lib/vmware-k8s-base`(`base-setup.sh` 打的),克隆出来的机器带着这个标记,
首启时重置 machine-id 和 host key、按 guestinfo 配好静态 IP,然后把标记删掉 ——
之后每次开机都不会再重置。

---

## 复用了仓库的哪些东西

`setup-k8s/scripts/*.sh` 直接拿来用,Windows 侧只是把 `main.sh` 在 Linux 上
做的事换了个传输方式(main.sh 用 rsync,这里用 scp)。仓库脚本只在**用户明确
要求**的地方动过(地区判定、拆掉 IPVS、钉死 kube-proxy 代理模式),其余逻辑
一个字不改:

| 脚本 | 在哪一层跑 |
|---|---|
| `01-base-pkgs.sh` 基础包、chrony、内核模块、sysctl(不再装 IPVS) | base |
| `02-2-containerd.sh` containerd | base |
| `03-kubelet.sh` kubelet / kubectl / kubeadm | base |
| `04-kubeadm-init.sh` kubeadm init(master)+ 钉死 kube-proxy 代理模式 | k8s |
| `07-k8s-worker.sh` join(现场生成) | k8s |
| `08-2-cni-calico.sh` CNI | k8s |

base 层装好的东西,节点克隆过来就有了;k8s 阶段会**先探测**节点上有没有
`kubeadm` + `containerd`,有就跳过重装(省下每台节点几分钟的下载)。

**补了 `main.sh` 漏掉的一步**:装 CNI。`main.sh` 跑完 join 就结束了,第 57 行还留着
`# todo: which cni plugin to use`,集群会一直停在 `NotReady`。这边按
`$NetworkPlugin` 补上。

装完之后会写出 `setup-k8s/config.sh`,记录这次的 IP 和参数,之后想在一台 Linux 上
接着用 `setup-k8s/main.sh` 管理这个集群也有据可依。

### 地区判断:问四家,谁先答出国家码就用谁

`setup-k8s/scripts/functions.sh` 靠这一段决定用不用国内镜像源:

```bash
REGION=$(detect_region)
```

`detect_region()` 一家一家问过去,谁先答出合法的两字母国家码就用谁,最多问三轮:

| 源 | 协议 | 提取 |
|---|---|---|
| `ipinfo.io/country` | https | 纯文本国家码 |
| `ipwho.is` | https | `"country_code": "CN"`(**缩进 JSON,冒号后有空格**) |
| `sysad.win` | **http** | `"iso_code":"CN"`(https 证书主机名不匹配) |
| `ip-api.com/json` | **http** | `"countryCode":"CN"`(https 免费端点 403) |

四家都问不到时,还有一层兜底:直接问国内镜像源通不通,通就当 CN ——
**地区判错的后果是 `kubeadm init` 拉不到镜像一直挂着**,宁可慢也不能挂。

为什么非得判对:`registry.k8s.io` 的 manifest 请求会 307 跳到
`europe-west3-docker.pkg.dev`,这个域名在国内是 `connection refused`,
containerd 会一直重试,`kubeadm init` 永远不返回;节点则因为拿不到
`/var/lib/kubelet/config.yaml` 一直崩溃重启(日志里只写
`failed to load kubelet config file`,完全看不出是镜像拉不下来)。

即便如此,VMware 这条链路还是**再补了一层**:k8s 阶段会先在 guest 上
真的跑一次仓库的 `detect_region()`,把结果**固定**下来,再用 `BASH_ENV`
注入 —— `guest/region-shim.sh` 用一个 shell 函数把这四个探测地址都拦下来
返回固定的国家码,别的 `curl` 调用用 `command curl` 原样放行。
问不到就用缓存,再问不到就当 CN。

### IPVS:拆掉了 —— 而且本来就没在用

kube-proxy 的 IPVS 模式在 **Kubernetes 1.37 被正式弃用**(官方时间表:
1.40 起 `--mode` 默认切 nftables,1.43 彻底移除 IPVS 模式)。所以
`setup-k8s/scripts/01-base-pkgs.sh` 里那一整套 IPVS 逻辑全部拆掉了:

| 原来 | 现在 |
|---|---|
| 包列表里的 `ipvsadm` | 没了 |
| 写 `/etc/modules-load.d/ipvs.conf` + `modprobe ip_vs*` | 没了,只 `rm -f` 掉老版本留下的残留 |
| 结尾的 `lsmod \| grep -e ip_vs -e nf_conntrack_ipv4` 校验 | 没了 |

**关键在于:这个集群的 kube-proxy 从来就没用过 IPVS。** kubeadm 写进
kube-proxy ConfigMap 的 `mode` 字段是**空的**,而 kube-proxy 把空值当成
`iptables`(v1.34.12 实测)。也就是说,以前装的 `ip_vs*` 内核模块和
`ipvsadm` 是**纯死重**,数据面压根没碰过 —— 拆掉它对集群零影响。

但空值本身是个雷:1.37 起空值会被判为即将过期并打告警,1.40 起默认值改成
nftables —— **升级一次,数据面就悄悄换掉了**。所以
`setup-k8s/scripts/04-kubeadm-init.sh` 里把模式显式钉死:

```bash
KUBE_PROXY_MODE=iptables
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get cm kube-proxy -o yaml > /tmp/kube-proxy-cm.yaml
sudo sed -i "s/^\( *\)mode: \"\"$/\1mode: \"${KUBE_PROXY_MODE}\"/" /tmp/kube-proxy-cm.yaml
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f /tmp/kube-proxy-cm.yaml
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system rollout restart ds/kube-proxy
```

想换 nftables 就改 `KUBE_PROXY_MODE` 那一行。

> **每条 `kubectl` 都必须带 `--kubeconfig`**:admin.conf 是 root 权限 600,
> 而 root 的 `HOME` 是 `/root`,那边没有 `~/.kube/config` —— 漏了 kubectl 就
> 去连 `localhost:8080`,报
> `couldn't get current server API group list`。这个坑实跑时踩过一次,
> `tests/test-ipvs-removal.ps1` 现在专门盯着它。

`tests/test-ipvs-removal.ps1` 是这条线的护栏(20 项断言),否定测试里的
M21–M26 会把 IPVS 一个个加回去,要求检查必须报红。

### CNI 下载会被代理 reset,编排层会重试

`08-2-cni-calico.sh` 要通过 `GHPROXY` 拿 calico 的 manifest,而国内代理
偶尔会把连接 reset 掉(`curl: (56) Recv failure`)。仓库脚本没有 `set -e`,
于是它接着往下跑,最后报出来的是:

```
sed: can't read calico.yaml: No such file or directory
error: the path "calico.yaml" does not exist
```

看着像路径写错了,真凶是**下载失败**。编排层因此会重跑整个 CNI 脚本
(`apply` 是幂等的,重跑没副作用),最多 3 次,并且每次重跑之前先删掉上
一次留下的半截文件 —— 拿一个只下了一半的 manifest 去 `apply`,报错会指向
完全不相干的地方。

### k8s 阶段可以重跑

k8s 阶段开始时会先把三个节点上一次的痕迹清掉(`kubeadm reset` +
删 `/etc/kubernetes`、`/var/lib/kubelet`),还会杀掉上一次挂死的
`kubeadm init` 进程。没有这一步,第二次跑会撞上:

- `kubeadm init` → `the cluster already exists`
- worker join → `This node has already joined the cluster`

远端命令一律套 `timeout`(见 `Add-RemoteTimeout`),所以就算某个脚本
卡死也只会超时退出,不会把整个 build 干耗着 —— 之前就是 `kubeadm init`
挂了 15 分钟,build 一直等在那儿。

---

## 目录

```
vmware-k8s/
├── build.cmd                    一键入口
├── build.ps1                    主脚本:变量区 + 阶段编排
├── lib/
│   ├── common.ps1               日志、下载(断点续传)、SHA256、工具探测
│   ├── packer.ps1               下载 Packer + 解析 ISO 地址 + 生成 user-data
│   ├── vmnet.ps1                vmnet 探测 + DHCP 池范围
│   ├── clone.ps1                full clone + .vmx 调整 + MAC/guestinfo 生成
│   ├── base.ps1                 k8s-base 这一层(装东西、关机)
│   └── k8s.ps1                  scp/ssh 复用 setup-k8s 脚本
├── packer/
│   ├── ubuntu-template.pkr.hcl  Packer 模板
│   └── http/
│       ├── user-data            Ubuntu autoinstall 配置(固定地址在这)
│       └── meta-data
├── guest/
│   ├── base-setup.sh            base 层:换源 / 免密 sudo / 装 clone-prep
│   ├── clone-prep.sh            克隆首启:重置 machine-id / host key / 配 IP
│   ├── clone-prep.service
│   └── region-shim.sh           k8s 层:把仓库脚本的地区判断固定住(见下)
├── tests/
│   ├── run-all.ps1              一键跑全部离线测试
│   ├── test-ps-syntax.ps1       语法 + UTF-8 BOM
│   ├── test-encoding.ps1        编码回归(见下)
│   ├── test-bash-syntax.ps1     guest 脚本 bash -n + user-data YAML
│   ├── test-userdata.ps1        autoinstall user-data 的结构
│   ├── test-vmnet-lease.ps1     DHCP 池范围读取 + 地址冲突判断
│   ├── test-node-defs.ps1       节点定义 / MAC 推导 / .vmx 改写
│   ├── test-k8s-config.ps1      生成的 setup-k8s/config.sh 对不对
│   ├── test-ipvs-removal.ps1    IPVS 拆除的回归护栏(见下)
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

`test-negative.ps1` 会在临时目录里复制一份代码,**故意改坏**(比如把固定地址改回
DHCP、把 `match: name` 改成写死 `ens33`),然后要求对应的检查必须报失败。改坏了
检查还是绿的,就说明那条断言是摆设 —— 这个仓库以前栽过"检查是绿的但其实什么都没
验"的跟头,所以每次加断言都要先证明它会咬。

---

## 踩过的坑(改代码前先看一眼)

### packer 找不到 guest IP(最贵的一个)

packer 找 guest IP 的办法**只有一个**:读 VMware 的 DHCP 租约文件
(`C:\ProgramData\VMware\vmnetdhcp.leases`),按 MAC 挑出**还没过期**的条目,
取其中**最早**的一条去连(见 packer 插件 `builder/vmware/common/driver.go` 的
`getLeaseAddresses`)。

而 Ubuntu live-server ISO 里,live 环境和装好的目标系统用的是**两种不同的 DHCP
client-id**:

```
live 环境   systemd-networkd  →  uid ff:29:58:75:53:00:03:00:01:<mac>
目标系统    dhclient          →  uid 01:<mac>
```

client-id 不同 → DHCP 派给它们的地址不同。实测 live 环境拿到 `10.10.10.10`、
目标系统拿到 `10.10.10.11`,于是 packer 死死地连着 live 环境那个地址,对着一台
永远不会有我们公钥的 sshd 一路撞到 `ssh_timeout` 耗尽 —— **40 分钟,模板永远
装不出来**,而且日志里只有满屏的 `unable to authenticate`。

解法不是"再等等",而是**根本不去猜**:autoinstall 的 `network` 段配固定地址
(官方文档写明它 *"is applied during installation as well as in the installed
system"*,也就是 live 环境和目标系统是同一个地址),packer 那边用
`ssh_host` 直接指过去,一行都不用猜。

`ssh_handshake_attempts` 也调大了(默认 10 次根本不够):从按下回车到装完系统
重启,packer 要在同一个地址上白等十几分钟。

### autoinstall 的 late-commands 没有 `curtin-installer` 这个命令

subiquity 的 late-commands 跑在**安装环境**里,目标系统挂在 `/target`;要在目标
系统里执行,官方给的形式是 `curtin in-target -- <cmd>`(它会 chroot 进 `/target`)。

写错成 `curtin-installer --target=/target --shell=sh -c "..."` 的后果是
`command not found` —— curtin 的子命令只有 install / in-target / system-install /
mkfs / pack 这些,压根没有 `curtin-installer`。

而且 **late-commands 失败不重试,直接中止整场安装**,屏幕上留下的是:

```
finish: subiquity/Late/run_user_supplied/command_0: ... returned non-zero
finish: subiquity/Install/install: Command execution failure: ...
```

第二个坑是路径:`curtin in-target --` 已经 chroot 进 `/target` 了,命令里的路径是
**目标系统视角**,不能再带 `/target` 前缀。

**现在模板里一个 late-commands 都不写** —— 免密 sudo、machine-id 重置这些挪到
base 阶段用 SSH 做,失败了能看见、能重试。`tests/test-userdata.ps1` 专门盯这条,
`tests/test-negative.ps1` 里的 M11 会把 late-commands 加回来,要求检查必须报红。

### PowerShell 5.1 的编码

5.1 里 `Get-Content` / `Set-Content` 的默认编码是**系统 ANSI 代码页**(中文 Windows
上是 GBK),不是 UTF-8。拿它们读写 UTF-8 文件,中文会变乱码;更阴的是某些多字节
序列被 GBK 误解后会把行尾吃掉,把下一行粘到上一行末尾。

实际后果:`packer/http/user-data` 是 UTF-8,一旦用 `Get-Content -Raw` 读再写回去,
`network:` 会变成

```
  # ...涓変釜鑺傜偣鐨勫湴鍧€鐢ㄩ潤鎬佺绾﹂拤姝汇€?  network:
```

—— 粘在注释后面了。YAML 照样能解析,但 subiquity 会**静默忽略**整段 network:
固定地址没配上,packer 就在一个没人听的地址上白等 40 分钟。

所以规矩定死:**读用 `Read-Utf8Text` / `Read-Utf8Lines`,写用 `Write-Utf8Text` /
`Write-Utf8Lines`(一律不带 BOM)**。`test-encoding.ps1` 会用 AST 扫生产脚本,
发现真的调了 `Get-Content` / `Set-Content` 就报错。

### 其他几条

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
之后在 guest 上统一 `sed -i 's/\r$//'`。

**PowerShell 可展开 here-string 会吃掉 shell 语法**:`@"..."@` 里的
`${CLUSTER_NAME:-"devops-k8s"}` 会被当成变量引用,输出变成 `CLUSTER_NAME=`。写
config.sh 这种要给 bash source 的文件,要么用单引号 here-string,要么逐行拼。

**`headless=false` 时 VMware 图形界面会删掉产物**:GUI 接管由 vmrun 启动的、
并不在"库"里的 VM,等它关机时会把整个 output 目录(含 20G 的 disk.vmdk)当临时
产物清掉。所以 `headless` 默认 `true`,排障时才用 `-ShowWindow` 弹窗口。

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
`ssh vagrant@10.10.10.201 'kubectl get pods -A'`

**想重来**
```
vmware-k8s\build.cmd -Stage destroy          # 删掉 base 和三个节点
vmware-k8s\build.cmd -Stage template -ForceTemplate
```
