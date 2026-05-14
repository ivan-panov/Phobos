# Phobos

Автоматизация развертывания защищенного WireGuard с обфускацией трафика через `wg-obfuscator`.

## Описание

**Phobos** — комплексное решение для автоматизации настройки обфусцированного WireGuard соединения между VPS сервером и клиентами. Включает серверные скрипты и клиентские установщики для роутеров (Keenetic/Netcraze, OpenWrt, ImmortalWrt) и Linux систем (Ubuntu/Debian).

### Основные компоненты

- **Серверная часть** - автоматизация развертывания WireGuard с обфускацией на VPS
- **Клиентская часть** - установщики для роутеров (Keenetic/Netcraze, OpenWrt, ImmortalWrt) и Linux систем
- **Интеграция с 3x-ui** - поддержка установки только obfuscator для работы с панелью 3x-ui

## Быстрый старт

### 1. Установка на VPS

Запустите установку:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ivan-panov/Phobos/main/phobos-deploy.sh)" </dev/tty
```

### 2. Установка на клиенте

**Keenetic/Netcraze/ImmortalWrt** (терминал Entware):
```bash
wget -O - http://<server_ip>:8080/init/<token>.sh | sh
```

**OpenWrt** (SSH):
```bash
wget -O - http://<server_ip>:8080/init/<token>.sh | sh
```

**Linux (Ubuntu/Debian)** (SSH или терминал):
```bash
wget -O - http://<server_ip>:8080/init/<token>.sh | sudo sh
```

<details>
  <summary>Подробней</summary>

  Скрипт автоматически определяет платформу и архитектуру, устанавливает wg-obfuscator, настраивает автозапуск, конфигурирует WireGuard, активирует подключение, развёртывает скрипты health-check и uninstall.

  **Keenetic/Netcraze:** настройка через RCI API, интерфейс `Phobos-{client_name}`
  **OpenWrt/ImmortalWrt:** установка kmod-wireguard, wireguard-tools, luci-app-wireguard; настройка через UCI, интерфейс `phobos_wg`, firewall зона `phobos`
  **Linux:** установка через apt-get и systemd, интерфейс `phobos`, VPN как запасной интерфейс (`Table = off`). При обнаружении 3x-ui — только obfuscator через 3xui.sh.
</details>

## Управление системой

### Интерактивное меню на VPS

Меню на VPS вызывается командой:
```
phobos
```

**Основные возможности меню:**
- Управление сервисами (start/stop/status/logs для WireGuard, obfuscator, HTTP сервера)
- Управление клиентами (создание, удаление, пересоздание конфигураций)
- Системные функции (health checks, мониторинг клиентов, очистка токенов)
- Настройка параметров obfuscator (порты, ключи, уровни маскировки, пул адресов)


## VPS1 -> VPS2 Remnawave via Xray

Phobos can route traffic from WireGuard clients through a second VPS managed by Remnawave. The topology is:

```text
Client/router -> VPS1 Phobos WireGuard/wg-obfuscator -> local Xray on VPS1 -> VPS2 Remnawave outbound -> Internet
```

Run this on **VPS1** after the normal Phobos installation. VPS2 is the Remnawave/Xray server from the subscription URL; Phobos does not install anything on VPS2 in this mode. Use the real **user subscription URL** from Remnawave, not the admin panel URL and not the literal placeholder below. The script now sends a normal `v2rayNG/1.10.5` User-Agent, adds a stable `x-hwid` header, and automatically retries the explicit `/json` endpoint when the bare URL returns HTML/fallback content.

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh configure "https://sub.example.com/<shortUuid>" vps2-remnawave

# Or force Xray JSON explicitly:
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh configure "https://sub.example.com/<shortUuid>/json" vps2-remnawave

# If Remnawave HWID is enabled and you want a specific device id:
sudo REMNAWAVE_HWID="phobos-vps1-main" /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh configure "https://sub.example.com/<shortUuid>/json" vps2-remnawave
```

