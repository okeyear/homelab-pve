# AGENTS.md

## What this repo is
- PVE + Kubernetes homelab automation.
- Main entrypoints: `.github/workflows/*.yml`, `setup-k8s/main.sh`, `setup-k8s/main-pve.sh`, `docker/entrypoint.sh`.

## Read first
- Prefer executable sources of truth over README prose.
- Highest-value files here: root README, `.github/workflows/*.yml`, `setup-k8s/config.sh.example`, `setup-k8s/scripts/functions.sh`, `setup-k8s/scripts/01-base-pkgs.sh`, `setup-k8s/scripts/04-kubeadm-init.sh`, `docker/README_DOCKER.md`.

## Repo-specific run flow
- `setup-k8s/main.sh` is the remote bootstrap path: it sources `setup-k8s/config.sh` if present, downloads containerd/runc/CNI into `setup-k8s/pkgs/`, then rsyncs `setup-k8s/` to each node and runs the numbered scripts over SSH.
- `setup-k8s/main-pve.sh` is the local-on-PVE path and runs the same numbered scripts directly.
- Copy `setup-k8s/config.sh.example` to `setup-k8s/config.sh` before running k8s setup.

## K8s setup quirks
- `setup-k8s/scripts/functions.sh` auto-chooses `GHPROXY`/mirrors based on country code; do not assume raw GitHub URLs are used everywhere.
- The country code comes from `functions.sh`'s `detect_region()`: it queries `ipinfo.io/country`, `ipwho.is`, `sysad.win`, `ip-api.com/json` in that order and takes the first valid 2-letter code (3 rounds). `sysad.win` and `ip-api.com` must be queried over **http** (https is broken for both); `ipwho.is` returns indented JSON, so the grep has to tolerate the space after the colon.
- **Never let the country detection end up empty.** Empty `REGION` means the CN mirror is skipped and `registry.k8s.io` is used, whose manifest requests 307-redirect to `europe-west3-docker.pkg.dev` — unreachable from CN, so containerd retries forever, `kubeadm init` never returns, and nodes crash-loop on a missing `/var/lib/kubelet/config.yaml`. `functions.sh` has a mirror-reachability fallback for this; keep it.
- `setup-k8s/scripts/01-base-pkgs.sh` is OS-specific and changes host state: installs base packages, disables swap, configures chrony, loads kernel modules, and disables firewalld/SELinux on RPM distros.
- `setup-k8s/scripts/01-base-pkgs.sh` no longer touches IPVS: kube-proxy's IPVS mode is deprecated in Kubernetes 1.37 (upstream plan: `--mode` defaults to nftables in 1.40, IPVS is removed in 1.43). The script no longer installs `ipvsadm`, no longer loads `ip_vs*`, and only removes a leftover `/etc/modules-load.d/ipvs.conf`.
- **The proxy mode was never IPVS.** kubeadm writes `mode: ""` into the kube-proxy ConfigMap, and kube-proxy treats an empty mode as `iptables` (verified on v1.34.12) — so the `ip_vs*` modules the script used to install were dead weight. `setup-k8s/scripts/04-kubeadm-init.sh` now pins `KUBE_PROXY_MODE=iptables` into that ConfigMap and restarts the kube-proxy DaemonSet; an empty mode is deprecated in 1.37 and would silently become `nftables` on 1.40.
- Every `kubectl` in `04-kubeadm-init.sh` must pass `--kubeconfig /etc/kubernetes/admin.conf`: `admin.conf` is root-only (600) and root's `HOME` is `/root` (no `~/.kube/config`), so without it kubectl falls back to `localhost:8080` and fails with "couldn't get current server API group list".
- `vmware-k8s/tests/test-ipvs-removal.ps1` guards all of the above; `vmware-k8s/tests/test-negative.ps1` cases M21–M26 prove those assertions actually bite.
- `setup-k8s/scripts/04-kubeadm-init.sh` switches the kubeadm image repository to Aliyun in CN, otherwise uses `registry.k8s.io`.
- The init script expects `MASTER_NODES`, `LoadBalancer`, `POD_CIDR`, and `SERVICE_CIDR` to be set; `config.sh.example` shows the default shape.
- `setup-k8s/scripts/*.sh` have no `set -e`, so their exit code is the last command's — never treat a non-zero exit as "the step failed" without checking the actual state.
- `setup-k8s/scripts/08-2-cni-calico.sh` rewrites `quay.io/calico/` to the Docker Hub cache `registry.cn-beijing.aliyuncs.com/my-dockermirrors/`, which does not hold the calico images — pods land in `ImagePullBackOff` and nodes stay `NotReady`.
- `setup-k8s/scripts/08-2-cni-calico.sh` fetches the calico manifest through `GHPROXY`, and the CN proxy sometimes resets the connection mid-download. The script has no `set -e`, so it keeps going and finally fails with `the path "calico.yaml" does not exist` — that error means **the download failed**, not that the path is wrong. `vmware-k8s` retries the script (deleting the partial file first) up to 3 times.

## Workflows and auth
- GitHub Actions workflows are the real orchestration layer; many are manual `workflow_dispatch` jobs and some generate `setup-k8s/config.sh` during the run.
- PVE access in workflows is Tailscale-based.
- `.vscode/mcp.json` points the `cnb` MCP server at `.env.mcp`; copy `.env.mcp.example` to `.env.mcp` before using it.

## Git remote convention
- The repo is set up for GitHub + CNB dual push.
- `git push github` and `git push cnb` target the individual remotes; if the optional `all` remote is configured, `git push` / `git pushall` push to both.
