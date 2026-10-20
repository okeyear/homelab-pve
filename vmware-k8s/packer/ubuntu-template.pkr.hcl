# vmware-k8s — Packer 模板:Ubuntu LTS 装成一张可全克隆的模板盘
#
# 产出一个 2C/2G/20G 的最小化 Ubuntu:用户名 vagrant,装了 SSH 和
# open-vm-tools,固定地址 __TEMPLATE_IP__。
#
# 这一层**只**负责把系统装起来,别的什么都不干。之后的路是:
#
#   模板  ->  k8s-base  ->  三个 k8s 节点
#            (装 cloud-init / 换源 / 基础包 / containerd / k8s 组件)
#
# clone-prep 也不在模板里,而是 base 阶段才装 —— 真正要被克隆的是
# k8s-base,不是这张模板。
#
# 变量不写在这里,build.ps1 会生成 ubuntu-template.pkrvars.hcl。

packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.2"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Ubuntu live-server ISO 的直链"
}

variable "iso_checksum" {
  type        = string
  description = "file:<SHA256SUMS 的路径> 或 sha256:<hash>"
}

variable "vm_name" {
  type    = string
  default = "k8s-template"
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 2048
}

variable "disk_gb" {
  type    = number
  default = 20
}

variable "vmware_hardware_version" {
  type    = string
  default = "21"
  # 说明:这是**虚拟硬件版本号**(virtualHW.version),不是 Workstation 的
  # 产品版本 —— 两套号完全不是一回事:产品版本是 17.6 / 25.0.1 这种,
  # 虚拟硬件版本是 19 / 20 / 21 这种全局递增号。填错了 VMware 会弹
  # "created by a VMware product that is incompatible" 然后拒绝打开。
  #
  # 21 是 packer 插件自己的默认值(下限 19),兼容性最好。
  # 本机 Workstation 25.0.1 实测 19~25 都能开,21 最稳。
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type    = string
  default = "vagrant"
}

variable "ssh_private_key_file" {
  type        = string
  description = "宿主机上用来连进来的私钥"
}

variable "http_dir" {
  type        = string
  default     = "http"
  description = "提供 autoinstall 用的 user-data / meta-data 的目录"
}

variable "headless" {
  type        = bool
  default     = true
  description = <<-EOT
    true  = 用 vmrun nogui 启动,VMware 图形界面不接管这个 VM
    false = 弹 VMware 窗口,装机出错时屏幕上直接写着原因
  EOT
  # 默认 true 的原因:headless=false 时 VMware GUI 会接管这个由 vmrun
  # 启动的、并不在"库"里的 VM,等它关机时 GUI 会把这套文件(整个
  # output 目录,含 20G 的 disk.vmdk)当临时产物清掉 —— 实测就是这样:
  # build 还在等 SSH,output 目录却整个不见了。
  # 要看屏幕的时候把它改成 false,或者用 -ShowWindow。
}

variable "mac_address" {
  type        = string
  default     = ""
  description = "模板网卡的 MAC。留空 = 让 VMware 自己生成"
  # 每轮换一个,理由有二:
  #
  # 1. packer 找 guest IP 的办法是**读 VMware 的 DHCP 租约文件**,
  #    按 MAC 挑出当前还没过期的条目(见 packer 插件
  #    builder/vmware/common/driver.go 的 getLeaseAddresses)。
  #    VMware 自己生成的 MAC 不保证每次都不同 —— 实测连续两轮 build
  #    拿到的是同一个 00:0c:29:58:75:53,租约文件里留着上一轮的条目
  #    (租期 30 分钟),packer 会先去试那些**已经没人用**的地址。
  #    现在改成用 ssh_host 直接指定地址,这一条已经不致命了,但换掉
  #    随机 MAC 仍然能让租约文件干净,少一堆干扰。
  #
  # 2. 模板的 MAC 反正会被 clone 那一步覆盖成每个节点自己的,这里
  #    怎么选都不影响最终结果。
}