Useful commands:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh status
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh test
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh refresh
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh disable
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh enable
```

The script prefers a Remnawave Xray JSON subscription. If the URL returns base64/plain share links, the first supported `vless://`, `vmess://`, `trojan://`, or `ss://` link is converted into an Xray outbound. Routing is done on VPS1 with an Xray TPROXY inbound and iptables mangle rules applied only to traffic entering from `wg0`. A local SOCKS test inbound is also bound to `127.0.0.1:10808`; it is not exposed publicly and exists only so `phobos-xray-remnawave.sh test` can force a real VPS1 -> Xray -> Remnawave/VPS2 request. A fail-closed kill-switch blocks direct `wg0 -> VPS1 WAN` forwarding, so if Xray/VPS2 is unavailable, client traffic fails instead of leaking through the VPS1 public IP.

Remnawave showing `Не подключался` only means the user has not made a real Xray connection yet. Fetching the subscription URL alone does not count as a connection. Run the `test` command above or send traffic from a WireGuard client through VPS1, then refresh the Remnawave page.

The same workflow is available in the `phobos` menu: `VPS1 -> VPS2 Remnawave via Xray`.

## Удаление

### Удаление с VPS сервера

Для полного удаления Phobos с VPS сервера:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-uninstall.sh
```

Для сохранения резервной копии данных клиентов:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-uninstall.sh --keep-data
```

### Удаление с клиента

**Keenetic/Netcraze:**
```bash
/opt/etc/Phobos/phobos-uninstall.sh
```

**OpenWrt/ImmortalWrt:**
```bash
/etc/Phobos/phobos-uninstall.sh
```

**Linux (Ubuntu/Debian):**
```bash
sudo /opt/Phobos/phobos-uninstall.sh
```

<details>
  <summary>Подробней</summary>

  Скрипт остановит obfuscator и WireGuard, удалит интерфейс, бинарники, конфигурационные файлы и init-скрипт / systemd сервис.

  **Keenetic/Netcraze:** удаление интерфейсов через RCI API, сохранение конфигурации роутера
  **OpenWrt/ImmortalWrt:** удаление через UCI, firewall зоны `phobos`, сохранение конфигурации роутера
  **Linux:** удаление `/usr/local/bin/wg-obfuscator`, `/opt/Phobos`, `/etc/wireguard/phobos.conf`
</details>

## Совместимость и поддерживаемые платформы

### Сервер (VPS)
Протестированно и рекомендуется к использованию на **Ubuntu 20/22/24.04**.
Желательна установка на **чистый VPS** без предварительно установленных сервисов или конфигураций.
> Совместимость с другими дистрибутивами Linux и сторонними сервисами **не проверялась**.

### Клиенты

**Роутеры:**
- **Keenetic** (все модели с Entware) - mipsel, aarch64, mips
- **Netcraze** (устройства Keenetic под другой маркой) - mipsel, aarch64, mips
- **OpenWrt/LEDE** - mipsel, mips, aarch64, armv7, x86_64
- **ImmortalWrt** - форк OpenWrt с дополнительными возможностями

**Linux системы:**
- **Ubuntu/Debian** - стандартная установка WireGuard + obfuscator
- **Системы с 3x-ui панелью** - автоматическое определение и установка только obfuscator

**Поддерживаемые архитектуры:**
- x86_64 (VPS, PC-роутеры)
- mipsel (большинство Keenetic, бюджетные TP-Link)
- mips (старые модели TP-Link, D-Link)
- aarch64 (современные Keenetic, Linksys, Netgear)
- armv7 (GL.iNet, Raspberry Pi 2/3)

## License

This project is licensed under GPL-3.0.
See the [LICENSE](./LICENSE) file for full terms.

## Благодарности

- [ClusterM/wg-obfuscator](https://github.com/ClusterM/wg-obfuscator) — инструмент обфускации WireGuard трафика /[Поблагадарить Алексея и поддержать его разработку](https://boosty.to/cluster)/
- [WireGuard](https://www.wireguard.com/) — современный VPN протокол

## Поддержка

**Угостить автора чашечкой какао можно на** [Boosty](https://boosty.to/ground_zerro) ❤️
