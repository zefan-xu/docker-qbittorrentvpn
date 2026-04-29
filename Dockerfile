FROM ubuntu:26.04@sha256:5e275723f82c67e387ba9e3c24baa0abdcb268917f276a0561c97bef9450d0b4

ARG TARGETARCH
# renovate: datasource=github-releases depName=just-containers/s6-overlay extractVersion=^v(?<version>.*)$ versioning=loose
ARG S6_OVERLAY_VERSION=3.2.2.0

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
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      xz-utils \
      tzdata \
      qbittorrent-nox \
      openvpn \
      wireguard-tools \
      iptables \
      iproute2 \
      ipcalc-ng \
      dos2unix \
      moreutils \
      openssl \
      procps \
      kmod \
      dnsutils \
      iputils-ping \
      net-tools \
      7zip \
      unzip \
      zip \
      unrar-free; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -r abc; \
    useradd -r -g abc -d /config -s /usr/sbin/nologin abc; \
    mkdir -p /config /downloads /run/qbtvpn

WORKDIR /tmp

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) S6_ARCH=x86_64 ;; \
      arm64) S6_ARCH=aarch64 ;; \
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
    rm -f /tmp/s6-overlay-*.tar.xz /tmp/s6-overlay-*.tar.xz.sha256

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
  CMD /usr/local/bin/qbtvpn-container-healthcheck