variable "ssh_host" {
  type        = string
  description = "guest 的固定地址。packer 直接连它,不再去猜"
  # 为什么必须显式指定:packer 找 guest IP 的唯一办法是读 VMware 的
  # DHCP 租约文件(见上面 getLeaseAddresses),然后取**最早**那条还没
  # 过期的条目去连。
  #
  # 而 Ubuntu live-server ISO 里,live 环境和装好的目标系统用的是两种
  # 不同的 DHCP client-id:
  #
  #   live 环境   systemd-networkd → uid ff:29:58:75:53:00:03:00:01:<mac>
  #   目标系统    dhclient         → uid 01:<mac>
  #
  # client-id 不同 → DHCP 派给它们的地址不同(实测 live 环境拿到
  # 10.10.10.10、目标系统拿到 10.10.10.11)。packer 于是死死连着 live
  # 环境那个地址,对着一个永远不会有我们公钥的 sshd 一路撞到
  # ssh_timeout 耗尽 —— 40 分钟,模板永远装不出来。
  #
  # 改成固定地址就彻底没这个问题:autoinstall 的 network 段官方写明
  # "is applied during installation as well as in the installed system",
  # 也就是 live 环境和目标系统用的是同一个地址。build.ps1 把同一个
  # 地址同时写进 user-data 的 network 段和这个变量,两边必然对得上。
}

variable "ssh_handshake_attempts" {
  type        = number
  default     = 1000
  description = "SSH 握手最多试几次"
  # 默认值(10)根本不够:从按下回车到装完系统重启,packer 要在 live
  # 环境的地址上白等十几分钟,每一次"连上了但认证不过"都算一次握手
  # 失败。调大它,让它一直等到目标系统起来、真正的 sshd 接管。
}

