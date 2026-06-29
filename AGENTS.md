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
- `setup-k8s/scripts/01-base-pkgs.sh` is OS-specific and changes host state: installs base packages, disables swap, configures chrony, loads kernel modules, and disables firewalld/SELinux on RPM distros.
- `setup-k8s/scripts/04-kubeadm-init.sh` switches the kubeadm image repository to Aliyun in CN, otherwise uses `registry.k8s.io`.
- The init script expects `MASTER_NODES`, `LoadBalancer`, `POD_CIDR`, and `SERVICE_CIDR` to be set; `config.sh.example` shows the default shape.

## Workflows and auth
- GitHub Actions workflows are the real orchestration layer; many are manual `workflow_dispatch` jobs and some generate `setup-k8s/config.sh` during the run.
- PVE access in workflows is Tailscale-based.
- `.vscode/mcp.json` points the `cnb` MCP server at `.env.mcp`; copy `.env.mcp.example` to `.env.mcp` before using it.

## Git remote convention
- The repo is set up for GitHub + CNB dual push.
- `git push github` and `git push cnb` target the individual remotes; if the optional `all` remote is configured, `git push` / `git pushall` push to both.
