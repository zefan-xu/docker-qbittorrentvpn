#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common
load_state

if [[ "$VPN_ENABLED_NORM" == no ]]; then
  log INFO "VPN disabled; skipping fail-closed firewall"
  exit 0
fi

log INFO "Applying fail-closed firewall"

iptables -F
iptables -t mangle -F
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

ip6tables -F 2>/dev/null || true
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -A INPUT -i "$VPN_DEVICE" -j ACCEPT
iptables -A OUTPUT -o "$VPN_DEVICE" -j ACCEPT

for remote_ip in $VPN_REMOTE_ADDRS; do
  iptables -A OUTPUT -o "$DOCKER_IFACE" -p "$VPN_PROTOCOL" -d "$remote_ip" --dport "$VPN_PORT" -j ACCEPT
  iptables -A INPUT -i "$DOCKER_IFACE" -p "$VPN_PROTOCOL" -s "$remote_ip" --sport "$VPN_PORT" -j ACCEPT
done

allow_lan_webui() {
  local cidr=$1
  iptables -A INPUT -i "$DOCKER_IFACE" -s "$cidr" -p tcp --dport "$QBT_WEBUI_PORT" -j ACCEPT
  iptables -A OUTPUT -o "$DOCKER_IFACE" -d "$cidr" -p tcp --sport "$QBT_WEBUI_PORT" -j ACCEPT
}

allow_lan_webui "$DOCKER_CIDR"
for lan in $LAN_NETWORKS; do
  allow_lan_webui "$lan"
done

if [[ -n "${ADDITIONAL_PORTS:-}" ]]; then
  mapfile -t ADDITIONAL_PORT_ITEMS < <(split_csv "$ADDITIONAL_PORTS")
  for port in "${ADDITIONAL_PORT_ITEMS[@]}"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "ADDITIONAL_PORTS contains invalid port '${port}'"
    for cidr in "$DOCKER_CIDR" $LAN_NETWORKS; do
      iptables -A INPUT -i "$DOCKER_IFACE" -s "$cidr" -p tcp --dport "$port" -j ACCEPT
      iptables -A OUTPUT -o "$DOCKER_IFACE" -d "$cidr" -p tcp --sport "$port" -j ACCEPT
    done
  done
fi

iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

log INFO "Firewall active"
iptables -S
