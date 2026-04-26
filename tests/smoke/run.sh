#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../lib/testlib.sh
source "$(dirname "$0")/../lib/testlib.sh"

name=qbtvpn-smoke
host_port=18080
config_dir=$(mktemp -d)
downloads_dir=$(mktemp -d)
cookie=$(mktemp)
trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' EXIT

cleanup_container "$name"

docker run -d --name "$name" \
  -e VPN_ENABLED=no \
  -e ENABLE_SSL=no \
  -e PUID=1000 \
  -e PGID=1000 \
  -e UMASK=002 \
  -p "${host_port}:8080" \
  -v "${config_dir}:/config" \
  -v "${downloads_dir}:/downloads" \
  "$IMAGE" >/dev/null

wait_for_qbt "$name" "$host_port" http "$cookie"

docker exec "$name" pgrep qbittorrent-nox >/dev/null
docker exec "$name" sh -c 'test "$(id -u abc)" = 1000 && test "$(id -g abc)" = 1000'
grep -Fq 'Session\Port=8999' "${config_dir}/qBittorrent/config/qBittorrent.conf"

log INFO "smoke test passed"
