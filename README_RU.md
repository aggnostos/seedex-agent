<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex" width="320">
  </picture>
</p>

<p align="center"><a href="README.md">English</a> | Русский</p>

Seedex Agent превращает обычный сервер на Ubuntu в дальний конец туннеля
Seedex: одна команда его настраивает, ещё одна выдаёт клиентский конфиг,
который роутер импортирует как есть.

## Модули

**VPN.** Сервер AmneziaWG с параметрами обфускации, сгенерированными для этой
установки, — на проводе никакие два сервера не выглядят одинаково. Клиенты
добавляются и отзываются командой; работающий интерфейс подхватывает
изменение сразу.

**Proxy.** Сервер sing-box с любым из протоколов, которые он умеет, — VLESS
Reality, Trojan, Shadowsocks, ShadowTLS, VMess, Hysteria2, TUIC, AnyTLS — каждый
на выбранном порту, с учётными данными, сгенерированными для каждого протокола
и ротируемыми без смены порта.

**Link.** Небольшой HTTPS API, с которым роутер соединяется один раз и дальше
сам забирает конфиги: новый клиент, ротированные учётные данные или новый
протокол доходят до роутера без копирования файлов, а роутер сам выбирает,
какие конфиги ему нужны. Роутер может и управлять здешним `sdx` — добавить
клиента, добавить протокол — не заходя на сервер. У каждого роутера свой
токен; сертификат закрепляется при соединении.

Все три модуля идут вместе с фаерволом, юнитами systemd и ротацией логов.

## Как это выглядит

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

## Установка

Нужен сервер на Ubuntu 24.04 с публичным IP и правами root.

```sh
git clone https://github.com/aggnostos/seedex-agent.git
cd seedex-agent
make install
```

Скрипт ставит команду `sdx`, AmneziaWG, закреплённую версию sing-box и API
link, генерирует ключи сервера, открывает порты и включает сервисы. Ничего не
запускается, пока вы не скажете:

```sh
sdx start
sdx proxy add vless 443
sdx link add router
```

Последняя команда печатает токен, отпечаток сертификата и одну строку для
роутера; после неё роутер сам держит конфиги в актуальном состоянии.

## Роутер

[seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) соединяется с
API link или принимает родные клиентские конфиги AmneziaWG и sing-box,
которые пишет `sdx export`; телефоны и ноутбуки берут те же файлы в своих
обычных приложениях.

## Лицензия

AGPL-3.0.
