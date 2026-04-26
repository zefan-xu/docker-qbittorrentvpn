#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../lib/testlib.sh
source "$(dirname "$0")/../lib/testlib.sh"

scenario=${1:-all}
ARTIFACT_DIR=${ARTIFACT_DIR:-"${ROOT_DIR}/tests/integration/tmp/artifacts-${scenario}"}
mkdir -p "$TEST_TMP" "$ARTIFACT_DIR"

wait_exit() {
  local name=$1
  local timeout=${2:-45}
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == false ]]; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "${name} did not exit within ${timeout}s"
}

run_basic_container() {
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

test_vpn_disabled_basic() {
  "${ROOT_DIR}/tests/smoke/run.sh"
}

test_uid_gid_umask() {
  local name=qbtvpn-uidgid
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    -e VPN_ENABLED=no \
    -e ENABLE_SSL=no \
    -e PUID=1234 \
    -e PGID=1235 \
    -e UMASK=007 \
    -p 18081:8080 \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_for_qbt "$name" 18081 http "$cookie"
  docker exec "$name" sh -c 'test "$(id -u abc)" = 1234 && test "$(id -g abc)" = 1235'
  docker exec "$name" sh -c 'grep -Eq "^Umask:[[:space:]]+0007$" /proc/$(pgrep qbittorrent-nox)/status'
}

test_first_run_config() {
  local name=qbtvpn-first-run
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18082 "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" 18082 http "$cookie"
  grep -Fq 'Session\Port=8999' "${config_dir}/qBittorrent/config/qBittorrent.conf"
  grep -Fq 'WebUI\Username=admin' "${config_dir}/qBittorrent/config/qBittorrent.conf"
  ! grep -Fq 'WebUI\Password_PBKDF2=' "${config_dir}/qBittorrent/config/qBittorrent.conf"
}

test_existing_config_preserved() {
  local name=qbtvpn-existing-config
  local config_dir downloads_dir cookie conf
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  conf="${config_dir}/qBittorrent/config/qBittorrent.conf"
  mkdir -p "$(dirname "$conf")"
  printf '[Preferences]\nCustom\\Sentinel=true\nWebUI\\Port=8080\n' > "$conf"
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18083 "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" 18083 http "$cookie"
  grep -Fq 'Custom\Sentinel=true' "$conf"
}

test_enable_ssl_on() {
  local name=qbtvpn-ssl-on
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18084 "$config_dir" "$downloads_dir" -e ENABLE_SSL=yes
  wait_for_qbt "$name" 18084 https "$cookie"
  test -f "${config_dir}/qBittorrent/config/WebUICertificate.crt"
  test -f "${config_dir}/qBittorrent/config/WebUIKey.key"
  grep -Fq 'WebUI\HTTPS\Enabled=true' "${config_dir}/qBittorrent/config/qBittorrent.conf"
}

test_enable_ssl_off() {
  local name=qbtvpn-ssl-off
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18085 "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" 18085 http "$cookie"
  ! grep -Fq 'WebUI\HTTPS\Enabled=true' "${config_dir}/qBittorrent/config/qBittorrent.conf"
}

start_openvpn_fixture() {
  local proto=$1
  local net=$2
  local server_dir=$3
  local client_dir=$4
  mkdir -p "$server_dir" "${client_dir}/openvpn"
  docker run --rm --entrypoint openvpn -v "${server_dir}:/out" "$IMAGE" --genkey secret /out/static.key
  cp "${server_dir}/static.key" "${client_dir}/openvpn/static.key"

  local server_proto=udp
  local client_proto=udp
  if [[ "$proto" == tcp ]]; then
    server_proto=tcp-server
    client_proto=tcp-client
  fi

  cat > "${server_dir}/server.conf" <<EOF
dev tun
ifconfig 10.8.0.1 10.8.0.2
secret /server/static.key
proto ${server_proto}
port 1194
keepalive 10 60
verb 3
EOF

  cat > "${client_dir}/openvpn/client.ovpn" <<EOF
dev tun
ifconfig 10.8.0.2 10.8.0.1
secret static.key
remote vpn-server 1194 ${client_proto}
proto ${client_proto}
redirect-gateway def1
verb 3
EOF

  docker network create "$net" >/dev/null
  docker run -d --name vpn-server --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    -v "${server_dir}:/server" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE; exec openvpn --config /server/server.conf' >/dev/null
}

run_openvpn_case() {
  local proto=$1
  local extra_name=${2:-basic}
  ensure_tun
  local net="qbtvpn-ovpn-${proto}-${RANDOM}"
  local name="qbtvpn-ovpn-${proto}-${extra_name}"
  local base_dir server_dir client_dir downloads_dir cookie subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir" "$cookie"' RETURN

  start_openvpn_fixture "$proto" "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")

  if [[ "$extra_name" == credentials ]]; then
    printf 'auth-user-pass\n' >> "${client_dir}/openvpn/client.ovpn"
  fi

  cleanup_container "$name"
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes \
    -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -e HEALTH_CHECK_INTERVAL=10 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=no \
    -e VPN_USERNAME=user1 \
    -e VPN_PASSWORD=pass1 \
    -p 18086:8080 \
    -v "${client_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null

  wait_for_qbt "$name" 18086 http "$cookie"
  docker exec "$name" ip -4 addr show tun0 | grep -q 'inet '
  docker exec "$name" iptables -S OUTPUT | head -n 1 | grep -q '^-P OUTPUT DROP'
  docker exec "$name" ip6tables -S OUTPUT | head -n 1 | grep -q '^-P OUTPUT DROP'
  docker exec "$name" timeout 20 curl -fsS http://1.1.1.1 >/dev/null

  if [[ "$extra_name" == credentials ]]; then
    docker exec "$name" test -f /run/qbtvpn/openvpn-credentials.conf
    docker exec "$name" grep -Fq 'auth-user-pass /run/qbtvpn/openvpn-credentials.conf' /run/qbtvpn/client.ovpn
  fi
}