source "vmware-iso" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # 注意:这里没有 vmware_path。vmware 插件 v2.x(Packer 1.10+ 重写)
  # 已经去掉了这个参数,Workstation 的安装路径由插件自己探测 ——
  # packer validate 会直接报 "An argument named vmware_path is not
  # expected here"。
  version          = var.vmware_hardware_version
  output_directory = "output"
  vm_name          = var.vm_name

  guest_os_type = "ubuntu-64"
  # 插件 v2.x 要求显式指定网卡类型。vmxnet3 是 Linux guest 的正解,
  # e1000 是老设备模拟出来的,性能差一截。
  network_adapter_type = "vmxnet3"
  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_gb * 1024
  disk_type_id         = "0" # 0 = 可增长

  # headless 由 build.ps1 传(默认 true,理由见 variable "headless")。
  # true  = vmrun nogui 启动,VMware 图形界面不接管,关机会把整个
  #         output 目录当临时产物清掉。
  # false = 弹窗口,出错时屏幕上直接写着原因 —— 排障时用。
  headless  = var.headless
  boot_wait = "20s"

  # autoinstall(subiquity)从 http 拿 user-data / meta-data。
  # .HTTPIP 是宿主机在 vmnet 上的地址,模板能直接访问。
  http_directory = var.http_dir

  # ---- GRUB 按键序列 ----------------------------------------------------
  #
  # Ubuntu 22.04 及以后的 live-server ISO **不能**在 GRUB 菜单里直接敲
  # "autoinstall ..." —— 那样 GRUB 把整行当菜单操作,系统会进到交互式
  # 安装界面停住不动。正确做法是进 GRUB 命令行模式,手动把内核和
  # initramfs 加载起来。HashiCorp 官方的 iso-vars.pkr.hcl 也是这么写的。
  #
  # 26.04 的 /boot/grub/grub.cfg 实际内容(从 ISO 里读出来的,不是猜的):
  #
  #     set timeout=30
  #     menuentry "Try or Install Ubuntu Server" {
  #         set gfxpayload=keep
  #         linux  /casper/vmlinuz  ---
  #         initrd /casper/initrd
  #     }
  #
  # 所以有两条硬约束:
  #   1. timeout=30 —— 30 秒后会自动引导,必须在这之前按 <esc> 打断。
  #   2. 内核参数要接在 "---" **后面**(那是 initramfs 参数的位置,
  #      subiquity 就住在 initramfs 里),initrd 的路径是 /casper/initrd。
  #
  # ds 的值必须用单引号包起来:分号在 GRUB 里是**命令分隔符**,
  # 不包起来的话 "ds=nocloud-net;s=http://..." 会被截成两条命令,
  # 内核只拿到 ds=nocloud-net,装到一半找不到 user-data,而且报错
  # 指向 cloud-init,跟真正的病因隔着十万八千里。
  #
  # ---- systemd.mask=open-vm-tools.service ------------------------------
  #
  # 这条**曾经**是必须的,现在不需要了。
  #
  # 当初加它是因为 packer 靠 `vmrun getGuestIPAddress` 拿地址,而
  # live-server ISO 的 live 环境(casper)**自带并运行** open-vm-tools ——
  # 于是 packer 在**装机还没结束时**就拿到了 live 环境的 IP。
  # 装完 subiquity 会 reboot,系统进到目标系统,DHCP 往往会换一个地址,
  # packer 手里还攥着旧地址,就一路 i/o timeout 到 ssh_timeout 耗尽。
  #
  # 现在不用猜地址了(见 variable "ssh_host"),而且 mask 掉 Tools 还有
  # 副作用:插件的 "wait for tools" 那一步会一直等。live 环境里留着
  # Tools,插件那一步能立刻过,SSH 重试到目标系统起来为止。
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ip=dhcp ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/' <enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]

  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_private_key_file = var.ssh_private_key_file
  # 直接指定 guest 的固定地址,不去猜 DHCP 租约。理由见上面
  # variable "ssh_host" 的说明。
  ssh_host = var.ssh_host
  # 握手失败重试次数调大:装完系统要十几分钟,packer 会在这个地址上
  # 一直等到目标系统起来。
  ssh_handshake_attempts = var.ssh_handshake_attempts
  # 40 分钟:无人值守安装本身 10-20 分钟够用,超时的多半是哪里没配对
  # (GRUB 没进命令行模式 / 拿不到 user-data),早点失败早点能看见屏幕上的报错
  ssh_timeout = "40m"
  ssh_port    = 22

  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"

  # 只放插件不会自己设的键。displayName / ethernet0.vnet /
  # ethernet0.connectionType 都在其中:插件自己会设这几个,硬塞进去
  # packer validate 会警告 "may cause your build to fail or behave
  # unpredictably"。
  #
  # 模板本身不需要指定网段:vmware-iso 默认就挂在 NAT(vmnet8)上,
  # 装系统时能出网就够了。真正决定节点网段和 MAC 的是克隆那一步
  # (lib/clone.ps1 直接改 .vmx),所以这里不动。
  #
  # MAC:给了就写死(见 variable "mac_address" 的说明 —— 每轮换一个,
  # 是为了让 packer 能在 DHCP 租约文件里一眼认出本轮这台机器),
  # 没给就让 VMware 自己生成。
  vmx_data = merge(
    {
      "annotation"                   = "built by packer for vmware-k8s"
      "isolation.tools.hgfs.disable" = "TRUE"
      "tools.syncTime"               = "TRUE"
    },
    var.mac_address == "" ? {
      "ethernet0.addressType" = "generated"
      } : {
      "ethernet0.addressType" = "static"
      "ethernet0.address"     = var.mac_address
    }
  )
}

build {
  name    = "ubuntu-template"
  sources = ["source.vmware-iso.ubuntu"]

  # 刻意**不写任何 provisioner**。
  #
  # 这一层只负责"把 Ubuntu 装起来,并且能用 SSH 连进来",装完就关机
  # (shutdown_command)。预置 clone-prep、改 apt 源、装 containerd
  # 和 k8s 这些重活,全部挪到 base 阶段 —— 也就是先从这张模板克隆出
  # 一台 k8s-base,在那上面用 SSH 一步步做。
  #
  # 这么分的两个理由:
  #   1. 模板越薄,后面每一步失败都越好定位。autoinstall 的
  #      late-commands 失败会**中止整场安装**,装的东西越多,失败面
  #      越大 —— 之前把 15 个包和 6 条 late-commands 塞进模板,
  #      结果一次 i/o timeout 就把整场安装带走了。
  #   2. 重活失败可以重试。模板装坏了要重来 20 分钟,base 阶段失败
  #      只要重跑那一步。
  #
  # 模板盘不自带任何"我是一张模板"的标记 —— 标记改由 base 阶段打,
  # 因为真正要克隆的是 k8s-base,不是这张模板。

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
