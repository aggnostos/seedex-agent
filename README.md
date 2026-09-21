<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center">English | <a href="README_RU.md">Русский</a></p>

# Seedex Agent

Seedex Agent: one command turns an Ubuntu server into a VPN and proxy server: WireGuard, AmneziaWG, sing-box, and the Link API that a router running [Seedex](https://github.com/aggnostos/seedex-openwrt) pulls its configs from. The client configs are native WireGuard, AmneziaWG, and sing-box files, so any device with the usual apps can use the same server.

## Requirements

- A server running Ubuntu 24.04 with a public IP address and root access.
- A router running [seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) to pair with, or any device with a WireGuard, AmneziaWG, or sing-box app.

## Installation

### 1. Install the agent

On the server, run the installer as root:

```sh
wget -O - https://github.com/aggnostos/seedex-agent/releases/latest/download/install.sh | bash
```

The installer downloads the latest release and installs the `sdx` command, WireGuard, AmneziaWG, a pinned sing-box release, and the Link API. It generates the server keys, opens the ports, and enables the services. To update later, run the same command again.

### 2. Start the services

```sh
sdx start
```

### 3. Set up tunnels

Add proxy protocols or VPN clients. For example:

```sh
sdx proxy add vless 443
sdx vpn add awg router
sdx vpn add wg router
```

The protocols are `vless`, `trojan`, `shadowsocks`, `shadowtls`, `vmess`, `hysteria2`, `tuic`, and `anytls`. VPN clients are added with `sdx vpn add awg <name>` (AmneziaWG) or `sdx vpn add wg <name>` (WireGuard).

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
  Port:           8447/tcp
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

AGPL-3.0.
