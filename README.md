<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex" width="320">
  </picture>
</p>

<p align="center">English | <a href="README_RU.md">Русский</a></p>

Seedex Agent turns a plain Ubuntu server into the far end of a Seedex tunnel:
one command sets it up, one more issues a client config the router imports
as it is.

## Modules

**VPN.** An AmneziaWG server with obfuscation parameters generated for this
installation, so no two servers look alike on the wire. Clients are added and
revoked with a command; the running interface picks the change up at once.

**Proxy.** A sing-box server with any of the protocols it speaks — VLESS
Reality, Trojan, Shadowsocks, ShadowTLS, VMess, Hysteria2, TUIC, AnyTLS — each
on a port of your choice, with credentials generated per protocol and rotated
without touching the port.

**Link.** A small HTTPS API the router pairs with once and then pulls its
configs from on its own — a new client, a rotated credential or a new protocol
reaches the router without copying files, and the router picks which of the
configs it wants. Each router gets its own token; the certificate is pinned at
pairing.

All three come with the firewall, systemd units and log rotation taken care of.

## What it looks like

```
$ sdx
[*] VPN:
  Interface:      awg0
  Port:           51821/udp
  Clients:
    laptop
    phone
    router

[*] Proxy:
  Protocols:
    anytls         8445/tcp
    hysteria2      8444/udp
    shadowtls      8443/tcp
    vless          443/tcp

[*] Link:
  Port:           8447/tcp
  Fingerprint:    sha256//k3Xr…
  Routers:
    router
```

## Install

You need a server running Ubuntu 24.04 with a public IP and root access.

```sh
git clone https://github.com/aggnostos/seedex-agent.git
cd seedex-agent
make install
```

This installs the `sdx` command, AmneziaWG, a pinned sing-box release and the
link API, generates the server keys, opens the ports and enables the
services. Nothing is started until you say so:

```sh
sdx start
sdx proxy add vless 443
sdx link add router
```

The last command prints the token, the certificate fingerprint and the one
line to run on the router; from then on the router keeps its configs in sync
by itself.

## Router

[seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) pairs with the
link API, or takes the native AmneziaWG and sing-box client configs written by
`sdx export`; phones and laptops take those with their usual apps.

## License

AGPL-3.0.
