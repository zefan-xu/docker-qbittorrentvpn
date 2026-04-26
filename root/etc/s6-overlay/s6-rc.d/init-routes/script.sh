#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common
load_state

if [[ "$VPN_ENABLED_NORM" == no ]]; then
  log INFO "VPN disabled; skipping LAN route setup"
  exit 0
fi

for lan in $LAN_NETWORKS; do
  log INFO "Routing ${lan} via ${DOCKER_GATEWAY} dev ${DOCKER_IFACE}"
  ip route replace "$lan" via "$DOCKER_GATEWAY" dev "$DOCKER_IFACE"
done

ip route
