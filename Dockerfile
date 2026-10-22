FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944

ARG TARGETARCH
# renovate: datasource=github-releases depName=just-containers/s6-overlay extractVersion=^v(?<version>.*)$ versioning=loose
ARG S6_OVERLAY_VERSION=3.2.3.2
# Official static build from userdocs/qbittorrent-nox-static (tag release-<qbt>_v<libtorrent>).
# Each arch is a separate Renovate dependency so a tag bump also updates that
# asset's SHA-256. The two tags are checked for equality below. Renovate does
# not notice a re-upload of the same tag (it keeps the current digest); the
# sha256sum check still fails the build until the pins are updated.
# renovate: datasource=github-release-attachments depName=userdocs/qbittorrent-nox-static/x86_64-qbittorrent-nox packageName=userdocs/qbittorrent-nox-static
ARG QBITTORRENT_NOX_RELEASE=release-5.3.0_v2.1.2
ARG QBITTORRENT_NOX_SHA256_AMD64=006071fb46f4223de042d1b7fed877e5d8ea9ed11066779c92ab889a658cc30b
# renovate: datasource=github-release-attachments depName=userdocs/qbittorrent-nox-static/aarch64-qbittorrent-nox packageName=userdocs/qbittorrent-nox-static
ARG QBITTORRENT_NOX_RELEASE_ARM64=release-5.3.0_v2.1.2
ARG QBITTORRENT_NOX_SHA256_ARM64=5e4eeeea0ca58f551f21d4071a9f97dca47fc27f9884214e12eb2cde113d8843
# resolute-updates includes the security pocket, so these pins can move forward.
# renovate: datasource=deb depName=openvpn suite=resolute-updates components=main binaryArch=amd64
ARG OPENVPN_VERSION=2.7.0-1ubuntu1.3
# wireguard-tools is only published in the release pocket.
# renovate: datasource=deb depName=wireguard-tools suite=resolute components=main binaryArch=amd64
ARG WIREGUARD_TOOLS_VERSION=1.0.20250521-1ubuntu1
# libssl3t64 and openssl-provider-legacy ship the same version as the openssl CLI.
# renovate: datasource=deb depName=openssl suite=resolute-updates components=main binaryArch=amd64
ARG OPENSSL_VERSION=3.5.5-1ubuntu3.7

ENV DEBIAN_FRONTEND=noninteractive \
    S6_VERBOSITY=1 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    PUID=1000 \
    PGID=1000 \
    UMASK=002 \
    VPN_ENABLED=yes \
    VPN_TYPE=openvpn \
    ENABLE_SSL=yes \
    HEALTH_CHECK_HOST=one.one.one.one \
    HEALTH_CHECK_INTERVAL=300 \
    HEALTH_CHECK_SILENT=1 \
    HEALTH_CHECK_AMOUNT=1 \
    RESTART_CONTAINER=yes

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
      sed -i -E 's/^Components: .*/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    apt-get update; \
    # hadolint ignore=DL3005
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      xz-utils \
      tzdata \
      openvpn="${OPENVPN_VERSION}" \
      wireguard-tools="${WIREGUARD_TOOLS_VERSION}" \
      iptables \
      iproute2 \
      ipcalc-ng \
      dos2unix \
      moreutils \
      openssl="${OPENSSL_VERSION}" \
      libssl3t64="${OPENSSL_VERSION}" \
      openssl-provider-legacy="${OPENSSL_VERSION}" \
      procps \
      kmod \
      dnsutils \
      iputils-ping \
      net-tools \
      7zip \
      unzip \
      zip \
      unrar-free; \
    rm -f /usr/bin/pebble; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -r abc; \
    useradd -r -g abc -d /config -s /usr/sbin/nologin abc; \
    mkdir -p /config /downloads /run/qbtvpn

WORKDIR /tmp

RUN set -eux; \
    if [ "${QBITTORRENT_NOX_RELEASE}" != "${QBITTORRENT_NOX_RELEASE_ARM64}" ]; then \
      echo "qBittorrent release pins diverged: amd64=${QBITTORRENT_NOX_RELEASE} arm64=${QBITTORRENT_NOX_RELEASE_ARM64}" >&2; \
      exit 1; \
    fi; \
    case "${TARGETARCH}" in \
      amd64) S6_ARCH=x86_64; QBT_SHA256="${QBITTORRENT_NOX_SHA256_AMD64}" ;; \
      arm64) S6_ARCH=aarch64; QBT_SHA256="${QBITTORRENT_NOX_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    for asset in noarch "${S6_ARCH}"; do \
      curl -fsSLo "/tmp/s6-overlay-${asset}.tar.xz" \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${asset}.tar.xz"; \
      curl -fsSLo "/tmp/s6-overlay-${asset}.tar.xz.sha256" \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${asset}.tar.xz.sha256"; \
    done; \
    sha256sum -c s6-overlay-noarch.tar.xz.sha256; \
    sha256sum -c "s6-overlay-${S6_ARCH}.tar.xz.sha256"; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf "/tmp/s6-overlay-${S6_ARCH}.tar.xz"; \
    rm -f /tmp/s6-overlay-*.tar.xz /tmp/s6-overlay-*.tar.xz.sha256; \
    curl -fsSLo /tmp/qbittorrent-nox \
      "https://github.com/userdocs/qbittorrent-nox-static/releases/download/${QBITTORRENT_NOX_RELEASE}/${S6_ARCH}-qbittorrent-nox"; \
    echo "${QBT_SHA256}  /tmp/qbittorrent-nox" > /tmp/qbittorrent-nox.sha256; \
    sha256sum -c /tmp/qbittorrent-nox.sha256; \
    install -m 0755 /tmp/qbittorrent-nox /usr/bin/qbittorrent-nox; \
    rm -f /tmp/qbittorrent-nox /tmp/qbittorrent-nox.sha256; \
    /usr/bin/qbittorrent-nox --version

WORKDIR /

COPY root/ /

RUN set -eux; \
    find /etc/s6-overlay/s6-rc.d -type f \( -name up -o -name run -o -name finish -o -name '*.sh' \) -exec chmod +x {} \;; \
    chmod +x /usr/local/bin/qbtvpn-*; \
    mkdir -p /config /downloads /run/qbtvpn

EXPOSE 8080 8999 8999/udp
VOLUME ["/config", "/downloads"]
ENTRYPOINT ["/init"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/qbtvpn-container-healthcheck"]
