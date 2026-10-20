# vmware-k8s — Packer 模板:Ubuntu LTS 装成一张可全克隆的模板盘
#
# 产出一个 2C/2G/20G 的 Ubuntu,用户名 vagrant,装了 open-vm-tools,
# 并预置了"克隆首启自检"服务(clone-prep)。之后由 build.ps1 用
# vmrun full clone 出 1 master + 2 worker。
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

variable "guest_scripts_dir" {
  type        = string
  description = "guest/ 目录,里面是预置进模板的脚本"
}

variable "http_dir" {
  type        = string
  default     = "http"
  description = "提供 autoinstall 用的 user-data / meta-data 的目录"
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

  # headless = false:让 VMware 的窗口显示出来。
  #
  # 这一条是为了"看得见" —— autoinstall 出问题的时候,屏幕上通常就
  # 明明白白写着原因(找不到 user-data、ds 写错、GRUB 没进命令行模式),
  # 比对着日志猜强太多。build 成功之后窗口自己关掉。
  # 跑在没有桌面的机器上时改回 true。
  headless  = false
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
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ip=dhcp ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]

  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_private_key_file = var.ssh_private_key_file
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
  vmx_data = {
    "ethernet0.addressType"        = "generated"
    "annotation"                   = "built by packer for vmware-k8s"
    "isolation.tools.hgfs.disable" = "TRUE"
    "tools.syncTime"               = "TRUE"
  }
}

build {
  name    = "ubuntu-template"
  sources = ["source.vmware-iso.ubuntu"]

  # 预置克隆首启要用的东西,并留下"我是一张模板"的标记。
  provisioner "file" {
    source      = "${var.guest_scripts_dir}/"
    destination = "/tmp/vmware-k8s-guest"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      # 去掉 CR 再执行。Windows 上 checkout 出来的 .sh 是 CRLF,
      # 直接 install 过去的话,每行末尾都多个 \r,脚本会莫名其妙地
      # 报 "command not found" 或者 set 选项不认。跟有没有
      # .gitattributes 无关 —— 在这里兜住最保险。
      "sudo sed -i 's/\\r$//' /tmp/vmware-k8s-guest/clone-prep.sh",
      "sudo mkdir -p /usr/local/sbin /etc/systemd/system",
      "sudo install -m 0755 /tmp/vmware-k8s-guest/clone-prep.sh /usr/local/sbin/vmware-clone-prep.sh",
      "sudo install -m 0644 /tmp/vmware-k8s-guest/clone-prep.service /etc/systemd/system/vmware-clone-prep.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable vmware-clone-prep.service",
      "sudo apt-get update",
      "sudo apt-get install -yq open-vm-tools curl wget jq chrony",
      "sudo systemctl enable --now open-vm-tools",
      # 标记模板本身:克隆出来的机器带着这个标记,首启时会重置
      # machine-id 和 SSH host key —— 这是 k8s 的硬要求,三个节点
      # 共用一套 machine-id 或 host key 的话集群根本起不来。
      "sudo touch /var/lib/vmware-template-sealed",
      "echo 'packer build finished'"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
