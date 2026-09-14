<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex" width="320">
  </picture>
</p>

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

Both come with the firewall, systemd units and log rotation taken care of.

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
  Logs:           /var/log/seedex-vpn/vpn.log (4.0K)

[*] Proxy:
  Protocols:
    anytls         8445/tcp
    hysteria2      8444/udp
    shadowtls      8443/tcp
    vless          443/tcp
  Logs:           /var/log/seedex-proxy/sing-box.log (672K)
```

## Install

You need a server running Ubuntu 24.04 with a public IP and root access.

```sh
git clone https://github.com/aggnostos/seedex-agent.git
cd seedex-agent
make install
```

This installs the `sdx` command, AmneziaWG and a pinned sing-box release,
generates the server keys, opens the ports and enables both services. Nothing
is started until you say so:

```sh
sdx start
sdx vpn add router
sdx proxy add vless 443
sdx export -o <dir>
```

## Router

`sdx export` writes native AmneziaWG and sing-box client configs.
[seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) takes them with
`sdx import`; phones and laptops take them with their usual apps.

## License

AGPL-3.0.
