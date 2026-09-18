<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center"><a href="README.md">English</a> | Русский</p>

# Seedex Agent

Seedex Agent – одна команда разворачивает на сервере с Ubuntu всё, к чему подключается роутер с [Seedex](https://github.com/aggnostos/seedex-openwrt): WireGuard, AmneziaWG, sing-box и Link API, из которого роутер забирает конфигурации. Клиентские конфиги — нативные файлы AmneziaWG и sing-box, поэтому тот же сервер можно использовать с обычными приложениями на любом устройстве.

## Требования

- Сервер на Ubuntu 24.04 с публичным IP-адресом и правами root.
- Роутер на [seedex-openwrt](https://github.com/aggnostos/seedex-openwrt) для соединения или любое устройство с приложением WireGuard, AmneziaWG или sing-box.

## Установка

### 1. Установите агент

На сервере запустите установщик от root:

```sh
wget -O - https://github.com/aggnostos/seedex-agent/releases/latest/download/install.sh | bash
```

Установщик скачивает последний релиз и ставит команду `sdx`, AmneziaWG, закреплённую версию sing-box и API link. Он генерирует ключи сервера, открывает порты и включает сервисы. Чтобы обновиться позже, запустите ту же команду ещё раз.

### 2. Запустите сервисы

```sh
sdx start
```

### 3. Добавьте прокси-протокол

Добавьте прокси-протоколы или VPN клиентов:
```sh
sdx proxy add vless 443
sdx vpn add awg router
sdx vpn add wg router
```

Протоколы: `vless`, `trojan`, `shadowsocks`, `shadowtls`, `vmess`, `hysteria2`, `tuic` и `anytls`. VPN-клиенты добавляются командой `sdx vpn add awg <name>` (AmneziaWG) или `sdx vpn add wg <name>` (WireGuard).

### 4. Добавьте роутер

```sh
sdx link add router
```

Команда печатает токен, отпечаток сертификата и одну строку для роутера. Дальше роутер забирает конфиги сам.

### 5. Проверьте статус

```
$ sdx

[*] VPN:
  Protocols:
    [*] awg       51821/udp
        router
    [*] wg       51820/udp
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

## Что дальше

- [Начало работы](https://docs.seedex.net/ru/getting-started) проводит через полную настройку, включая роутер.
- [Руководство по seedex-agent](https://docs.seedex.net/ru/user-guide/seedex-agent) описывает каждую команду `sdx` на сервере.
- [Для разработчиков](https://docs.seedex.net/ru/developer-guide/seedex-agent) рассказывает о сборке, линте и структуре проекта.

## Участие

Сообщения об ошибках, предложения и pull request'ы приветствуются.

## Лицензия

AGPL-3.0.
