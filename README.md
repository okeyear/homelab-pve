# homelab-pve
PVE with Github runner, build HomeLab Environment

## pipelines

### pve os template
### pve create VMs

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
| **多盘位高可靠**  | ZFS + mdadm RAID1/5/6            | 2C4G   | Ubuntu 22.04 + `zfsutils-linux`                                            | 数据校验+快照，适合重要资料                           |
| **分布式/多节点** | Ceph 或 GlusterFS                 | 3×2C4G | K3s + `rook-ceph` Helm Chart                                               | 跨节点冗余，支持块/对象/文件存储                        |
| **极简容器卷**   | Portainer + NFS / Samba          | 1C2G   | `docker run -d portainer/portainer-ce` + `itsthenetwork/nfs-server-alpine` | 给 Docker/K8s 提供持久卷                       |
| **云备份**     | rclone + Backblaze B2 / OneDrive | 任意     | `rclone mount` + `restic backup`                                           | 异地容灾，加密去重                                |


### OSS MinIO
- Docker compose 启动MinIO
- k3s 部署MinIO Operator

### Code Server
直接部署code server到PVE上, 打开浏览器即可写代码

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