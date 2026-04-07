# Debian + Tailscale Docker Usage

This repo now includes a Debian-based container build for installing and running Tailscale in Docker.

## Files

- `install-tailscale-debian.sh`: installs Tailscale from official package repo
- `entrypoint.sh`: starts `tailscaled`, optionally runs `tailscale up`
- `Dockerfile.debian`: base image and runtime wiring

## Build

```bash
cd docker
docker build -f Dockerfile-debian-tailscale -t tailscale:latest .
docker tag tailscale:latest registry.cn-beijing.aliyuncs.com/my-dockermirrors/tailscale:latest
docker push registry.cn-beijing.aliyuncs.com/my-dockermirrors/tailscale:latest
```

## Runtime modes

### 1) Userspace networking mode (recommended in containers)

Does not require `/dev/net/tun`, easier to run in most CI/container platforms.

```bash
docker run --rm -it \
  --name tailscale-userspace \
  -e TS_AUTHKEY=tskey-xxxxx \
  -e TS_HOSTNAME=ci-node \
  -e TS_ADVERTISE_TAGS=tag:ci \
  -v tailscale-state:/var/lib/tailscale \
  tailscale:latest
```

### 2) Kernel TUN mode (higher performance, needs extra privileges)

```bash
docker run --rm -it \
  --name tailscale-kernel \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device=/dev/net/tun \
  -e TS_TUN_MODE=tun \
  -e TS_AUTHKEY=tskey-xxxxx \
  -e TS_HOSTNAME=ci-node \
  -e TS_ADVERTISE_TAGS=tag:ci \
  -v tailscale-state:/var/lib/tailscale \
  tailscale:latest
```

## Docker permissions explained

- `--cap-add=NET_ADMIN`: required for route, firewall, and tunnel network changes in kernel mode.
- `--cap-add=SYS_MODULE`: needed only if your environment requires loading kernel modules from inside the container.
- `--device=/dev/net/tun`: required for kernel TUN mode.
- `-v tailscale-state:/var/lib/tailscale`: persists state and node identity across restarts.

For userspace mode, you typically do not need `NET_ADMIN`, `SYS_MODULE`, or `/dev/net/tun`.

## Supported environment variables

- `TS_AUTHKEY`: auth key used by `tailscale up` (if empty, `tailscale up` is skipped)
- `TS_HOSTNAME`: optional hostname for `tailscale up`
- `TS_ADVERTISE_TAGS`: optional tags, e.g. `tag:ci`
- `TS_ACCEPT_ROUTES`: `true`/`false`, default `true`
- `TS_TUN_MODE`: `userspace-networking` (default) or `tun`
- `TS_STATE_DIR`: defaults to `/var/lib/tailscale`
- `TS_SOCKET`: defaults to `/var/run/tailscale/tailscaled.sock`
- `TS_EXTRA_DAEMON_ARGS`: extra args passed to `tailscaled`
- `TS_EXTRA_UP_ARGS`: extra args passed to `tailscale up`
- `TS_CHANNEL`: package channel for install script (`stable`/`unstable`)
- `TS_VERSION`: optional package version pin during image build

## Custom command

If you pass a command to `docker run`, entrypoint executes it directly:

```bash
docker run --rm -it tailscale:latest tailscale version
```
