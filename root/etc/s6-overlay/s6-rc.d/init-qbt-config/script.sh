#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/qbtvpn-common

# Certificates we generate use this organization. Any other subject is treated
# as user-supplied and left alone.
WEBUI_CERT_ORG='qBittorrentVPN'
# Apple rejects TLS server certificates valid for more than 825 days.
WEBUI_CERT_DAYS=825
# Regenerate our certificate once it is inside this window, or already expired.
WEBUI_CERT_RENEW_BEFORE_SECONDS=$((30 * 24 * 60 * 60))

webui_cert_is_generated() {
  local subject
  subject=$(openssl x509 -in "$1" -noout -subject 2>/dev/null) || return 1
  [[ "$subject" == *"O=${WEBUI_CERT_ORG}"* || "$subject" == *"O = ${WEBUI_CERT_ORG}"* ]]
}

webui_cert_has_san() {
  local san
  san=$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null || true)
  [[ "$san" == *'DNS:localhost'* && "$san" == *'127.0.0.1'* ]]
}

webui_cert_is_expiring() {
  ! openssl x509 -in "$1" -checkend "$WEBUI_CERT_RENEW_BEFORE_SECONDS" -noout >/dev/null 2>&1
}

generate_webui_cert() {
  local cert=$1
  local key=$2
  local tmp
  tmp=$(mktemp -d)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -days "$WEBUI_CERT_DAYS" \
    -keyout "${tmp}/key" \
    -out "${tmp}/cert" \
    -subj "/C=US/ST=Local/L=Local/O=${WEBUI_CERT_ORG}/OU=WebUI/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "extendedKeyUsage=serverAuth" \
    >/dev/null
  chmod 644 "${tmp}/cert"
  chmod 600 "${tmp}/key"
  mv -f "${tmp}/cert" "$cert"
  mv -f "${tmp}/key" "$key"
  rm -rf "$tmp"
}

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
  if [[ -f "$cert" ]] && ! webui_cert_is_generated "$cert"; then
    log INFO "Keeping user-supplied WebUI certificate at ${cert}"
  elif [[ ! -f "$cert" && -f "$key" ]]; then
    log WARN "WebUI key exists without a certificate; leaving ${key} untouched"
  elif [[ ! -f "$cert" || ! -f "$key" ]] || ! webui_cert_has_san "$cert" || webui_cert_is_expiring "$cert"; then
    if [[ -f "$cert" ]]; then
      log INFO "Replacing generated WebUI certificate (missing SAN or within 30 days of expiry)"
    else
      log INFO "Generating self-signed WebUI certificate"
    fi
    generate_webui_cert "$cert" "$key"
  else
    log INFO "Using existing generated WebUI certificate"
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
# The file holds the WebUI password hash. 600 keeps it readable by abc after the chown above.
chmod 600 "$QBT_CONF"
