#!/usr/bin/env bash
set -euo pipefail

TS_CHANNEL="${TS_CHANNEL:-stable}"
TS_VERSION="${TS_VERSION:-}"

if [[ "${TS_CHANNEL}" != "stable" && "${TS_CHANNEL}" != "unstable" ]]; then
  echo "TS_CHANNEL must be 'stable' or 'unstable'" >&2
  exit 1
fi

source /etc/os-release
CODENAME="${VERSION_CODENAME:-bookworm}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -d -m 0755 /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/${TS_CHANNEL}/debian/${CODENAME}.noarmor.gpg" \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

curl -fsSL "https://pkgs.tailscale.com/${TS_CHANNEL}/debian/${CODENAME}.tailscale-keyring.list" \
  | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

apt-get update
if [[ -n "${TS_VERSION}" ]]; then
  apt-get install -y --no-install-recommends "tailscale=${TS_VERSION}*"
else
  apt-get install -y --no-install-recommends tailscale
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
