#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_TMP=${TEST_TMP:-"${ROOT_DIR}/tests/integration/tmp"}
IMAGE=${IMAGE:-qbtvpn:ci}

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

fail() {
  log ERROR "$1"
  exit 1
}

retry() {
  local attempts=$1
  local delay=$2
  shift 2
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

ensure_tun() {
  if [[ ! -c /dev/net/tun ]]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200 || true
    sudo chmod 666 /dev/net/tun
  fi
  [[ -c /dev/net/tun ]] || fail "/dev/net/tun is unavailable"
}

cleanup_container() {
  docker rm -f "$@" >/dev/null 2>&1 || true
}

cleanup_paths() {
  local path
  for path in "$@"; do
    [[ -n "${path:-}" ]] || continue
    [[ -e "$path" || -L "$path" ]] || continue
    if ! rm -rf "$path" 2>/dev/null; then
      if command -v sudo >/dev/null 2>&1; then
        sudo rm -rf "$path"
      else
        rm -rf "$path"
      fi
    fi
  done
}

collect_container_logs() {
  local out_dir=$1
  shift
  mkdir -p "$out_dir"
  local name
  for name in "$@"; do
    docker logs "$name" > "${out_dir}/${name}.log" 2>&1 || true
    docker exec "$name" ip route > "${out_dir}/${name}.routes" 2>&1 || true
    docker exec "$name" iptables -S > "${out_dir}/${name}.iptables" 2>&1 || true
    docker exec "$name" ip6tables -S > "${out_dir}/${name}.ip6tables" 2>&1 || true
  done
}

extract_temp_password() {
  local name=$1
  docker logs "$name" 2>&1 \
    | sed -nE 's/.*temporary password[^:]*: ([^[:space:]]+).*/\1/p' \
    | tail -n 1
}

webui_scheme() {
  local config_dir=$1
  local conf="${config_dir}/qBittorrent/config/qBittorrent.conf"
  if [[ -f "$conf" ]] && grep -Fq 'WebUI\HTTPS\Enabled=true' "$conf"; then
    printf 'https'
  else
    printf 'http'
  fi
}

qbt_login_cookie() {
  local base=$1
  local password=$2
  local cookie=$3
  local curl_tls=(-fsS)
  [[ "$base" == https://* ]] && curl_tls=(-fksS)
  curl "${curl_tls[@]}" -c "$cookie" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=${password}" \
    "${base}/api/v2/auth/login" | grep -q '^Ok\.$'
}

qbt_api_version() {
  local base=$1
  local cookie=$2
  local curl_tls=(-fsS)
  [[ "$base" == https://* ]] && curl_tls=(-fksS)
  curl "${curl_tls[@]}" -b "$cookie" "${base}/api/v2/app/version"
}

wait_for_qbt() {
  local name=$1
  local port=$2
  local scheme=$3
  local cookie=$4
  local password
  local base="${scheme}://127.0.0.1:${port}"
  local i
  for ((i = 1; i <= 90; i++)); do
    password=$(extract_temp_password "$name" || true)
    if [[ -n "$password" ]] && qbt_login_cookie "$base" "$password" "$cookie"; then
      qbt_api_version "$base" "$cookie" | grep -Eq '^v?5\.1\.'
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "qBittorrent WebUI did not become ready for ${name}"
}

assert_container_exited_nonzero() {
  local name=$1
  local status
  status=$(docker inspect -f '{{.State.ExitCode}}' "$name")
  [[ "$status" != "0" ]] || fail "${name} exited with status 0, expected failure"
}