test_openvpn_udp_basic() {
  run_openvpn_case udp basic
}

test_openvpn_tcp_basic() {
  run_openvpn_case tcp basic
}

test_openvpn_credentials() {
  run_openvpn_case udp credentials
}

test_openvpn_options() {
  ensure_tun
  local net="qbtvpn-ovpn-options-${RANDOM}"
  local name=qbtvpn-ovpn-options
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_openvpn_fixture udp "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes \
    -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -e VPN_OPTIONS='--ping 10' \
    -v "${client_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  retry 60 1 docker exec "$name" pgrep openvpn >/dev/null
  docker exec "$name" sh -c 'tr "\0" " " < /proc/$(pgrep openvpn)/cmdline' | grep -Fq -- '--ping 10'
}

start_wireguard_fixture() {
  local net=$1
  local server_dir=$2
  local client_dir=$3
  mkdir -p "$server_dir" "${client_dir}/wireguard"
  docker run --rm --entrypoint bash "$IMAGE" -c 'wg genkey' > "${server_dir}/server.key"
  docker run --rm --entrypoint bash "$IMAGE" -c 'wg genkey' > "${client_dir}/client.key"
  docker run --rm --entrypoint bash -v "${server_dir}:/keys" "$IMAGE" -c 'wg pubkey < /keys/server.key' > "${server_dir}/server.pub"
  docker run --rm --entrypoint bash -v "${client_dir}:/keys" "$IMAGE" -c 'wg pubkey < /keys/client.key' > "${client_dir}/client.pub"
  local server_private client_private server_public client_public
  server_private=$(cat "${server_dir}/server.key")
  client_private=$(cat "${client_dir}/client.key")
  server_public=$(cat "${server_dir}/server.pub")
  client_public=$(cat "${client_dir}/client.pub")

  cat > "${client_dir}/wireguard/wg0.conf" <<EOF
[Interface]
PrivateKey = ${client_private}
Address = 10.9.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_public}
Endpoint = wg-server:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF

  docker network create "$net" >/dev/null
  docker run -d --name wg-server --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --entrypoint bash \
    "$IMAGE" \
    -c "ip link add wg0 type wireguard; ip addr add 10.9.0.1/24 dev wg0; wg set wg0 private-key <(printf '%s\n' '${server_private}') listen-port 51820 peer '${client_public}' allowed-ips 10.9.0.2/32; ip link set wg0 up; iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE; sleep infinity" >/dev/null
}

