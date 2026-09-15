<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center">English | <a href="README_RU.md">Русский</a></p>

# Seedex Agent

Seedex Agent is the server side of [Seedex](https://github.com/aggnostos/seedex-openwrt). One command turns an Ubuntu server into a VPN and Proxy server: AmneziaWG, sing-box and Link API that the router pulls its configs from.

## Requirements

- A server running Ubuntu 24.04 with a public IP address and root access.
- A router running [seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) to pair with. Any AmneziaWG or sing-box client works with the exported configs.

## Installation

### 1. Install the agent

On the server, run the installer as root:

```sh
wget -O - https://github.com/aggnostos/seedex-agent/releases/latest/download/install.sh | bash
```

The installer downloads the latest release and installs the `sdx` command, AmneziaWG, a pinned sing-box release, and the link API. It generates the server keys, opens the ports, and enables the services. To update later, run the same command again.

### 2. Start the services

```sh
sdx start
```

### 3. Add a proxy protocol

Add a proxy protocol. For example, VLESS Reality on port 443:

```sh
sdx proxy add vless 443
```

The protocols are `vless`, `trojan`, `shadowsocks`, `shadowtls`, `vmess`, `hysteria2`, `tuic`, and `anytls`. A VPN client is created during installation. `sdx vpn add <name>` adds more.

### 4. Pair the router

```sh
sdx link add router
```

The command prints the token, the certificate fingerprint, and one line to run on the router. From then on, the router pulls its configs by itself.

### 5. Check the status

```sh
sdx
```


## Where to go next

- [Getting started](https://docs.seedex.net/getting-started) walks you through the full setup, router included.
- [seedex-agent user guide](https://docs.seedex.net/user-guide/seedex-agent) describes every `sdx` command on the server.
- [Developer guide](https://docs.seedex.net/developer-guide/seedex-agent) covers building, linting, and the project structure.
## Contributing

Bug reports, suggestions, and pull requests are welcome. Open an issue or a pull request.

## License

AGPL-3.0.
