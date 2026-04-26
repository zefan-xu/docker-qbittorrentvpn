#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_TMP=${TEST_TMP:-"${ROOT_DIR}/tests/integration/tmp"}
IMAGE=${IMAGE:-qbtvpn:ci}
PROBE_IMAGE=${PROBE_IMAGE:-qbtvpn-probe:ci}
TORRENT_LAB_IMAGE=${TORRENT_LAB_IMAGE:-qbtvpn-torrent-lab:ci}

ASSERTIONS_PASSED=0
SCENARIO_NAME=${SCENARIO_NAME:-standalone}
SCENARIO_MIN_ASSERTIONS=1
declare -ga SCENARIO_REQUIRED_EVIDENCE=()
declare -gA SCENARIO_EVIDENCE=()

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

redact() {
  sed -E \
    -e 's/(VPN_PASSWORD=)[^[:space:]]+/\1<redacted>/g' \
    -e 's/(password=)[^&[:space:]]+/\1<redacted>/Ig' \
    -e 's/(Password[^=]*=).*/\1<redacted>/Ig' \
    -e 's/(PrivateKey[[:space:]]*=[[:space:]]*).*/\1<redacted>/Ig'
}

compact() {
  local value=${1:-}
  value=$(printf '%s' "$value" | tr '\n' ' ' | tr -s '[:space:]' ' ' | redact)
  if (( ${#value} > 500 )); then
    printf '%s...' "${value:0:500}"
  else
    printf '%s' "$value"
  fi
}

fail() {
  log ERROR "$1"
  exit 1
}

begin_scenario() {
  SCENARIO_NAME=$1
  SCENARIO_MIN_ASSERTIONS=${2:-1}
  shift 2 || true
  ASSERTIONS_PASSED=0
  SCENARIO_REQUIRED_EVIDENCE=("$@")
  SCENARIO_EVIDENCE=()
  log INFO "BEGIN scenario=${SCENARIO_NAME} min_assertions=${SCENARIO_MIN_ASSERTIONS} required_evidence=${SCENARIO_REQUIRED_EVIDENCE[*]:-none}"
}

record_evidence() {
  local key=$1
  local value=${2:-present}
  SCENARIO_EVIDENCE["$key"]=$value
  log INFO "EVIDENCE scenario=${SCENARIO_NAME} ${key}=$(compact "$value")"
}

record_pass() {
  local name=$1
  local evidence=${2:-ok}
  ASSERTIONS_PASSED=$((ASSERTIONS_PASSED + 1))
  log INFO "PASS scenario=${SCENARIO_NAME} assertion=${ASSERTIONS_PASSED} check=${name} evidence=$(compact "$evidence")"
}

check_start() {
  log INFO "CHECK scenario=${SCENARIO_NAME} check=$1"
}

end_scenario() {
  local key
  if (( ASSERTIONS_PASSED < SCENARIO_MIN_ASSERTIONS )); then
    fail "Scenario ${SCENARIO_NAME} recorded ${ASSERTIONS_PASSED} assertions, expected at least ${SCENARIO_MIN_ASSERTIONS}"
  fi
  for key in "${SCENARIO_REQUIRED_EVIDENCE[@]}"; do
    if [[ -z "${SCENARIO_EVIDENCE[$key]:-}" ]]; then
      fail "Scenario ${SCENARIO_NAME} did not record required evidence key '${key}'"
    fi
  done
  log INFO "END scenario=${SCENARIO_NAME} assertions=${ASSERTIONS_PASSED} status=passed"
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
  check_start "host tun device available"
  if [[ ! -c /dev/net/tun ]]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200 || true
    sudo chmod 666 /dev/net/tun
  fi
  [[ -c /dev/net/tun ]] || fail "/dev/net/tun is unavailable"
  record_pass "host tun device available" "/dev/net/tun exists"
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
    docker inspect "$name" > "${out_dir}/${name}.inspect.json" 2>&1 || true
    docker exec "$name" ip addr > "${out_dir}/${name}.ip-addr" 2>&1 || true
    docker exec "$name" ip route > "${out_dir}/${name}.routes" 2>&1 || true
    docker exec "$name" iptables -S > "${out_dir}/${name}.iptables" 2>&1 || true
    docker exec "$name" ip6tables -S > "${out_dir}/${name}.ip6tables" 2>&1 || true
    docker exec "$name" sh -c 'test -f /run/qbtvpn/state.env && cat /run/qbtvpn/state.env' \
      | redact > "${out_dir}/${name}.state.env" 2>&1 || true
    docker exec "$name" sh -c 'test -f /config/qBittorrent/config/qBittorrent.conf && cat /config/qBittorrent/config/qBittorrent.conf' \
      | redact > "${out_dir}/${name}.qbt.conf" 2>&1 || true
    docker exec "$name" wg show > "${out_dir}/${name}.wg-show" 2>&1 || true
  done
}

assert_eq() {
  local name=$1
  local expected=$2
  local actual=$3
  check_start "$name"
  [[ "$actual" == "$expected" ]] || fail "${name}: expected '${expected}', got '${actual}'"
  record_pass "$name" "$actual"
}

assert_contains() {
  local name=$1
  local haystack=$2
  local needle=$3
  check_start "$name"
  grep -F -- "$needle" <<< "$haystack" >/dev/null || fail "${name}: expected output to contain '${needle}'"
  record_pass "$name" "$needle"
}

assert_not_contains() {
  local name=$1
  local haystack=$2
  local needle=$3
  check_start "$name"
  if grep -F -- "$needle" <<< "$haystack" >/dev/null; then
    fail "${name}: output unexpectedly contained '${needle}'"
  fi
  record_pass "$name" "absent: ${needle}"
}

assert_regex() {
  local name=$1
  local haystack=$2
  local regex=$3
  check_start "$name"
  grep -E -- "$regex" <<< "$haystack" >/dev/null || fail "${name}: expected output to match '${regex}'"
  record_pass "$name" "$regex"
}

assert_file_exists() {
  local name=$1
  local path=$2
  check_start "$name"
  [[ -f "$path" ]] || fail "${name}: file does not exist: ${path}"
  record_pass "$name" "$path"
}

assert_file_contains() {
  local name=$1
  local path=$2
  local needle=$3
  check_start "$name"
  [[ -f "$path" ]] || fail "${name}: file does not exist: ${path}"
  grep -F -- "$needle" "$path" >/dev/null || fail "${name}: expected ${path} to contain '${needle}'"
  record_pass "$name" "${path}: ${needle}"
}

assert_file_not_contains() {
  local name=$1
  local path=$2
  local needle=$3
  check_start "$name"
  [[ -f "$path" ]] || fail "${name}: file does not exist: ${path}"
  if grep -F -- "$needle" "$path" >/dev/null; then
    fail "${name}: ${path} unexpectedly contains '${needle}'"
  fi
  record_pass "$name" "${path}: absent ${needle}"
}

assert_command_succeeds() {
  local name=$1
  shift
  check_start "$name"
  local output
  if ! output=$("$@" 2>&1); then
    log ERROR "${name}: command failed: $*"
    log ERROR "${name}: output=$(compact "$output")"
    return 1
  fi
  record_pass "$name" "${output:-command exited 0}"
}

assert_command_fails() {
  local name=$1
  shift
  check_start "$name"
  local output
  if output=$("$@" 2>&1); then
    log ERROR "${name}: command unexpectedly succeeded: $*"
    log ERROR "${name}: output=$(compact "$output")"
    return 1
  fi
  record_pass "$name" "${output:-command failed as expected}"
}

command_output() {
  "$@" 2>&1
}

assert_command_output_contains() {
  local name=$1
  local needle=$2
  shift 2
  local output
  output=$(command_output "$@") || fail "${name}: command failed: $* output=$(compact "$output")"
  assert_contains "$name" "$output" "$needle"
}

extract_temp_password() {
  local name=$1
  docker logs "$name" 2>&1 \
    | sed -nE 's/.*temporary password[^:]*: ([^[:space:]]+).*/\1/p' \
    | tail -n 1
}

curl_for_scheme() {
  local scheme=$1
  if [[ "$scheme" == https ]]; then
    printf '%s\n' -fksS
  else
    printf '%s\n' -fsS
  fi
}

qbt_login_cookie() {
  local base=$1
  local password=$2
  local cookie=$3
  local curl_tls
  mapfile -t curl_tls < <(curl_for_scheme "${base%%://*}")
  curl "${curl_tls[@]}" -c "$cookie" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=${password}" \
    "${base}/api/v2/auth/login" | grep -q '^Ok\.$'
}

qbt_api_get() {
  local base=$1
  local cookie=$2
  local path=$3
  local curl_tls
  mapfile -t curl_tls < <(curl_for_scheme "${base%%://*}")
  curl "${curl_tls[@]}" -b "$cookie" "${base}${path}"
}

qbt_api_post() {
  local base=$1
  local cookie=$2
  local path=$3
  shift 3
  local curl_tls
  mapfile -t curl_tls < <(curl_for_scheme "${base%%://*}")
  curl "${curl_tls[@]}" -b "$cookie" -X POST "$@" "${base}${path}"
}

wait_for_qbt() {
  local name=$1
  local port=$2
  local scheme=$3
  local cookie=$4
  local password base version
  base="${scheme}://127.0.0.1:${port}"
  check_start "qBittorrent WebUI ready for ${name}"
  local i
  for ((i = 1; i <= 90; i++)); do
    password=$(extract_temp_password "$name" || true)
    if [[ -n "$password" ]] && qbt_login_cookie "$base" "$password" "$cookie"; then
      version=$(qbt_api_get "$base" "$cookie" /api/v2/app/version)
      if grep -Eq '^v?5\.1\.' <<< "$version"; then
        record_evidence webui_version "$version"
        record_pass "qBittorrent WebUI ready for ${name}" "${base} version=${version}"
        return 0
      fi
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "qBittorrent WebUI did not become ready for ${name}"
}

assert_http_ok() {
  local name=$1
  local url=$2
  shift 2 || true
  check_start "$name"
  local output
  output=$(curl -fsS "$@" "$url") || fail "${name}: curl failed for ${url}"
  record_pass "$name" "${url}: $(compact "$output")"
}

assert_container_running() {
  local name=$1
  local container=$2
  check_start "$name"
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$container")
  [[ "$running" == true ]] || fail "${name}: ${container} is not running"
  record_pass "$name" "${container} running"
}

assert_container_exited_nonzero() {
  local name=$1
  local container=$2
  check_start "$name"
  local running status
  running=$(docker inspect -f '{{.State.Running}}' "$container")
  status=$(docker inspect -f '{{.State.ExitCode}}' "$container")
  [[ "$running" == false ]] || fail "${name}: ${container} is still running"
  [[ "$status" != "0" ]] || fail "${name}: ${container} exited with status 0, expected failure"
  record_pass "$name" "${container} exit=${status}"
}

assert_docker_logs_contains() {
  local name=$1
  local container=$2
  local needle=$3
  local logs
  logs=$(docker logs "$container" 2>&1 | redact)
  assert_contains "$name" "$logs" "$needle"
}

wait_docker_logs_contains() {
  local name=$1
  local container=$2
  local needle=$3
  local timeout=${4:-60}
  local deadline=$((SECONDS + timeout))
  local logs
  check_start "$name"
  while (( SECONDS < deadline )); do
    logs=$(docker logs "$container" 2>&1 | redact)
    if grep -F -- "$needle" <<< "$logs" >/dev/null; then
      record_pass "$name" "$needle"
      return 0
    fi
    sleep 2
  done
  fail "${name}: expected logs for ${container} to contain '${needle}' within ${timeout}s"
}

assert_docker_logs_not_contains() {
  local name=$1
  local container=$2
  local needle=$3
  local logs
  logs=$(docker logs "$container" 2>&1 | redact)
  assert_not_contains "$name" "$logs" "$needle"
}

wait_exit() {
  local name=$1
  local timeout=${2:-45}
  local deadline=$((SECONDS + timeout))
  check_start "${name} exits within ${timeout}s"
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == false ]]; then
      record_pass "${name} exits within ${timeout}s" "container stopped"
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "${name} did not exit within ${timeout}s"
}

iptables_policy() {
  local name=$1
  local tool=$2
  local chain=$3
  docker exec "$name" "$tool" -S "$chain" 2>/dev/null | sed -n '1p'
}

assert_iptables_policy() {
  local name=$1
  local container=$2
  local tool=$3
  local chain=$4
  local expected=$5
  check_start "$name"
  local first
  first=$(iptables_policy "$container" "$tool" "$chain") || fail "${name}: unable to read ${tool} ${chain}"
  [[ "$first" == "-P ${chain} ${expected}" ]] || fail "${name}: expected '-P ${chain} ${expected}', got '${first}'"
  record_evidence "${tool}_${chain}_policy" "$expected"
  record_pass "$name" "$first"
}

assert_container_output_contains() {
  local name=$1
  local container=$2
  local needle=$3
  shift 3
  local output
  output=$(docker exec "$container" "$@" 2>&1) || fail "${name}: docker exec failed: $* output=$(compact "$output")"
  assert_contains "$name" "$output" "$needle"
}

assert_no_clear_egress() {
  local name=$1
  local container=$2
  local url=$3
  check_start "$name"
  if docker exec "$container" timeout 8 curl -fsS "$url" >/dev/null 2>&1; then
    fail "${name}: clear-net egress unexpectedly succeeded for ${url}"
  fi
  record_evidence no_clear_egress "$url"
  record_pass "$name" "${url} blocked"
}

assert_vpn_egress() {
  local name=$1
  local container=$2
  local url=$3
  check_start "$name"
  local output
  output=$(docker exec "$container" timeout 30 curl -fsS "$url" 2>&1) || fail "${name}: VPN egress failed for ${url}: $(compact "$output")"
  record_evidence vpn_egress "$url"
  record_pass "$name" "${url}: $(compact "$output")"
}

assert_sha256_file() {
  local name=$1
  local path=$2
  local expected=$3
  check_start "$name"
  local actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || fail "${name}: checksum mismatch for ${path}: expected ${expected}, got ${actual}"
  record_pass "$name" "${path} sha256=${actual}"
}

json_field() {
  local json=$1
  local expr=$2
  JSON_INPUT=$json python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1].split(".")
data = json.loads(os.environ["JSON_INPUT"])
for part in expr:
    if part == "":
        continue
    if isinstance(data, list):
        data = data[int(part)]
    else:
        data = data[part]
print(data)
PY
}

ensure_fixture_images() {
  if ! docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
    log INFO "Building fixture image ${PROBE_IMAGE}"
    docker build -t "$PROBE_IMAGE" "${ROOT_DIR}/tests/fixtures/probe"
  fi
  if ! docker image inspect "$TORRENT_LAB_IMAGE" >/dev/null 2>&1; then
    log INFO "Building fixture image ${TORRENT_LAB_IMAGE}"
    docker build -t "$TORRENT_LAB_IMAGE" "${ROOT_DIR}/tests/fixtures/torrent-lab"
  fi
}
