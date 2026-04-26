#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common

mkdir -p "$STATE_DIR"
: > "$STATE_FILE"

configure_name_servers() {
  local name_servers=${NAME_SERVERS:-1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4}
  local -a name_server_items
  mapfile -t name_server_items < <(split_csv "$name_servers")
  [[ ${#name_server_items[@]} -gt 0 ]] || die "NAME_SERVERS must contain at least one IPv4 resolver"
  : > /etc/resolv.conf
  local ns
  for ns in "${name_server_items[@]}"; do
    is_ipv4 "$ns" || die "NAME_SERVERS only supports IPv4 resolvers, got '${ns}'"
    printf 'nameserver %s\n' "$ns" >> /etc/resolv.conf
  done
  write_state_var NAME_SERVERS_LIST "${name_server_items[*]}"
}

resolve_remote_ipv4() {
  local remote=$1
  if is_ipv4 "$remote"; then
    printf '%s\n' "$remote"
    return 0
  fi
  getent ahostsv4 "$remote" | awk '{print $1}' | sort -u | xargs
}

rewrite_openvpn_remote() {
  local config=$1
  local remote_addr=$2
  local tmp
  tmp=$(mktemp)
  awk -v remote_addr="$remote_addr" '
    /^[[:space:]]*remote[[:space:]]+/ && !done {
      $2 = remote_addr
      done = 1
    }
    { print }
  ' "$config" > "$tmp"
  mv "$tmp" "$config"
}

rewrite_wireguard_endpoint() {
  local config=$1
  local remote_addr=$2
  local remote_port=$3
  local tmp
  tmp=$(mktemp)
  awk -v remote_addr="$remote_addr" -v remote_port="$remote_port" '
    /^[[:space:]]*Endpoint[[:space:]]*=/ && !done {
      sub(/=.*/, "= " remote_addr ":" remote_port)
      done = 1
    }
    { print }
  ' "$config" > "$tmp"
  mv "$tmp" "$config"
}

detect_docker_network

VPN_ENABLED_NORM=$(normalize_bool VPN_ENABLED "${VPN_ENABLED:-yes}")
VPN_TYPE_NORM=$(lower "$(trim "${VPN_TYPE:-openvpn}")")
[[ "$VPN_TYPE_NORM" == openvpn || "$VPN_TYPE_NORM" == wireguard ]] || die "VPN_TYPE must be openvpn or wireguard, got '${VPN_TYPE:-}'"

write_state_var VPN_ENABLED_NORM "$VPN_ENABLED_NORM"
write_state_var VPN_TYPE_NORM "$VPN_TYPE_NORM"
write_state_var DOCKER_IFACE "$DOCKER_IFACE"
write_state_var DOCKER_GATEWAY "$DOCKER_GATEWAY"
write_state_var DOCKER_CIDR "$DOCKER_CIDR"

if [[ "$VPN_ENABLED_NORM" == no ]]; then
  configure_name_servers
  log WARNING "VPN is disabled; qBittorrent traffic will not be protected"
  exit 0
fi

LAN_NETWORK=${LAN_NETWORK:-}
mapfile -t LAN_NETWORK_ITEMS < <(split_csv "$LAN_NETWORK")
[[ ${#LAN_NETWORK_ITEMS[@]} -gt 0 ]] || die "LAN_NETWORK is required when VPN_ENABLED=yes"
for lan in "${LAN_NETWORK_ITEMS[@]}"; do
  validate_ipv4_cidr "$lan" || die "LAN_NETWORK contains invalid IPv4 CIDR '${lan}'"
done
write_state_var LAN_NETWORKS "${LAN_NETWORK_ITEMS[*]}"

if [[ "$VPN_TYPE_NORM" == openvpn ]]; then
  mkdir -p /config/openvpn
  VPN_CONFIG=$(find /config/openvpn -maxdepth 1 -type f -name '*.ovpn' -print -quit)
  [[ -n "$VPN_CONFIG" ]] || die "No OpenVPN .ovpn file found in /config/openvpn"
  runtime_config=/run/qbtvpn/client.ovpn
  cp "$VPN_CONFIG" "$runtime_config"
  dos2unix -q "$runtime_config"

  if [[ -n "${VPN_USERNAME:-}" && -n "${VPN_PASSWORD:-}" ]]; then
    cred_file=/run/qbtvpn/openvpn-credentials.conf
    printf '%s\n%s\n' "$VPN_USERNAME" "$VPN_PASSWORD" > "$cred_file"
    chmod 600 "$cred_file"
    if grep -Eq '^[[:space:]]*auth-user-pass([[:space:]].*)?$' "$runtime_config"; then
      sed -i "s|^[[:space:]]*auth-user-pass.*|auth-user-pass ${cred_file}|" "$runtime_config"
    else
      printf 'auth-user-pass %s\n' "$cred_file" | cat - "$runtime_config" > /run/qbtvpn/client.ovpn.tmp
      mv /run/qbtvpn/client.ovpn.tmp "$runtime_config"
    fi
  fi

  remote_line=$(grep -E '^[[:space:]]*remote[[:space:]]+' "$runtime_config" | head -n 1 || true)
  [[ -n "$remote_line" ]] || die "OpenVPN config must contain a remote line"
  VPN_REMOTE=$(awk '{print $2}' <<< "$remote_line")
  VPN_PORT=$(awk '{print $3}' <<< "$remote_line")
  [[ -n "$VPN_REMOTE" && -n "$VPN_PORT" ]] || die "OpenVPN remote line must include host and port"
  [[ "$VPN_PORT" =~ ^[0-9]{2,5}$ ]] || die "OpenVPN remote port is invalid: '${VPN_PORT}'"

  proto_line=$(grep -E '^[[:space:]]*proto[[:space:]]+' "$runtime_config" | head -n 1 || true)
  VPN_PROTOCOL=$(awk '{print $2}' <<< "${proto_line:-}")
  [[ -n "$VPN_PROTOCOL" ]] || VPN_PROTOCOL=$(awk '{print $4}' <<< "$remote_line")
  [[ -n "$VPN_PROTOCOL" ]] || VPN_PROTOCOL=udp
  case "$VPN_PROTOCOL" in
    udp|udp4|udp6) VPN_PROTOCOL=udp ;;
    tcp|tcp4|tcp6|tcp-client) VPN_PROTOCOL=tcp ;;
    *) die "Unsupported OpenVPN proto '${VPN_PROTOCOL}'" ;;
  esac

  dev_line=$(grep -E '^[[:space:]]*dev[[:space:]]+' "$runtime_config" | head -n 1 || true)
  [[ -n "$dev_line" ]] || die "OpenVPN config must contain a dev line"
  dev_value=$(awk '{print $2}' <<< "$dev_line")
  case "$dev_value" in
    tun|tap) VPN_DEVICE="${dev_value}0" ;;
    tun[0-9]*|tap[0-9]*) VPN_DEVICE="$dev_value" ;;
    *) die "Unsupported OpenVPN dev '${dev_value}'" ;;
  esac

  write_state_var VPN_CONFIG "$runtime_config"
  write_state_var VPN_CONFIG_DIR /config/openvpn
