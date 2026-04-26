#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common

mkdir -p /config/qBittorrent/config /config/qBittorrent/data/logs /downloads/temp

if [[ ! -f "$QBT_CONF" ]]; then
  log INFO "Seeding qBittorrent config at ${QBT_CONF}"
  cp "$QBT_DEFAULT_CONF" "$QBT_CONF"
fi

set_qbt_config_value BitTorrent 'Session\Port' "$QBT_TORRENT_PORT"
set_qbt_config_value BitTorrent 'Session\UseRandomPort' false
set_qbt_config_value BitTorrent 'Session\DefaultSavePath' /downloads
set_qbt_config_value BitTorrent 'Session\TempPath' /downloads/temp
set_qbt_config_value BitTorrent 'Session\TempPathEnabled' true
set_qbt_config_value Preferences 'WebUI\Port' "$QBT_WEBUI_PORT"
set_qbt_config_value Preferences 'WebUI\HostHeaderValidation' false
set_qbt_config_value Preferences 'WebUI\Username' admin

ENABLE_SSL_NORM=$(normalize_bool ENABLE_SSL "${ENABLE_SSL:-yes}")
if [[ "$ENABLE_SSL_NORM" == yes ]]; then
  cert=/config/qBittorrent/config/WebUICertificate.crt
  key=/config/qBittorrent/config/WebUIKey.key
  if [[ ! -f "$cert" || ! -f "$key" ]]; then
    log INFO "Generating self-signed WebUI certificate"
    openssl req -new -x509 -nodes -days 3650 \
      -out "$cert" \
      -keyout "$key" \
      -subj "/C=US/ST=Local/L=Local/O=qBittorrentVPN/OU=WebUI/CN=localhost" >/dev/null 2>&1
  fi
  set_qbt_config_value Preferences 'WebUI\HTTPS\Enabled' true
  set_qbt_config_value Preferences 'WebUI\HTTPS\CertificatePath' "$cert"
  set_qbt_config_value Preferences 'WebUI\HTTPS\KeyPath' "$key"
else
  log INFO "Disabling qBittorrent WebUI HTTPS"
  tmp=$(mktemp)
  awk 'index($0, "WebUI\\HTTPS\\") != 1 { print }' "$QBT_CONF" > "$tmp"
  mv "$tmp" "$QBT_CONF"
fi

chown -R abc:abc /config/qBittorrent /downloads
chmod 755 "$QBT_CONF"
