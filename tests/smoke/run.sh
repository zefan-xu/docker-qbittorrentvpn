#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../lib/testlib.sh
source "$(dirname "$0")/../lib/testlib.sh"

scenario=${1:-all}
ARTIFACT_DIR=${ARTIFACT_DIR:-"${ROOT_DIR}/tests/smoke/tmp/artifacts-${scenario}"}
mkdir -p "$ARTIFACT_DIR"

CLEANUP_CONTAINERS=()
CLEANUP_PATHS=()

cleanup_smoke() {
  local status=$?
  set +e
  if (( status != 0 && ${#CLEANUP_CONTAINERS[@]} > 0 )); then
    collect_container_logs "$ARTIFACT_DIR" "${CLEANUP_CONTAINERS[@]}"
  fi
  if (( ${#CLEANUP_CONTAINERS[@]} > 0 )); then
    cleanup_container "${CLEANUP_CONTAINERS[@]}"
  fi
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    cleanup_paths "${CLEANUP_PATHS[@]}"
  fi
  return "$status"
}

start_basic_container() {
  local name=$1
  local host_port=$2
  local config_dir=$3
  local downloads_dir=$4
  shift 4
  cleanup_container "$name"
  docker run -d --name "$name" \
    -e VPN_ENABLED=no \
    -p "${host_port}:8080" \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$@" \
    "$IMAGE" >/dev/null
}

test_smoke_http_vpn_disabled() {
  local name=qbtvpn-smoke-http
  local host_port=18080
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  CLEANUP_CONTAINERS+=("$name")
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir" "$cookie")

  start_basic_container "$name" "$host_port" "$config_dir" "$downloads_dir" \
    -e ENABLE_SSL=no -e PUID=1000 -e PGID=1000 -e UMASK=002

  wait_for_qbt "$name" "$host_port" http "$cookie"
  assert_command_succeeds "qBittorrent process exists" docker exec "$name" pgrep qbittorrent-nox
  assert_command_succeeds "container healthcheck command succeeds" docker exec "$name" /usr/local/bin/qbtvpn-container-healthcheck
  # shellcheck disable=SC2016
  assert_command_succeeds "abc user defaults to 1000:1000" docker exec "$name" sh -c 'test "$(id -u abc)" = 1000 && test "$(id -g abc)" = 1000'
  assert_file_contains "torrent port fixed in config" "${config_dir}/qBittorrent/config/qBittorrent.conf" 'Session\Port=8999'
  assert_file_contains "webui username seeded" "${config_dir}/qBittorrent/config/qBittorrent.conf" 'WebUI\Username=admin'
  record_evidence qbt_config "${config_dir}/qBittorrent/config/qBittorrent.conf"
}

test_smoke_https_default() {
  local name=qbtvpn-smoke-https
  local host_port=18081
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  CLEANUP_CONTAINERS+=("$name")
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir" "$cookie")

  start_basic_container "$name" "$host_port" "$config_dir" "$downloads_dir"

  wait_for_qbt "$name" "$host_port" https "$cookie"
  assert_file_exists "WebUI certificate generated" "${config_dir}/qBittorrent/config/WebUICertificate.crt"
  assert_file_exists "WebUI key generated" "${config_dir}/qBittorrent/config/WebUIKey.key"
  assert_file_contains "HTTPS enabled in config" "${config_dir}/qBittorrent/config/qBittorrent.conf" 'WebUI\HTTPS\Enabled=true'
  assert_command_fails "plain HTTP does not pass when HTTPS is enabled" curl -fsS "http://127.0.0.1:${host_port}/api/v2/app/version"
  record_evidence https_webui "enabled"
}

test_smoke_uid_gid_umask() {
  local name=qbtvpn-smoke-uidgid
  local host_port=18082
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  CLEANUP_CONTAINERS+=("$name")
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir" "$cookie")

  start_basic_container "$name" "$host_port" "$config_dir" "$downloads_dir" \
    -e ENABLE_SSL=no -e PUID=1234 -e PGID=1235 -e UMASK=007

  wait_for_qbt "$name" "$host_port" http "$cookie"
  # shellcheck disable=SC2016
  assert_command_succeeds "abc user changed to requested uid/gid" docker exec "$name" sh -c 'test "$(id -u abc)" = 1234 && test "$(id -g abc)" = 1235'
  # shellcheck disable=SC2016
  assert_command_succeeds "qBittorrent runs as abc" docker exec "$name" sh -c 'test "$(ps -o user= -p "$(pgrep qbittorrent-nox)" | xargs)" = abc'
  # shellcheck disable=SC2016
  assert_command_succeeds "qBittorrent process umask applied" docker exec "$name" sh -c 'grep -Eq "^Umask:[[:space:]]+0007$" /proc/$(pgrep qbittorrent-nox)/status'
  # shellcheck disable=SC2016
  assert_command_succeeds "config volume owned by requested identity" docker exec "$name" sh -c 'test "$(stat -c "%u:%g" /config)" = 1234:1235'
  # shellcheck disable=SC2016
  assert_command_succeeds "downloads volume owned by requested identity" docker exec "$name" sh -c 'test "$(stat -c "%u:%g" /downloads)" = 1234:1235'
  record_evidence identity "1234:1235 umask=0007"
}

test_smoke_config_persistence() {
  local name=qbtvpn-smoke-persist
  local host_port=18083
  local config_dir downloads_dir cookie conf
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  conf="${config_dir}/qBittorrent/config/qBittorrent.conf"
  CLEANUP_CONTAINERS+=("$name")
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir" "$cookie")

  start_basic_container "$name" "$host_port" "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" "$host_port" http "$cookie"
  assert_file_contains "first run wrote qBittorrent config" "$conf" 'WebUI\Port=8080'
  assert_file_contains "non-managed qBittorrent preference starts from default" "$conf" 'Session\BTProtocol=Both'

  docker stop "$name" >/dev/null
  assert_command_succeeds "offline edit can persist a non-managed qBittorrent preference" \
    docker run --rm -v "${config_dir}:/config" --entrypoint sh "$IMAGE" \
      -c "sed -i 's/Session\\\\BTProtocol=Both/Session\\\\BTProtocol=TCP/' /config/qBittorrent/config/qBittorrent.conf"
  start_basic_container "$name" "$host_port" "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" "$host_port" http "$cookie"
  assert_file_contains "non-managed qBittorrent preference survives restart" "$conf" 'Session\BTProtocol=TCP'
  assert_file_contains "torrent port remains managed after restart" "$conf" 'Session\Port=8999'
  record_evidence persistence "$conf"
}

SCENARIOS=(
  smoke-http-vpn-disabled
  smoke-https-default
  smoke-uid-gid-umask
  smoke-config-persistence
)

run_one() {
  local selected=$1
  local fn="test_${selected//-/_}"
  declare -F "$fn" >/dev/null || fail "Unknown smoke scenario '${selected}'"
  (
    CLEANUP_CONTAINERS=()
    CLEANUP_PATHS=()
    trap cleanup_smoke EXIT
    begin_scenario "$selected" 5 webui_version
    "$fn"
    end_scenario
  )
}

if [[ "$scenario" == all ]]; then
  for item in "${SCENARIOS[@]}"; do
    run_one "$item"
  done
else
  run_one "$scenario"
fi