else
  mkdir -p /config/wireguard
  VPN_CONFIG=$(find /config/wireguard -maxdepth 1 -type f -name '*.conf' -print -quit)
  [[ -n "$VPN_CONFIG" ]] || die "No WireGuard .conf file found in /config/wireguard"
  [[ "$VPN_CONFIG" == /config/wireguard/wg0.conf ]] || die "WireGuard config must be named /config/wireguard/wg0.conf"
  runtime_config=/run/qbtvpn/wg0.conf
  awk 'tolower($1) != "dns" { print }' "$VPN_CONFIG" > "$runtime_config"
  chmod 600 "$runtime_config"
  endpoint_line=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$VPN_CONFIG" | head -n 1 || true)
  [[ -n "$endpoint_line" ]] || die "WireGuard config must contain an Endpoint"
  endpoint=${endpoint_line#*=}
  endpoint=$(trim "$endpoint")
  [[ "$endpoint" != \[* ]] || die "WireGuard IPv6 endpoints are not supported"
  VPN_REMOTE=${endpoint%:*}
  VPN_PORT=${endpoint##*:}
  [[ -n "$VPN_REMOTE" && -n "$VPN_PORT" && "$VPN_REMOTE" != "$VPN_PORT" ]] || die "WireGuard Endpoint must be host:port"
  [[ "$VPN_PORT" =~ ^[0-9]{2,5}$ ]] || die "WireGuard endpoint port is invalid: '${VPN_PORT}'"
  VPN_PROTOCOL=udp
  VPN_DEVICE=wg0

  write_state_var VPN_CONFIG "$runtime_config"
  write_state_var VPN_CONFIG_DIR /config/wireguard
fi

VPN_REMOTE_ADDRS=$(resolve_remote_ipv4 "$VPN_REMOTE" || true)
[[ -n "$VPN_REMOTE_ADDRS" ]] || die "Unable to resolve VPN remote '${VPN_REMOTE}' to an IPv4 address"
VPN_REMOTE_ADDR=${VPN_REMOTE_ADDRS%% *}

if [[ "$VPN_TYPE_NORM" == openvpn ]]; then
  rewrite_openvpn_remote "$runtime_config" "$VPN_REMOTE_ADDR"
else
  rewrite_wireguard_endpoint "$runtime_config" "$VPN_REMOTE_ADDR" "$VPN_PORT"
fi

configure_name_servers

write_state_var VPN_REMOTE "$VPN_REMOTE"
write_state_var VPN_REMOTE_ADDRS "$VPN_REMOTE_ADDRS"
write_state_var VPN_REMOTE_ADDR "$VPN_REMOTE_ADDR"
write_state_var VPN_PORT "$VPN_PORT"
write_state_var VPN_PROTOCOL "$VPN_PROTOCOL"
write_state_var VPN_DEVICE "$VPN_DEVICE"

log INFO "VPN config OK: type=${VPN_TYPE_NORM}, remote=${VPN_REMOTE} (${VPN_REMOTE_ADDR}:${VPN_PORT}/${VPN_PROTOCOL}), device=${VPN_DEVICE}"
