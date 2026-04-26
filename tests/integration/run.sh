#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../lib/testlib.sh
source "$(dirname "$0")/../lib/testlib.sh"

scenario=${1:-all}
ARTIFACT_DIR=${ARTIFACT_DIR:-"${ROOT_DIR}/tests/integration/tmp/artifacts-${scenario}"}
mkdir -p "$TEST_TMP" "$ARTIFACT_DIR"

CLEANUP_CONTAINERS=()
CLEANUP_NETWORKS=()
CLEANUP_PATHS=()
LOG_CONTAINERS=()

cleanup_scenario() {
  local status=$?
  set +e
  if (( ${#LOG_CONTAINERS[@]} > 0 )); then
    collect_container_logs "$ARTIFACT_DIR" "${LOG_CONTAINERS[@]}"
  fi
  if (( ${#CLEANUP_CONTAINERS[@]} > 0 )); then
    cleanup_container "${CLEANUP_CONTAINERS[@]}"
  fi
  local net
  for net in "${CLEANUP_NETWORKS[@]}"; do
    docker network rm "$net" >/dev/null 2>&1 || true
  done
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    cleanup_paths "${CLEANUP_PATHS[@]}"
  fi
  return "$status"
}

docker_network_subnet() {
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$1"
}

docker_network_ip() {
  local container=$1
  local network=$2
  docker inspect -f "{{with index .NetworkSettings.Networks \"${network}\"}}{{.IPAddress}}{{end}}" "$container"
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

start_probe() {
  local internet_net=$1
  local log_dir=$2
  mkdir -p "$log_dir"
  cleanup_container probe
  docker run -d --name probe --network "$internet_net" \
    -v "${log_dir}:/logs" \
    "$PROBE_IMAGE" >/dev/null
  LOG_CONTAINERS+=("probe")
  CLEANUP_CONTAINERS+=("probe")
  sleep 1
  PROBE_IP=$(docker_network_ip probe "$internet_net")
  record_evidence probe_ip "$PROBE_IP"
}

start_torrent_lab() {
  local internet_net=$1
  local data_dir=$2
  local log_dir=$3
  local throttle=${4:-0}
  mkdir -p "$data_dir" "$log_dir"
  cleanup_container torrent-lab
  docker run -d --name torrent-lab --network "$internet_net" \
    -e THROTTLE_BPS="$throttle" \
    -v "${data_dir}:/data" \
    -v "${log_dir}:/logs" \
    "$TORRENT_LAB_IMAGE" >/dev/null
  LOG_CONTAINERS+=("torrent-lab")
  CLEANUP_CONTAINERS+=("torrent-lab")
  sleep 1
  TORRENT_LAB_IP=$(docker_network_ip torrent-lab "$internet_net")
  record_evidence torrent_lab_ip "$TORRENT_LAB_IP"
}

start_openvpn_fixture() {
  local proto=$1
  local lan_net=$2
  local server_dir=$3
  local client_dir=$4
  mkdir -p "$server_dir" "${client_dir}/openvpn"
  docker run --rm --entrypoint openvpn -v "${server_dir}:/out" "$IMAGE" --genkey secret /out/static.key
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$(id -u):$(id -g)" "$server_dir"
  else
    chown -R "$(id -u):$(id -g)" "$server_dir"
  fi
  cp "${server_dir}/static.key" "${client_dir}/openvpn/static.key"

  local server_proto=udp
  local client_proto=udp
  if [[ "$proto" == tcp ]]; then
    server_proto=tcp-server
    client_proto=tcp-client
  fi

  tee "${server_dir}/server.conf" >/dev/null <<EOF
dev tun
ifconfig 10.8.0.1 10.8.0.2
secret /server/static.key
allow-deprecated-insecure-static-crypto
cipher AES-256-CBC
proto ${server_proto}
port 1194
keepalive 10 60
verb 3
EOF

  tee "${client_dir}/openvpn/client.ovpn" >/dev/null <<EOF
dev tun
ifconfig 10.8.0.2 10.8.0.1
secret static.key
allow-deprecated-insecure-static-crypto
cipher AES-256-CBC
remote vpn-server 1194 ${client_proto}
proto ${client_proto}
redirect-gateway def1
verb 3
EOF

  cleanup_container vpn-server
  docker run -d --name vpn-server --network "$lan_net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    -v "${server_dir}:/server" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE; exec openvpn --config /server/server.conf' >/dev/null
  LOG_CONTAINERS+=("vpn-server")
  CLEANUP_CONTAINERS+=("vpn-server")
}

generate_openvpn_auth_pki() {
  local out_dir=$1
  mkdir -p "$out_dir"
  openssl genrsa -out "${out_dir}/ca.key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "${out_dir}/ca.key" -sha256 -days 2 \
    -out "${out_dir}/ca.crt" -subj "/CN=qbtvpn-test-ca" >/dev/null 2>&1
  openssl genrsa -out "${out_dir}/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "${out_dir}/server.key" -out "${out_dir}/server.csr" \
    -subj "/CN=vpn-auth-server" >/dev/null 2>&1
  tee "${out_dir}/server.ext" >/dev/null <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:vpn-auth-server
EOF
  openssl x509 -req -in "${out_dir}/server.csr" \
    -CA "${out_dir}/ca.crt" -CAkey "${out_dir}/ca.key" -CAcreateserial \
    -out "${out_dir}/server.crt" -days 2 -sha256 -extfile "${out_dir}/server.ext" >/dev/null 2>&1
}

start_openvpn_auth_fixture() {
  local lan_net=$1
  local server_dir=$2
  local client_dir=$3
  mkdir -p "$server_dir" "${client_dir}/openvpn"
  generate_openvpn_auth_pki "$server_dir"
  cp "${server_dir}/ca.crt" "${client_dir}/openvpn/ca.crt"

  tee "${server_dir}/auth.sh" >/dev/null <<'EOF'
#!/usr/bin/env sh
set -eu
user=$(sed -n '1p' "$1")
pass=$(sed -n '2p' "$1")
if [ "$user" = user1 ] && [ "$pass" = pass1 ]; then
  printf 'auth_success user=%s\n' "$user" >> /server/auth.log
  exit 0
fi
printf 'auth_failure user=%s\n' "$user" >> /server/auth.log
exit 1
EOF
  chmod +x "${server_dir}/auth.sh"
  : > "${server_dir}/auth.log"

  tee "${server_dir}/server.conf" >/dev/null <<'EOF'
port 1194
proto udp
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ca /server/ca.crt
cert /server/server.crt
key /server/server.key
dh none
ecdh-curve prime256v1
verify-client-cert none
username-as-common-name
script-security 3
auth-user-pass-verify /server/auth.sh via-file
push "redirect-gateway def1"
keepalive 10 60
verb 3
EOF

  tee "${client_dir}/openvpn/client.ovpn" >/dev/null <<'EOF'
client
dev tun
proto udp
remote vpn-auth-server 1194 udp
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
auth-nocache
ca ca.crt
redirect-gateway def1
verb 3
EOF

  cleanup_container vpn-auth-server
  docker run -d --name vpn-auth-server --network "$lan_net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    -v "${server_dir}:/server" \
    --entrypoint bash \
    "$IMAGE" \
    -c 'iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE; exec openvpn --config /server/server.conf' >/dev/null
  LOG_CONTAINERS+=("vpn-auth-server")
  CLEANUP_CONTAINERS+=("vpn-auth-server")
}

start_wireguard_fixture() {
  local lan_net=$1
  local server_dir=$2
  local client_dir=$3
  mkdir -p "$server_dir" "${client_dir}/wireguard"
  docker run --rm --entrypoint bash "$IMAGE" -c 'wg genkey' > "${server_dir}/server.key"
  docker run --rm --entrypoint bash "$IMAGE" -c 'wg genkey' > "${client_dir}/client.key"
  docker run --rm --entrypoint bash -v "${server_dir}:/keys" "$IMAGE" -c 'wg pubkey < /keys/server.key' > "${server_dir}/server.pub"
  docker run --rm --entrypoint bash -v "${client_dir}:/keys" "$IMAGE" -c 'wg pubkey < /keys/client.key' > "${client_dir}/client.pub"
  local server_private client_private server_public client_public
  server_private=$(<"${server_dir}/server.key")
  client_private=$(<"${client_dir}/client.key")
  server_public=$(<"${server_dir}/server.pub")
  client_public=$(<"${client_dir}/client.pub")

  tee "${client_dir}/wireguard/wg0.conf" >/dev/null <<EOF
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

  cleanup_container wg-server
  docker run -d --name wg-server --network "$lan_net" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --entrypoint bash \
    "$IMAGE" \
    -c "ip link add wg0 type wireguard; ip addr add 10.9.0.1/24 dev wg0; wg set wg0 private-key <(printf '%s\n' '${server_private}') listen-port 51820 peer '${client_public}' allowed-ips 10.9.0.2/32; ip link set wg0 up; iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE; sleep infinity" >/dev/null
  LOG_CONTAINERS+=("wg-server")
  CLEANUP_CONTAINERS+=("wg-server")
}

setup_dual_networks() {
  local prefix=$1
  LAB_LAN_NET="${prefix}-lan-${RANDOM}"
  LAB_INET_NET="${prefix}-inet-${RANDOM}"
  docker network create "$LAB_LAN_NET" >/dev/null
  docker network create "$LAB_INET_NET" >/dev/null
  CLEANUP_NETWORKS+=("$LAB_LAN_NET" "$LAB_INET_NET")
  LAB_LAN_SUBNET=$(docker_network_subnet "$LAB_LAN_NET")
  record_evidence lan_network "$LAB_LAN_SUBNET"
}

connect_vpn_server_to_internet() {
  local server=$1
  docker network connect "$LAB_INET_NET" "$server"
  VPN_SERVER_INET_IP=$(docker_network_ip "$server" "$LAB_INET_NET")
  record_evidence vpn_server_internet_ip "$VPN_SERVER_INET_IP"
}

run_qbt_vpn_container() {
  local name=$1
  local host_port=$2
  local vpn_type=$3
  local config_dir=$4
  local downloads_dir=$5
  shift 5
  cleanup_container "$name"
  docker run -d --name "$name" --network "$LAB_LAN_NET" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes \
    -e VPN_TYPE="$vpn_type" \
    -e LAN_NETWORK="$LAB_LAN_SUBNET" \
    -e NAME_SERVERS="$PROBE_IP" \
    -e ENABLE_SSL=no \
    -e HEALTH_CHECK_INTERVAL=10 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=no \
    "$@" \
    -p "${host_port}:8080" \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
}

assert_probe_saw_vpn_source() {
  local request_id=$1
  assert_docker_logs_contains "probe logged request ${request_id}" probe "\"request_id\": \"${request_id}\""
  assert_docker_logs_contains "probe saw VPN server source for ${request_id}" probe "\"client_ip\": \"${VPN_SERVER_INET_IP}\""
}

reset_probe_logs() {
  check_start "reset probe logs"
  docker exec probe sh -c ': > /logs/probe.log'
  record_pass "reset probe logs" "probe.log truncated"
}

assert_common_vpn_ready() {
  local name=$1
  local host_port=$2
  local cookie=$3
  local device=$4
  wait_for_qbt "$name" "$host_port" http "$cookie"
  assert_container_output_contains "${device} has IPv4 address" "$name" 'inet ' ip -4 addr show "$device"
  assert_iptables_policy "IPv4 OUTPUT policy fail-closed" "$name" iptables OUTPUT DROP
  assert_iptables_policy "IPv6 OUTPUT policy fail-closed" "$name" ip6tables OUTPUT DROP
  local request_id="${SCENARIO_NAME}-${RANDOM}"
  assert_vpn_egress "probe HTTP egress works through VPN" "$name" "http://${PROBE_IP}:8080/echo?request_id=${request_id}"
  assert_probe_saw_vpn_source "$request_id"
  assert_command_output_contains "DNS query resolved by VPN nameserver" "$PROBE_IP" docker exec "$name" dig +short probe.test
  assert_docker_logs_contains "probe logged DNS query" probe '"type": "dns"'
}

setup_openvpn_lab() {
  local proto=$1
  local base_dir=$2
  setup_dual_networks "qbtvpn-ovpn-${proto}"
  start_openvpn_fixture "$proto" "$LAB_LAN_NET" "${base_dir}/server" "${base_dir}/client"
  connect_vpn_server_to_internet vpn-server
  start_probe "$LAB_INET_NET" "${base_dir}/probe-logs"
}

setup_openvpn_auth_lab() {
  local base_dir=$1
  setup_dual_networks "qbtvpn-ovpn-auth"
  start_openvpn_auth_fixture "$LAB_LAN_NET" "${base_dir}/server" "${base_dir}/client"
  connect_vpn_server_to_internet vpn-auth-server
  start_probe "$LAB_INET_NET" "${base_dir}/probe-logs"
}

setup_wireguard_lab() {
  local base_dir=$1
  setup_dual_networks "qbtvpn-wg"
  start_wireguard_fixture "$LAB_LAN_NET" "${base_dir}/server" "${base_dir}/client"
  connect_vpn_server_to_internet wg-server
  start_probe "$LAB_INET_NET" "${base_dir}/probe-logs"
}

run_openvpn_full_case() {
  local proto=$1
  local extra=${2:-}
  local name="qbtvpn-ovpn-${proto}-${extra:-full}"
  local host_port=18100
  local base_dir downloads_dir cookie
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab "$proto" "$base_dir"
  local -a env_args=()
  if [[ "$extra" == auth ]]; then
    printf 'auth-user-pass\n' >> "${base_dir}/client/openvpn/client.ovpn"
    env_args=(-e VPN_USERNAME=user1 -e VPN_PASSWORD=pass1)
  elif [[ "$extra" == options ]]; then
    env_args=(-e VPN_OPTIONS='--ping 10')
  fi
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir" "${env_args[@]}"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  if [[ "$extra" == auth ]]; then
    assert_container_output_contains "OpenVPN credentials file exists" "$name" 'user1' sh -c 'sed -n 1p /run/qbtvpn/openvpn-credentials.conf'
    assert_container_output_contains "runtime OpenVPN config points to credentials file" "$name" 'auth-user-pass /run/qbtvpn/openvpn-credentials.conf' grep -F 'auth-user-pass' /run/qbtvpn/client.ovpn
    assert_docker_logs_not_contains "VPN password is not logged" "$name" 'pass1'
  elif [[ "$extra" == options ]]; then
    assert_container_output_contains "OpenVPN custom option appears in argv" "$name" '--ping 10' sh -c "xargs -0 printf '%s ' < /proc/\$(pgrep openvpn)/cmdline"
  fi
}

test_openvpn_udp_full() {
  run_openvpn_full_case udp
}

test_openvpn_tcp_full() {
  run_openvpn_full_case tcp
}

test_openvpn_auth_success() {
  local name=qbtvpn-openvpn-auth-success
  local host_port=18115
  local base_dir downloads_dir cookie
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_auth_lab "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir" \
    -e VPN_USERNAME=user1 -e VPN_PASSWORD=pass1
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  assert_container_output_contains "OpenVPN credentials file contains username" "$name" 'user1' sh -c 'sed -n 1p /run/qbtvpn/openvpn-credentials.conf'
  assert_container_output_contains "runtime OpenVPN config points to credentials file" "$name" 'auth-user-pass /run/qbtvpn/openvpn-credentials.conf' grep -F 'auth-user-pass' /run/qbtvpn/client.ovpn
  assert_container_output_contains "OpenVPN server accepted credentials" vpn-auth-server 'auth_success user=user1' cat /server/auth.log
  assert_docker_logs_not_contains "VPN password is not logged" "$name" 'pass1'
}

test_openvpn_options_full() {
  run_openvpn_full_case udp options
}

test_openvpn_auth_failure() {
  local name=qbtvpn-openvpn-auth-fail
  local base_dir downloads_dir
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir")
  setup_openvpn_auth_lab "$base_dir"
  cleanup_container "$name"
  docker run -d --name "$name" --network "$LAB_LAN_NET" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -e LAN_NETWORK="$LAB_LAN_SUBNET" \
    -e NAME_SERVERS="$PROBE_IP" -e VPN_WAIT_TIMEOUT=20 \
    -e VPN_USERNAME=user1 -e VPN_PASSWORD=wrong-pass \
    -v "${base_dir}/client:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  wait_exit "$name" 45
  assert_container_exited_nonzero "bad OpenVPN credentials exit nonzero" "$name"
  assert_container_output_contains "OpenVPN server rejected credentials" vpn-auth-server 'auth_failure user=user1' cat /server/auth.log
  assert_docker_logs_contains "OpenVPN client received AUTH_FAILED" "$name" 'AUTH_FAILED'
  assert_docker_logs_not_contains "qBittorrent never starts on VPN auth failure" "$name" 'Starting qBittorrent'
}

test_wireguard_full() {
  local name=qbtvpn-wireguard-full
  local host_port=18101
  local base_dir downloads_dir cookie
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_wireguard_lab "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" wireguard "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" wg0
  assert_container_output_contains "WireGuard handshake data is present" "$name" 'peer:' wg show
}

test_kill_switch_openvpn() {
  local name=qbtvpn-kill-openvpn
  local host_port=18102
  local base_dir downloads_dir cookie request_id before after
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab udp "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  before=$(docker logs probe 2>&1 | wc -l | tr -d ' ')
  docker rm -f vpn-server >/dev/null
  docker exec "$name" pkill openvpn || true
  sleep 5
  request_id="${SCENARIO_NAME}-blocked-${RANDOM}"
  assert_no_clear_egress "OpenVPN kill switch blocks probe egress" "$name" "http://${PROBE_IP}:8080/echo?request_id=${request_id}"
  after=$(docker logs probe 2>&1 | wc -l | tr -d ' ')
  assert_eq "probe request count does not increase after OpenVPN kill" "$before" "$after"
  assert_iptables_policy "IPv4 OUTPUT remains DROP after OpenVPN kill" "$name" iptables OUTPUT DROP
}

test_kill_switch_wireguard() {
  local name=qbtvpn-kill-wireguard
  local host_port=18103
  local base_dir downloads_dir cookie request_id before after
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_wireguard_lab "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" wireguard "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" wg0
  before=$(docker logs probe 2>&1 | wc -l | tr -d ' ')
  docker rm -f wg-server >/dev/null
  docker exec "$name" wg-quick down /run/qbtvpn/wg0.conf || true
  sleep 5
  request_id="${SCENARIO_NAME}-blocked-${RANDOM}"
  assert_no_clear_egress "WireGuard kill switch blocks probe egress" "$name" "http://${PROBE_IP}:8080/echo?request_id=${request_id}"
  after=$(docker logs probe 2>&1 | wc -l | tr -d ' ')
  assert_eq "probe request count does not increase after WireGuard down" "$before" "$after"
  assert_iptables_policy "IPv4 OUTPUT remains DROP after WireGuard down" "$name" iptables OUTPUT DROP
}

test_dns_through_vpn_no_leak() {
  local name=qbtvpn-dns-vpn
  local host_port=18104
  local base_dir downloads_dir cookie dns_before dns_after
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab udp "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  assert_command_output_contains "DNS resolver returns probe IP" "$PROBE_IP" docker exec "$name" getent ahostsv4 probe.test
  assert_docker_logs_contains "probe saw successful DNS through VPN source" probe "\"client_ip\": \"${VPN_SERVER_INET_IP}\""
  reset_probe_logs
  dns_before=$(docker logs probe 2>&1 | grep -c '"type": "dns"' || true)
  docker rm -f vpn-server >/dev/null
  docker exec "$name" pkill openvpn || true
  sleep 5
  assert_command_fails "DNS query fails after VPN teardown" docker exec "$name" timeout 8 getent ahostsv4 probe.test
  dns_after=$(docker logs probe 2>&1 | grep -c '"type": "dns"' || true)
  assert_eq "DNS probe count does not increase after VPN teardown" "$dns_before" "$dns_after"
}

qbt_add_torrent() {
  local base=$1
  local cookie=$2
  local torrent_file=$3
  local save_path=$4
  check_start "add torrent $(basename "$torrent_file")"
  qbt_api_post "$base" "$cookie" /api/v2/torrents/add \
    -F "torrents=@${torrent_file}" \
    -F "savepath=${save_path}" \
    -F paused=false >/dev/null
  record_pass "add torrent $(basename "$torrent_file")" "savepath=${save_path}"
}

qbt_add_seed_torrent() {
  local base=$1
  local cookie=$2
  local torrent_file=$3
  local save_path=$4
  check_start "add seed torrent $(basename "$torrent_file")"
  qbt_api_post "$base" "$cookie" /api/v2/torrents/add \
    -F "torrents=@${torrent_file}" \
    -F "savepath=${save_path}" \
    -F paused=false \
    -F skip_checking=true >/dev/null
  record_pass "add seed torrent $(basename "$torrent_file")" "savepath=${save_path}"
}

qbt_torrent_action() {
  local name=$1
  local base=$2
  local cookie=$3
  local action=$4
  local hash=$5
  check_start "$name"
  qbt_api_post "$base" "$cookie" "/api/v2/torrents/${action}" \
    --data-urlencode "hashes=${hash}" >/dev/null
  record_pass "$name" "${action} ${hash}"
}

qbt_torrent_info() {
  local base=$1
  local cookie=$2
  local hash=$3
  qbt_api_get "$base" "$cookie" "/api/v2/torrents/info?hashes=${hash}"
}

qbt_torrent_field() {
  local json=$1
  local field=$2
  JSON_INPUT=$json python3 - "$field" <<'PY'
import json
import os
import sys
data = json.loads(os.environ["JSON_INPUT"])
field = sys.argv[1]
if not data:
    print("")
else:
    print(data[0].get(field, ""))
PY
}

wait_torrent_complete() {
  local base=$1
  local cookie=$2
  local hash=$3
  local timeout=${4:-240}
  local deadline=$((SECONDS + timeout))
  local info progress state
  check_start "torrent ${hash} reaches 100 percent"
  while (( SECONDS < deadline )); do
    info=$(qbt_torrent_info "$base" "$cookie" "$hash")
    progress=$(qbt_torrent_field "$info" progress)
    state=$(qbt_torrent_field "$info" state)
    if python3 - "$progress" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1] or 0) >= 1.0 else 1)
PY
    then
      record_evidence torrent_complete "$hash"
      record_pass "torrent ${hash} reaches 100 percent" "state=${state} progress=${progress}"
      return 0
    fi
    sleep 2
  done
  fail "torrent ${hash} did not complete within ${timeout}s"
}

wait_torrent_seeding() {
  local base=$1
  local cookie=$2
  local hash=$3
  local timeout=${4:-120}
  local deadline=$((SECONDS + timeout))
  local info progress state
  check_start "torrent ${hash} is seeding"
  while (( SECONDS < deadline )); do
    info=$(qbt_torrent_info "$base" "$cookie" "$hash")
    progress=$(qbt_torrent_field "$info" progress)
    state=$(qbt_torrent_field "$info" state)
    if python3 - "$progress" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1] or 0) >= 1.0 else 1)
PY
    then
      record_pass "torrent ${hash} is seeding" "state=${state} progress=${progress}"
      return 0
    fi
    sleep 2
  done
  fail "torrent ${hash} did not enter seeding state within ${timeout}s"
}

wait_torrent_partial() {
  local base=$1
  local cookie=$2
  local hash=$3
  local timeout=${4:-90}
  local deadline=$((SECONDS + timeout))
  local info progress state
  check_start "torrent ${hash} makes partial progress"
  while (( SECONDS < deadline )); do
    info=$(qbt_torrent_info "$base" "$cookie" "$hash")
    progress=$(qbt_torrent_field "$info" progress)
    state=$(qbt_torrent_field "$info" state)
    if python3 - "$progress" <<'PY'
import sys
p = float(sys.argv[1] or 0)
sys.exit(0 if 0.0 < p < 1.0 else 1)
PY
    then
      record_pass "torrent ${hash} makes partial progress" "state=${state} progress=${progress}"
      return 0
    fi
    sleep 2
  done
  fail "torrent ${hash} did not make partial progress within ${timeout}s"
}

make_bytes_file() {
  local path=$1
  local size=$2
  python3 - "$path" "$size" <<'PY'
import hashlib
import os
import sys
path = sys.argv[1]
size = int(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
pattern = hashlib.sha256(path.encode()).digest()
with open(path, "wb") as fh:
    remaining = size
    while remaining > 0:
        chunk = pattern[: min(len(pattern), remaining)]
        fh.write(chunk)
        remaining -= len(chunk)
PY
}

make_torrent() {
  local source=$1
  local name=$2
  local webseed=$3
  local out=$4
  local hash_out=$5
  python3 "${ROOT_DIR}/tests/fixtures/torrent-lab/make_torrent.py" \
    --source "$source" \
    --name "$name" \
    --webseed "$webseed" \
    --out "$out" \
    --hash-out "$hash_out"
}

make_tracker_torrent() {
  local source=$1
  local name=$2
  local announce=$3
  local out=$4
  local hash_out=$5
  python3 "${ROOT_DIR}/tests/fixtures/torrent-lab/make_torrent.py" \
    --source "$source" \
    --name "$name" \
    --announce "$announce" \
    --out "$out" \
    --hash-out "$hash_out"
}

setup_torrent_openvpn_lab() {
  local base_dir=$1
  local throttle=${2:-0}
  setup_openvpn_lab udp "$base_dir"
  start_torrent_lab "$LAB_INET_NET" "${base_dir}/torrent-data" "${base_dir}/torrent-logs" "$throttle"
}

start_qbt_seeder() {
  local name=$1
  local host_port=$2
  local config_dir=$3
  local downloads_dir=$4
  cleanup_container "$name"
  docker run -d --name "$name" --network "$LAB_INET_NET" \
    -e VPN_ENABLED=no -e ENABLE_SSL=no \
    -p "${host_port}:8080" \
    -v "${config_dir}:/config" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  TORRENT_SEEDER_IP=$(docker_network_ip "$name" "$LAB_INET_NET")
  record_evidence torrent_seeder_ip "$TORRENT_SEEDER_IP"
}

test_torrent_download_through_vpn() {
  local name=qbtvpn-torrent-basic
  local host_port=18105
  local base_dir downloads_dir cookie base torrent_file hash_file hash source_file expected request_logs
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_torrent_openvpn_lab "$base_dir" 0
  source_file="${base_dir}/torrent-data/basic.bin"
  make_bytes_file "$source_file" 262144
  expected=$(sha256sum "$source_file" | awk '{print $1}')
  torrent_file="${base_dir}/basic.torrent"
  hash_file="${base_dir}/basic.hash"
  make_torrent "$source_file" basic.bin "http://${TORRENT_LAB_IP}:8080/files/basic.bin" "$torrent_file" "$hash_file"
  hash=$(<"$hash_file")
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  base="http://127.0.0.1:${host_port}"
  qbt_add_torrent "$base" "$cookie" "$torrent_file" /downloads
  wait_torrent_complete "$base" "$cookie" "$hash" 180
  assert_sha256_file "downloaded torrent checksum matches source" "${downloads_dir}/basic.bin" "$expected"
  request_logs=$(docker logs torrent-lab 2>&1)
  assert_contains "torrent lab saw file request" "$request_logs" '/files/basic.bin'
  assert_contains "torrent lab saw VPN server source" "$request_logs" "\"client_ip\": \"${VPN_SERVER_INET_IP}\""
}

test_torrent_resume_after_container_restart() {
  local name=qbtvpn-torrent-resume
  local host_port=18106
  local base_dir downloads_dir cookie base torrent_file hash_file hash source_file expected
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_torrent_openvpn_lab "$base_dir" 65536
  source_file="${base_dir}/torrent-data/resume.bin"
  make_bytes_file "$source_file" 4194304
  expected=$(sha256sum "$source_file" | awk '{print $1}')
  torrent_file="${base_dir}/resume.torrent"
  hash_file="${base_dir}/resume.hash"
  make_torrent "$source_file" resume.bin "http://${TORRENT_LAB_IP}:8080/files/resume.bin" "$torrent_file" "$hash_file"
  hash=$(<"$hash_file")
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  base="http://127.0.0.1:${host_port}"
  qbt_add_torrent "$base" "$cookie" "$torrent_file" /downloads
  wait_torrent_partial "$base" "$cookie" "$hash" 90
  docker stop "$name" >/dev/null
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  wait_for_qbt "$name" "$host_port" http "$cookie"
  wait_torrent_complete "$base" "$cookie" "$hash" 240
  assert_sha256_file "resumed torrent checksum matches source" "${downloads_dir}/resume.bin" "$expected"
  record_evidence torrent_resume "$hash"
}

test_torrent_multiple_download_savepaths() {
  local name=qbtvpn-torrent-multi
  local host_port=18107
  local base_dir downloads_dir cookie base i source_file torrent_file hash_file hash expected save_path
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_torrent_openvpn_lab "$base_dir" 0
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  base="http://127.0.0.1:${host_port}"
  for i in 1 2 3; do
    source_file="${base_dir}/torrent-data/path-${i}/file-${i}.bin"
    make_bytes_file "$source_file" $((131072 * i))
    expected=$(sha256sum "$source_file" | awk '{print $1}')
    torrent_file="${base_dir}/file-${i}.torrent"
    hash_file="${base_dir}/file-${i}.hash"
    make_torrent "$source_file" "file-${i}.bin" "http://${TORRENT_LAB_IP}:8080/files/path-${i}/file-${i}.bin" "$torrent_file" "$hash_file"
    hash=$(<"$hash_file")
    save_path="/downloads/batch-${i}"
    qbt_add_torrent "$base" "$cookie" "$torrent_file" "$save_path"
    wait_torrent_complete "$base" "$cookie" "$hash" 180
    assert_sha256_file "batch ${i} checksum matches source" "${downloads_dir}/batch-${i}/file-${i}.bin" "$expected"
  done
  assert_command_fails "torrent data is not written under /config" docker exec "$name" sh -c 'find /config -type f -name "file-*.bin" | grep .'
  record_evidence torrent_batch "3 torrents completed"
}

test_torrent_real_peer_download() {
  local name=qbtvpn-torrent-peer-leecher
  local seeder=qbtvpn-torrent-peer-seeder
  local leecher_port=18114
  local seeder_port=18113
  local base_dir leecher_downloads seeder_config seeder_downloads cookie seeder_cookie base seeder_base
  local source_file torrent_file hash_file hash expected tracker_logs leecher_info leecher_state
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  leecher_downloads="${base_dir}/leecher-downloads"
  seeder_config="${base_dir}/seeder-config"
  seeder_downloads="${base_dir}/seeder-downloads"
  cookie=$(mktemp)
  seeder_cookie=$(mktemp)
  mkdir -p "$leecher_downloads" "$seeder_config" "$seeder_downloads"
  CLEANUP_PATHS+=("$base_dir" "$cookie" "$seeder_cookie")
  setup_torrent_openvpn_lab "$base_dir" 0

  source_file="${seeder_downloads}/peer-small.bin"
  make_bytes_file "$source_file" 196608
  expected=$(sha256sum "$source_file" | awk '{print $1}')
  torrent_file="${base_dir}/peer-small.torrent"
  hash_file="${base_dir}/peer-small.hash"
  make_tracker_torrent "$source_file" peer-small.bin "http://${TORRENT_LAB_IP}:8080/announce" "$torrent_file" "$hash_file"
  hash=$(<"$hash_file")

  start_qbt_seeder "$seeder" "$seeder_port" "$seeder_config" "$seeder_downloads"
  wait_for_qbt "$seeder" "$seeder_port" http "$seeder_cookie"
  seeder_base="http://127.0.0.1:${seeder_port}"
  qbt_add_seed_torrent "$seeder_base" "$seeder_cookie" "$torrent_file" /downloads
  wait_torrent_seeding "$seeder_base" "$seeder_cookie" "$hash" 120
  wait_docker_logs_contains "tracker saw seeder announce" torrent-lab '"type": "announce"' 60

  run_qbt_vpn_container "$name" "$leecher_port" openvpn "${base_dir}/client" "$leecher_downloads"
  assert_common_vpn_ready "$name" "$leecher_port" "$cookie" tun0
  base="http://127.0.0.1:${leecher_port}"
  qbt_add_torrent "$base" "$cookie" "$torrent_file" /downloads
  wait_torrent_complete "$base" "$cookie" "$hash" 180
  assert_sha256_file "peer torrent checksum matches source" "${leecher_downloads}/peer-small.bin" "$expected"

  leecher_info=$(qbt_torrent_info "$base" "$cookie" "$hash")
  leecher_state=$(qbt_torrent_field "$leecher_info" state)
  assert_contains "qBittorrent reports peer torrent is complete and seeding" "$leecher_state" 'UP'
  tracker_logs=$(docker logs torrent-lab 2>&1)
  assert_contains "tracker saw direct seeder announce" "$tracker_logs" "\"client_ip\": \"${TORRENT_SEEDER_IP}\""
  assert_contains "tracker saw leecher announce through VPN" "$tracker_logs" "\"client_ip\": \"${VPN_SERVER_INET_IP}\""
  assert_contains "tracker returned a peer to the torrent client" "$tracker_logs" '"peers_returned": 1'
  assert_not_contains "peer torrent did not use HTTP webseed file endpoint" "$tracker_logs" '/files/peer-small.bin'
  record_evidence torrent_complete "$hash"
  record_evidence torrent_protocol "tracker-peer"
}

test_torrent_outage_and_recovery() {
  local name=qbtvpn-torrent-recovery
  local host_port=18108
  local base_dir downloads_dir cookie base torrent_file hash_file hash source_file expected info state
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_torrent_openvpn_lab "$base_dir" 0
  source_file="${base_dir}/torrent-data/recovery.bin"
  make_bytes_file "$source_file" 524288
  expected=$(sha256sum "$source_file" | awk '{print $1}')
  torrent_file="${base_dir}/recovery.torrent"
  hash_file="${base_dir}/recovery.hash"
  make_torrent "$source_file" recovery.bin "http://${TORRENT_LAB_IP}:8080/files/recovery.bin" "$torrent_file" "$hash_file"
  hash=$(<"$hash_file")
  touch "${base_dir}/torrent-logs/paused"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  base="http://127.0.0.1:${host_port}"
  qbt_add_torrent "$base" "$cookie" "$torrent_file" /downloads
  sleep 12
  info=$(qbt_torrent_info "$base" "$cookie" "$hash")
  state=$(qbt_torrent_field "$info" state)
  assert_regex "torrent remains incomplete while webseed is paused" "$(qbt_torrent_field "$info" progress)" '^0(\.0+)?$'
  assert_regex "torrent state is visible during outage" "$state" '^[[:alnum:]_]+$'
  wait_docker_logs_contains "torrent lab returned paused responses" torrent-lab '"status": 503' 60
  rm -f "${base_dir}/torrent-logs/paused"
  docker stop "$name" >/dev/null
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  qbt_torrent_action "start persisted torrent after webseed outage clears" "$base" "$cookie" start "$hash"
  wait_torrent_complete "$base" "$cookie" "$hash" 240
  assert_sha256_file "recovered torrent checksum matches source" "${downloads_dir}/recovery.bin" "$expected"
  record_evidence torrent_recovery "$hash"
}

test_firewall_lan_webui_additional_ports() {
  local name=qbtvpn-additional-ports
  local host_port=18109
  local base_dir downloads_dir cookie rules
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab udp "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir" -e ADDITIONAL_PORTS=8112,9696
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  rules=$(docker exec "$name" iptables -S INPUT)
  assert_contains "additional TCP port 8112 is allowed from LAN" "$rules" '--dport 8112'
  assert_contains "additional TCP port 9696 is allowed from LAN" "$rules" '--dport 9696'
  assert_contains "WebUI port is allowed from LAN" "$rules" '--dport 8080'
}

test_multi_lan_routes() {
  local name=qbtvpn-multi-lan
  local host_port=18110
  local base_dir downloads_dir cookie routes
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab udp "$base_dir"
  cleanup_container "$name"
  docker run -d --name "$name" --network "$LAB_LAN_NET" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn \
    -e LAN_NETWORK="${LAB_LAN_SUBNET},192.168.50.0/24,10.10.0.0/16" \
    -e NAME_SERVERS="$PROBE_IP" -e ENABLE_SSL=no -e RESTART_CONTAINER=no \
    -p "${host_port}:8080" \
    -v "${base_dir}/client:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  wait_for_qbt "$name" "$host_port" http "$cookie"
  routes=$(docker exec "$name" ip route)
  assert_contains "route for first extra LAN exists" "$routes" '192.168.50.0/24'
  assert_contains "route for second extra LAN exists" "$routes" '10.10.0.0/16'
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
}

test_ipv6_blocked() {
  local name=qbtvpn-ipv6-blocked
  local host_port=18111
  local base_dir downloads_dir cookie
  ensure_tun
  ensure_fixture_images
  base_dir=$(mktemp -d)
  downloads_dir="${base_dir}/downloads"
  cookie=$(mktemp)
  mkdir -p "$downloads_dir"
  CLEANUP_PATHS+=("$base_dir" "$cookie")
  setup_openvpn_lab udp "$base_dir"
  run_qbt_vpn_container "$name" "$host_port" openvpn "${base_dir}/client" "$downloads_dir"
  assert_common_vpn_ready "$name" "$host_port" "$cookie" tun0
  assert_iptables_policy "IPv6 OUTPUT is DROP" "$name" ip6tables OUTPUT DROP
  assert_command_fails "IPv6 egress is blocked" docker exec "$name" timeout 8 curl -g -6 -fsS 'http://[2606:4700:4700::1111]'
  assert_container_output_contains "OpenVPN cmdline ignores pushed IPv6 routes" "$name" 'pull-filter ignore route-ipv6' sh -c "xargs -0 printf '%s ' < /proc/\$(pgrep openvpn)/cmdline"
}

test_healthcheck_restart_yes() {
  local name=qbtvpn-health-yes
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir")
  cleanup_container "$name"
  docker run -d --name "$name" \
    -e VPN_ENABLED=no -e ENABLE_SSL=no \
    -e HEALTH_CHECK_HOST=192.0.2.1 \
    -e HEALTH_CHECK_INTERVAL=1 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=yes \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  wait_exit "$name" 30
  assert_docker_logs_contains "healthcheck failure is logged" "$name" 'Network health check failed'
  assert_docker_logs_contains "healthcheck restart intent is logged" "$name" 'Halting container so the runtime restart policy can restart it'
}

test_healthcheck_restart_no() {
  local name=qbtvpn-health-no
  local config_dir downloads_dir cookie
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  cookie=$(mktemp)
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir" "$cookie")
  cleanup_container "$name"
  docker run -d --name "$name" \
    -e VPN_ENABLED=no -e ENABLE_SSL=no \
    -e HEALTH_CHECK_HOST=192.0.2.1 \
    -e HEALTH_CHECK_INTERVAL=1 \
    -e HEALTH_CHECK_AMOUNT=1 \
    -e RESTART_CONTAINER=no \
    -p 18112:8080 \
    -v "${config_dir}:/config" -v "${downloads_dir}:/downloads" "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  wait_for_qbt "$name" 18112 http "$cookie"
  wait_docker_logs_contains "healthcheck failure is logged without halt" "$name" 'Network health check failed' 30
  assert_container_running "container keeps running when RESTART_CONTAINER=no" "$name"
  assert_command_succeeds "qBittorrent still runs after healthcheck failure" docker exec "$name" pgrep qbittorrent-nox
  assert_docker_logs_not_contains "healthcheck does not halt when restart disabled" "$name" 'Halting container'
}

validation_case() {
  local test_name=$1
  local expected=$2
  shift 2
  local name="qbtvpn-${test_name}"
  local config_dir downloads_dir
  config_dir=$(mktemp -d)
  downloads_dir=$(mktemp -d)
  CLEANUP_PATHS+=("$config_dir" "$downloads_dir")
  local -a config_mount=(-v "${config_dir}:/config")
  local arg
  for arg in "$@"; do
    if [[ "$arg" == *":/config"* ]]; then
      config_mount=()
      break
    fi
  done
  cleanup_container "$name"
  docker run -d --name "$name" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    "$@" \
    "${config_mount[@]}" \
    -v "${downloads_dir}:/downloads" \
    "$IMAGE" >/dev/null
  LOG_CONTAINERS+=("$name")
  CLEANUP_CONTAINERS+=("$name")
  wait_exit "$name" 45
  assert_container_exited_nonzero "${test_name} exits nonzero" "$name"
  assert_docker_logs_contains "${test_name} emits exact error" "$name" "$expected"
  assert_docker_logs_not_contains "${test_name} does not start qBittorrent" "$name" 'Starting qBittorrent'
}

test_validation_failures() {
  local cfg
  validation_case invalid-vpn-type 'VPN_TYPE must be openvpn or wireguard' \
    -e VPN_ENABLED=yes -e VPN_TYPE=bogus -e LAN_NETWORK=172.16.0.0/16
  validation_case missing-vpn-config 'No OpenVPN .ovpn file found' \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -e LAN_NETWORK=172.16.0.0/16

  cfg=$(mktemp -d)
  CLEANUP_PATHS+=("$cfg")
  mkdir -p "${cfg}/openvpn"
  printf 'remote vpn.example 1194 udp\ndev tun\n' > "${cfg}/openvpn/client.ovpn"
  validation_case missing-lan-network 'LAN_NETWORK is required' \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -v "${cfg}:/config"
  validation_case invalid-lan-network 'LAN_NETWORK contains invalid IPv4 CIDR' \
    -e VPN_ENABLED=yes -e VPN_TYPE=openvpn -e LAN_NETWORK=not-a-cidr -v "${cfg}:/config"
  validation_case invalid-nameserver 'NAME_SERVERS only supports IPv4 resolvers' \
    -e VPN_ENABLED=no -e NAME_SERVERS=not-an-ip
  validation_case invalid-puid 'PUID must be numeric' \
    -e VPN_ENABLED=no -e PUID=abc
  validation_case invalid-umask 'UMASK must be an octal mode' \
    -e VPN_ENABLED=no -e UMASK=888

  cfg=$(mktemp -d)
  CLEANUP_PATHS+=("$cfg")
  mkdir -p "${cfg}/wireguard"
  printf '[Interface]\nPrivateKey = x\n' > "${cfg}/wireguard/not-wg0.conf"
  validation_case wireguard-wrong-filename 'WireGuard config must be named' \
    -e VPN_ENABLED=yes -e VPN_TYPE=wireguard -e LAN_NETWORK=172.16.0.0/16 -v "${cfg}:/config"
}

test_compose_example() {
  assert_command_succeeds "docker compose example syntax is valid" docker compose -f "${ROOT_DIR}/docker-compose.yml" config -q
}

SCENARIOS=(
  openvpn-udp-full
  openvpn-tcp-full
  openvpn-auth-success
  openvpn-auth-failure
  openvpn-options-full
  wireguard-full
  kill-switch-openvpn
  kill-switch-wireguard
  dns-through-vpn-no-leak
  torrent-download-through-vpn
  torrent-real-peer-download
  torrent-resume-after-container-restart
  torrent-multiple-download-savepaths
  torrent-outage-and-recovery
  firewall-lan-webui-additional-ports
  multi-lan-routes
  ipv6-blocked
  healthcheck-restart-yes
  healthcheck-restart-no
  validation-failures
  compose-example
)

scenario_min_assertions() {
  case "$1" in
    torrent-*) printf '14' ;;
    validation-failures) printf '20' ;;
    openvpn-auth-failure) printf '4' ;;
    healthcheck-restart-yes) printf '3' ;;
    healthcheck-restart-no) printf '5' ;;
    compose-example) printf '1' ;;
    *) printf '8' ;;
  esac
}

scenario_required_evidence() {
  case "$1" in
    openvpn-auth-failure)
      true
      ;;
    openvpn-*|wireguard-*|kill-switch-*|dns-through-vpn-no-leak|firewall-lan-webui-additional-ports|multi-lan-routes|ipv6-blocked)
      printf '%s\n' webui_version lan_network vpn_egress
      ;;
    torrent-*)
      printf '%s\n' webui_version lan_network vpn_egress torrent_complete
      ;;
    healthcheck-restart-no)
      printf '%s\n' webui_version
      ;;
    *)
      true
      ;;
  esac
}

run_one() {
  local selected=$1
  local fn="test_${selected//-/_}"
  declare -F "$fn" >/dev/null || fail "Unknown integration scenario '${selected}'"
  (
    CLEANUP_CONTAINERS=()
    CLEANUP_NETWORKS=()
    CLEANUP_PATHS=()
    LOG_CONTAINERS=()
    trap cleanup_scenario EXIT
    mapfile -t required < <(scenario_required_evidence "$selected")
    begin_scenario "$selected" "$(scenario_min_assertions "$selected")" "${required[@]}"
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
