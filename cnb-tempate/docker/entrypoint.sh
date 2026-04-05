#!/usr/bin/env bash
set -euo pipefail

TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TS_TUN_MODE="${TS_TUN_MODE:-userspace-networking}"
TS_EXTRA_DAEMON_ARGS="${TS_EXTRA_DAEMON_ARGS:-}"
TS_EXTRA_UP_ARGS="${TS_EXTRA_UP_ARGS:-}"
TS_ACCEPT_ROUTES="${TS_ACCEPT_ROUTES:-true}"

mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCKET}")"

start_daemon() {
  tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="${TS_SOCKET}" \
    --tun="${TS_TUN_MODE}" \
    ${TS_EXTRA_DAEMON_ARGS} &
  TS_DAEMON_PID=$!
}

wait_for_socket() {
  local retries=30
  local interval=1

  for _ in $(seq 1 "${retries}"); do
    if [[ -S "${TS_SOCKET}" ]]; then
      return 0
    fi
    sleep "${interval}"
  done

  echo "tailscaled socket did not become ready: ${TS_SOCKET}" >&2
  return 1
}

run_up_if_configured() {
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    echo "TS_AUTHKEY not provided, skip tailscale up"
    return 0
  fi

  local up_args=(--socket "${TS_SOCKET}" up --authkey "${TS_AUTHKEY}")

  if [[ -n "${TS_HOSTNAME:-}" ]]; then
    up_args+=(--hostname "${TS_HOSTNAME}")
  fi

  if [[ -n "${TS_ADVERTISE_TAGS:-}" ]]; then
    up_args+=(--advertise-tags "${TS_ADVERTISE_TAGS}")
  fi

  if [[ "${TS_ACCEPT_ROUTES}" == "true" ]]; then
    up_args+=(--accept-routes)
  fi

  if [[ -n "${TS_EXTRA_UP_ARGS}" ]]; then
    # shellcheck disable=SC2206
    local extra=(${TS_EXTRA_UP_ARGS})
    up_args+=("${extra[@]}")
  fi

  tailscale "${up_args[@]}"
}

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

start_daemon
wait_for_socket
run_up_if_configured

wait "${TS_DAEMON_PID}"