test_wireguard_basic() {
  ensure_tun
  local net="qbtvpn-wg-${RANDOM}"
  local name=qbtvpn-wireguard
  local base_dir server_dir client_dir downloads_dir cookie subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" wg-server; cleanup_container "$name" wg-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir" "$cookie"' RETURN
  start_wireguard_fixture "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes \
    -e VPN_TYPE=wireguard \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -e RESTART_CONTAINER=no \
    -p 18087:8080 \
    -v "${client_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_for_qbt "$name" 18087 http "$cookie"
  docker exec "$name" ip -4 addr show wg0 | grep -q 'inet '
  docker exec "$name" timeout 20 curl -fsS http://1.1.1.1 >/dev/null
}

test_wireguard_wrong_filename() {
  local name=qbtvpn-wg-wrong
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  mkdir -p "${config_dir}/wireguard"
  printf '[Interface]\nPrivateKey = x\n' > "${config_dir}/wireguard/not-wg0.conf"
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -e VPN_ENABLED=yes \
    -e VPN_TYPE=wireguard \
    -e LAN_NETWORK=172.16.0.0/16 \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_exit "$name"
  assert_container_exited_nonzero "$name"
  docker logs "$name" | grep -Fq 'WireGuard config must be named'
}

validation_case() {
  local test_name=$1
  local expected=$2
  shift 2
  local name="qbtvpn-${test_name}"
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    "$@" \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_exit "$name"
  assert_container_exited_nonzero "$name"
  docker logs "$name" | grep -Fq "$expected"
}

test_missing_vpn_config() {
  validation_case missing-vpn-config 'No OpenVPN .ovpn file found' \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -e LAN_NETWORK=172.16.0.0/16
}

test_invalid_vpn_type() {
  validation_case invalid-vpn-type 'VPN_TYPE must be openvpn or wireguard' \
    -e VPN_ENABLED=yes -e VPN_TYPE=bogus -e LAN_NETWORK=172.16.0.0/16
}

test_missing_lan_network() {
  local name=qbtvpn-missing-lan
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  mkdir -p "${config_dir}/openvpn"
  printf 'remote vpn.example 1194 udp\ndev tun\n' > "${config_dir}/openvpn/client.ovpn"
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_exit "$name"
  assert_container_exited_nonzero "$name"
  docker logs "$name" | grep -Fq 'LAN_NETWORK is required'
}

test_invalid_lan_network() {
  local name=qbtvpn-invalid-lan
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  mkdir -p "${config_dir}/openvpn"
  printf 'remote vpn.example 1194 udp\ndev tun\n' > "${config_dir}/openvpn/client.ovpn"
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -e LAN_NETWORK=not-a-cidr \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  wait_exit "$name"
  assert_container_exited_nonzero "$name"
  docker logs "$name" | grep -Fq 'LAN_NETWORK contains invalid IPv4 CIDR'
}

test_multiple_lan_networks() {
  ensure_tun
  local net="qbtvpn-multi-lan-${RANDOM}"
  local name=qbtvpn-multi-lan
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_openvpn_fixture udp "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="${subnet},192.168.50.0/24,10.10.0.0/16" \
    -e ENABLE_SSL=no \
    -v "${client_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  retry 90 1 docker exec "$name" ip -4 addr show tun0 >/dev/null
  docker exec "$name" ip route | grep -Fq '192.168.50.0/24'
  docker exec "$name" ip route | grep -Fq '10.10.0.0/16'
}

test_additional_ports() {
  ensure_tun
  local net="qbtvpn-additional-${RANDOM}"
  local name=qbtvpn-additional
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_openvpn_fixture udp "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="$subnet" \
    -e ADDITIONAL_PORTS=8112,9696 \
    -e ENABLE_SSL=no \
    -v "${client_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  retry 90 1 docker exec "$name" iptables -S INPUT >/tmp/qbtvpn-iptables
  docker exec "$name" iptables -S INPUT | grep -Fq -- '--dport 8112'
  docker exec "$name" iptables -S INPUT | grep -Fq -- '--dport 9696'
}

test_name_servers() {
  local name=qbtvpn-nameservers
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18088 "$config_dir" "$downloads_dir" -e ENABLE_SSL=no -e NAME_SERVERS=9.9.9.9,1.1.1.1
  wait_for_qbt "$name" 18088 http "$cookie"
  docker exec "$name" grep -Fq 'nameserver 9.9.9.9' /etc/resolv.conf
}

test_kill_switch_openvpn() {
  ensure_tun
  local net="qbtvpn-kill-ovpn-${RANDOM}"
  local name=qbtvpn-kill-openvpn
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_openvpn_fixture udp "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -e RESTART_CONTAINER=no \
    -v "${client_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  retry 90 1 docker exec "$name" timeout 20 curl -fsS http://1.1.1.1 >/dev/null
  docker rm -f vpn-server >/dev/null
  docker exec "$name" pkill openvpn || true
  sleep 5
  if docker exec "$name" timeout 5 curl -fsS http://1.1.1.1 >/dev/null 2>&1; then
    fail "clear-net egress succeeded after OpenVPN was killed"
  fi
  docker exec "$name" iptables -S OUTPUT | head -n 1 | grep -q '^-P OUTPUT DROP'
}

test_kill_switch_wireguard() {
  ensure_tun
  local net="qbtvpn-kill-wg-${RANDOM}"
  local name=qbtvpn-kill-wireguard
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" wg-server; cleanup_container "$name" wg-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_wireguard_fixture "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=wireguard \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -e RESTART_CONTAINER=no \
    -v "${client_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  retry 90 1 docker exec "$name" timeout 20 curl -fsS http://1.1.1.1 >/dev/null
  docker rm -f wg-server >/dev/null
  docker exec "$name" wg-quick down /run/qbtvpn/wg0.conf || true
  sleep 5
  if docker exec "$name" timeout 5 curl -fsS http://1.1.1.1 >/dev/null 2>&1; then
    fail "clear-net egress succeeded after WireGuard was brought down"
  fi
}

test_ipv6_blocked() {
  ensure_tun
  local net="qbtvpn-ipv6-${RANDOM}"
  local name=qbtvpn-ipv6
  local base_dir server_dir client_dir downloads_dir subnet
  base_dir=$(mktemp -d)
  server_dir="${base_dir}/server"
  client_dir="${base_dir}/client"
  downloads_dir="${base_dir}/downloads"
  trap 'collect_container_logs "$ARTIFACT_DIR" "$name" vpn-server; cleanup_container "$name" vpn-server; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$base_dir"' RETURN
  start_openvpn_fixture udp "$net" "$server_dir" "$client_dir"
  subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$net")
  docker run -d --name "$name" --network "$net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="$subnet" \
    -e ENABLE_SSL=no \
    -v "${client_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  retry 90 1 docker exec "$name" ip6tables -S OUTPUT >/dev/null
  docker exec "$name" ip6tables -S OUTPUT | head -n 1 | grep -q '^-P OUTPUT DROP'
  ! docker exec "$name" timeout 5 curl -g -6 -fsS 'http://[2606:4700:4700::1111]' >/dev/null 2>&1
}

test_healthcheck_restart_yes() {
  local name=qbtvpn-health-yes
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir"' RETURN
  cleanup_container "$name"
  docker run -d --name "$name" \
    -e VPN_ENABLED=no \
    -e ENABLE_SSL=no \
    -e HEALTH_CHECK_HOST=192.0.2.1 \
    -e HEALTH_CHECK_INTERVAL=1 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=yes \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  wait_exit "$name" 30
  assert_container_exited_nonzero "$name"
}

test_healthcheck_restart_no() {
  local name=qbtvpn-health-no
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  docker run -d --name "$name" \
    -e VPN_ENABLED=no \
    -e ENABLE_SSL=no \
    -e HEALTH_CHECK_HOST=192.0.2.1 \
    -e HEALTH_CHECK_INTERVAL=1 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=no \
    -p 18089:8080 \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  wait_for_qbt "$name" 18089 http "$cookie"
  sleep 3
  docker exec "$name" pgrep qbittorrent-nox >/dev/null
}

test_torrent_port_exposed() {
  local name=qbtvpn-torrent-port
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  docker run -d --name "$name" \
    -e VPN_ENABLED=no \
    -e ENABLE_SSL=no \
    -p 18090:8080 \
    -p 18999:8999 \
    -p 18999:8999/udp \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  wait_for_qbt "$name" 18090 http "$cookie"
  docker port "$name" 8999/tcp | grep -q '18999'
  docker port "$name" 8999/udp | grep -q '18999'
}

test_graceful_stop() {
  local name=qbtvpn-graceful
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  trap 'cleanup_container "$name"; rm -rf "$config_dir" "$downloads_dir" "$cookie"' RETURN
  run_basic_container "$name" 18091 "$config_dir" "$downloads_dir" -e ENABLE_SSL=no
  wait_for_qbt "$name" 18091 http "$cookie"
  docker stop -t 20 "$name" >/dev/null
  [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == false ]]
}

test_compose_example() {
  docker compose -f "${ROOT_DIR}/docker-compose.yml" config -q
}

SCENARIOS=(
  vpn-disabled-basic
  uid-gid-umask
  first-run-config
  existing-config-preserved
  enable-ssl-on
  enable-ssl-off
  openvpn-udp-basic
  openvpn-tcp-basic
  openvpn-credentials
  openvpn-options
  wireguard-basic
  wireguard-wrong-filename
  missing-vpn-config
  invalid-vpn-type
  missing-lan-network
  invalid-lan-network
  multiple-lan-networks
  additional-ports
  name-servers
  kill-switch-openvpn
  kill-switch-wireguard
  ipv6-blocked
  healthcheck-restart-yes
  healthcheck-restart-no
  torrent-port-exposed
  graceful-stop
  compose-example
)

run_one() {
  local selected=$1
  local fn="test_${selected//-/_}"
  declare -F "$fn" >/dev/null || fail "Unknown integration scenario '${selected}'"
  log INFO "Running scenario ${selected}"
  ( "$fn" )
  log INFO "Scenario ${selected} passed"
}

if [[ "$scenario" == all ]]; then
  for item in "${SCENARIOS[@]}"; do
    run_one "$item"
  done
else
  run_one "$scenario"
fi
