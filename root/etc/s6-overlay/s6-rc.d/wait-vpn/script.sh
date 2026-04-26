#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common
load_state

if [[ "$VPN_ENABLED_NORM" == no ]]; then
  log INFO "VPN disabled; skipping tunnel wait"
  exit 0
fi

timeout=${VPN_WAIT_TIMEOUT:-90}
deadline=$((SECONDS + timeout))

while (( SECONDS < deadline )); do
  if ip link show "$VPN_DEVICE" >/dev/null 2>&1 && ip -4 addr show dev "$VPN_DEVICE" | grep -q 'inet '; then
    log INFO "VPN interface ${VPN_DEVICE} is ready"
    exit 0
  fi
  sleep 1
done

die "Timed out waiting for VPN interface ${VPN_DEVICE}"
