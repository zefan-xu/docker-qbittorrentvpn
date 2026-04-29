# qBittorrent + OpenVPN/WireGuard

Modern qBittorrent VPN container with a fail-closed firewall, OpenVPN or WireGuard, s6-overlay supervision, and multi-arch Docker Hub/GHCR images.

This repository is forked from [DyonR/docker-qbittorrentvpn](https://github.com/DyonR/docker-qbittorrentvpn), which originated from MarkusMcNugen/docker-qBittorrentvpn. The project remains licensed under GPL-3.0.

## Image

Pull from Docker Hub:

```sh
docker pull benjaminxzf/docker-qbittorrentvpn:latest
```

Or pull from GHCR:

```sh
docker pull ghcr.io/zefan-xu/docker-qbittorrentvpn:latest
```

Supported platforms:

- `linux/amd64`
- `linux/arm64`

Runtime stack:

- Ubuntu 26.04 LTS
- qBittorrent-nox from Ubuntu packages
- OpenVPN and WireGuard from Ubuntu packages
- s6-overlay v3
- iptables-nft fail-closed kill switch

## Compose

```yaml
services:
  qbittorrentvpn:
    image: benjaminxzf/docker-qbittorrentvpn:latest
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.conf.all.src_valid_mark: "1"
    environment:
      VPN_ENABLED: "yes"
      VPN_TYPE: openvpn
      LAN_NETWORK: 192.168.1.0/24
      NAME_SERVERS: 1.1.1.1,8.8.8.8
      ENABLE_SSL: "yes"
      PUID: "1000"
      PGID: "1000"
      UMASK: "002"
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports:
      - 8080:8080
      - 8999:8999
      - 8999:8999/udp
    restart: unless-stopped
```

Put one OpenVPN `.ovpn` file in `./config/openvpn/`, or put a WireGuard config at `./config/wireguard/wg0.conf`.
WireGuard `DNS =` lines are ignored; use `NAME_SERVERS` instead.

## WebUI Login

qBittorrent 5 no longer uses the old `admin/adminadmin` default. On first start, qBittorrent prints a temporary WebUI password in the container logs.

```sh
docker logs qbittorrentvpn
```

The username is `admin` unless you change it in qBittorrent after first login.

If `ENABLE_SSL=yes`, open `https://HOST:8080`. The container generates a self-signed certificate on first start. If `ENABLE_SSL=no`, open `http://HOST:8080`.

## Environment

| Variable | Default | Description |
| --- | --- | --- |
| `VPN_ENABLED` | `yes` | Enable VPN protection. Set `no` only for testing. |
| `VPN_TYPE` | `openvpn` | `openvpn` or `wireguard`. |
| `VPN_USERNAME` | empty | Optional OpenVPN username. Writes a runtime credentials file. |
| `VPN_PASSWORD` | empty | Optional OpenVPN password. |
| `VPN_OPTIONS` | empty | Extra OpenVPN CLI options. |
| `LAN_NETWORK` | required with VPN | Comma-delimited IPv4 CIDRs allowed to reach the WebUI, for example `192.168.1.0/24,10.0.0.0/8`. |
| `NAME_SERVERS` | `1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4` | IPv4 DNS resolvers written to `/etc/resolv.conf`. |
| `ENABLE_SSL` | `yes` | Generate and enable a self-signed HTTPS certificate for qBittorrent WebUI. |
| `PUID` | `1000` | UID for the `abc` user running qBittorrent. |
| `PGID` | `1000` | GID for the `abc` group running qBittorrent. |
| `UMASK` | `002` | Umask used by qBittorrent. |
| `HEALTH_CHECK_HOST` | `one.one.one.one` | Ping target for VPN health checks. |
| `HEALTH_CHECK_INTERVAL` | `300` | Seconds between health checks. |
| `HEALTH_CHECK_SILENT` | `1` | Set `0`, `false`, or `no` to log successful checks. |
| `HEALTH_CHECK_AMOUNT` | `1` | Ping count per health check. |
| `RESTART_CONTAINER` | `yes` | Halt the container on health-check failure so the runtime restart policy can restart it. |
| `ADDITIONAL_PORTS` | empty | Comma-delimited TCP ports allowed from LAN networks. |

Removed variables:

- `LEGACY_IPTABLES`: legacy iptables switching was removed. The image uses Ubuntu's nft-backed iptables.
- `INSTALL_PYTHON3`: runtime Python installation was removed.

IPv6 VPN routing is not supported in this modernization. The firewall drops IPv6 input/output by default when VPN protection is enabled.

## Volumes And Ports

| Path/Port | Purpose |
| --- | --- |
| `/config` | qBittorrent, OpenVPN, and WireGuard configuration. |
| `/downloads` | qBittorrent download path. |
| `8080/tcp` | qBittorrent WebUI. |
| `8999/tcp` | qBittorrent listening port. |
| `8999/udp` | qBittorrent listening port. |

The WebUI port inside the container is fixed at `8080`. Remap the host port with Docker, for example `18080:8080`.

## Testing

This project assumes local Docker may be unavailable. Docker-dependent validation runs in GitHub Actions.

Keep working until this release gate is true: CI is green on the exact commit being merged or tagged, the torrent jobs prove completed downloads with checksums, the VPN jobs prove egress source IPs are the VPN endpoint, kill-switch jobs prove blocked egress after tunnel loss, and the release workflow has passing registry smoke tests for every image tag it published.

CI covers:

- Docker runner capability for `/dev/net/tun` and `NET_ADMIN`
- Dockerfile, shell, YAML, and workflow linting
- amd64 runtime build and arm64 build check
- VPN-disabled startup
- first-run and existing qBittorrent config behavior
- UID/GID/umask behavior
- HTTPS on/off behavior
- OpenVPN UDP and TCP fixtures
- OpenVPN credentials and option pass-through
- WireGuard fixture
- validation failures for bad VPN settings
- multiple LAN networks
- additional allowed ports
- custom DNS resolvers
- OpenVPN and WireGuard kill-switch behavior
- IPv6 fail-closed behavior
- health-check restart behavior
- qBittorrent WebUI/API readiness
- qBittorrent config persistence across restarts
- torrent port exposure
- WebSeed torrent download through the VPN with checksum verification
- real peer-to-peer small `.torrent` download between two qBittorrent clients
- tracker evidence that the peer-to-peer leecher announces through the VPN source IP
- proof that the peer-to-peer torrent does not use the HTTP WebSeed endpoint
- torrent resume after container restart
- multiple torrent save paths
- torrent outage and recovery behavior
- graceful container stop
- compose syntax

## Release Flow

The `Release` GitHub Actions workflow handles both immutable versioned releases and the rolling daily release.

Versioned release images are published by pushing tags matching `v*`.

```sh
git tag v5.1.4-3
git push --tags
```

Versioned releases publish the semver tag, the major/minor tag, and a `sha-...` tag to both registries:

- `benjaminxzf/docker-qbittorrentvpn`
- `ghcr.io/zefan-xu/docker-qbittorrentvpn`

Versioned releases also create immutable GitHub Releases such as `v5.1.4-3`, with release notes, image digests, and compressed multi-arch OCI archives exported from the published GHCR image after registry smoke passes.

The same `Release` workflow is also scheduled daily on `main`. Scheduled and manually-dispatched `main` runs detect the qBittorrent version from the tested image, increment the next `vX.Y.Z-N` tag from existing remote tags, and publish `latest`, `X.Y.Z-N`, `X.Y`, and `sha-...` tags to both registries. After registry smoke passes, the workflow updates the rolling GitHub Release named `latest` and creates the new immutable versioned GitHub Release. The `latest` release remains marked as GitHub's Latest release.
