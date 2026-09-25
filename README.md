<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center">English | <a href="https://docs.seedex.net/ru">Русский</a></p>

<p align="center">
  <a href="https://github.com/aggnostos/seedex-agent/releases/latest"><img src="https://img.shields.io/github/v/release/aggnostos/seedex-agent" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
</p>

# Seedex Agent

Seedex Agent: one command turns an Ubuntu server into a VPN and proxy server: WireGuard, AmneziaWG, sing-box, plus the Link API that a router running [Seedex](https://github.com/aggnostos/seedex-openwrt) pulls its configs from. The client configs are native WireGuard, AmneziaWG, and sing-box files, so any device with the usual apps can use the same server.

> [!WARNING]
> Seedex is under active development. Bugs are likely. Commands, settings, and behavior may change between versions. Read the release notes before you update.

## Features

- **One command to install** — AmneziaWG, WireGuard, a pinned sing-box release, the Link API, the firewall rules, the systemd units.
- **AmneziaWG with unique obfuscation** — the parameters are generated per installation, so no two servers look alike to deep packet inspection.
- **Eight proxy protocols** — VLESS Reality, Trojan, Shadowsocks, ShadowTLS, VMess, Hysteria2, TUIC, AnyTLS, each on a port you pick.
- **Native client configs** — `.conf` for the WireGuard family, `.json` for sing-box, share links for phone and desktop apps. No format of our own, nothing to lock you in.
- **Clients added live** — a new peer joins the running interface without a restart, so the others stay connected.
- **Rotation on demand** — server keys, obfuscation parameters, proxy credentials, the API certificate: each can be regenerated when you need it.
- **Link API for the router** — a paired router pulls its configs on its own and runs a restricted subset of `sdx` on the server. The token is issued once, the certificate is pinned by fingerprint.
- **No panel, no database** — plain bash with systemd, plus one static binary built from the Go standard library.
- **amd64 with arm64** — the same install command on both.

## Requirements

- A server running Ubuntu 24.04 or later with a public IP address and root access.
- A router running [seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) to pair with, or any device with a WireGuard, AmneziaWG, or sing-box app.

## Installation

### 1. Install the agent

On the server, run the installer as root:

```sh
wget -O - https://github.com/aggnostos/seedex-agent/releases/latest/download/install.sh | bash
```

The installer downloads the latest release, then installs the `sdx` command, WireGuard, AmneziaWG, a pinned sing-box release, plus the Link API. It generates the server keys, opens the ports, and enables the services. Nothing is started yet. To update later, run the same command again.

### 2. Set up tunnels

Add proxy protocols or VPN clients. For example:

```sh
sdx proxy add vless 443
sdx vpn add awg router
sdx vpn add wg router
```

The protocols are `vless`, `trojan`, `shadowsocks`, `shadowtls`, `vmess`, `hysteria2`, `tuic`, and `anytls`. VPN clients are added with `sdx vpn add awg <name>` (AmneziaWG) or `sdx vpn add wg <name>` (WireGuard).

### 3. Start the services

```sh
sdx start
```

The services are not running until you start them. `sdx start` brings up every protocol that has a client or a port.

### 4. Pair the router

```sh
sdx link add router
```

The command prints the token, the certificate fingerprint, and one line to run on the router. From then on, the router pulls its configs by itself.

### 5. Check the status

```
$ sdx

[*] VPN:
  Protocols:
    [*] awg       51821/udp
        router
    [*] wg        51820/udp
        router

[*] Proxy:
  Protocols:
    vless          443/tcp

[*] Link:
  Port:           8282/tcp
  Fingerprint:    sha256//...
  Routers:
    router
```

## Where to go next

- [Getting started](https://docs.seedex.net/getting-started) walks you through the full setup, router included.
- [seedex-agent user guide](https://docs.seedex.net/user-guide/seedex-agent) describes every `sdx` command on the server.
- [Developer guide](https://docs.seedex.net/developer-guide/seedex-agent) covers building, linting, and the project structure.

## Contributing

Bug reports, suggestions, and pull requests are welcome.

## License

AGPL-3.0. The Seedex name and logo are covered by the [trademark policy](https://docs.seedex.net/trademark), not by the license.
