# homelab-pve
PVE with Github runner, build HomeLab Environment

```shell
# 只为 GitHub 设置代理
git config http.https://github.com.proxy http://127.0.0.1:38457
```

## IP和网段
PVE默认是vmbr0， 新建一个vmbr1,设置为10.10.10.0/24

```shell
STORAGE='local-zfs'   # 'local-lvm' 'local' 'local-zfs'
DNS='223.5.5.5'    # '192.168.168.168' # PVE启动了一个coredns,用于加速和缓存
CIDR='10.10.10'

# Linux虚拟机模板ID说明
# 2003: Alibaba Cloud Linux 3
# 2007: CentOS 7 
# 2008: AlmaLinux 8 
# 2009: AlmaLinux 9
# 20010: AlmaLinux 10

# 2109: CentOS Stream 9
# 21010: CentOS Stream 10

# 2112: Debian 12
# 2113: Debian 13

# 2204: Ubuntu 2204
# 2403: openEuler-24.03
# 2404: Ubuntu 2404
# 2604: Ubuntu 2604

# 虚拟机ID说明：
# 虚拟机网段为10.10.10. 
# 虚拟机ID为： 10+${IP尾号}
# 比如 1010 --> IP尾号是10， IP是10.10.10.10
# 比如 1011 --> IP尾号是11， IP是10.10.10.11
# 比如 10200 --> IP尾号是200， IP是10.10.10.200
# 比如 10250 --> IP尾号是250

# k8s实验环境， 1010~1019为k8s master网段，  10101~10109为k8s worker网段
# k8s配套的MetalLB的网段， 10120~10150
# 其他高可用或者服务实验，网段为10200~10250
```
## pipelines

### Code Server
直接部署code server到PVE上, 打开浏览器即可写代码

### pve os template
### pve create VMs
### kubeadm k8s
https://github.com/TimeBye/kubeadm-ha
### setup k8s cluster via k0s
### setup k8s cluster via k3s
### setup k8s cluster via kubeadm
### setup k8s cluster via ansible

### CICD Pipeline
- Gitea 
- Drone

### Docker registry
- Docker Registry (registry:2)	
- Harbor
- 阿里云 ACR 个人版

### Artifact制品库
- 纯 Maven/NPM: JFrog Artifactory OSS
- 通用全家桶: Nexus3 OSS
- 云托管白嫖: 华为云 CodeArts Artifact 个人版

### Storage

| 需求          | 推荐方案                             | 最低配置   | 一键落地/容器化                                                                   | 适用场景                                     |
| ----------- | -------------------------------- | ------ | -------------------------------------------------------------------------- | ---------------------------------------- |
| **轻量单节点**   | TrueNAS SCALE 或 UnRAID           | 2C4G   | `docker run -d truenas/scale` 或官方 ISO 安装                                   | 开箱即用，支持 SMB/NFS/TimeMachine，Web UI 管理硬盘  |
| **分布式/多节点** | Ceph 或 GlusterFS                 | 3×2C4G | K3s + `rook-ceph` Helm Chart                                               | 跨节点冗余，支持块/对象/文件存储                        |
| **云备份**     | rclone + davfs | 任意     | `rclone mount` + `restic backup`                                           | 异地容灾，加密去重                                |


### OSS MinIO RustFS
- Docker compose 启动MinIO
- k3s 部署MinIO Operator
- RustFS 替代 MinIO

### Monitor
Prometheus + Grafana + Loki + Alertmanager	
homelab-setup	
LibreNMS + SmokePing	
Hashi-Homelab	
Beszel
Uptime-Kuma	
Scrutiny

### DNS
要求既可以解析公网地址,又可以解析k8s内的service
- 极简方案：CoreDNS + hosts 插件（单节点即可）
```shell
docker run -d --name coredns \
  -p 53:53/udp \
  -v $(pwd)/Corefile:/Corefile \
  coredns/coredns:latest

# Corefile 示例
. {
    hosts {
        192.168.1.100  minio.lab.local
        192.168.1.101  gitea.lab.local
        fallthrough
    }
    kubernetes cluster.local 10.96.0.0/12 {
        pods insecure
        fallthrough
    }
    forward . 8.8.8.8 1.1.1.1
    log
}
```
- 进阶方案：NodeLocal DNSCache + CoreDNS（高可用/多节点）