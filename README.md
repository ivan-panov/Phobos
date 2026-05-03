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

### Какие порты открыть на VPS

При установке можно выбрать, какой публичный адрес использовать для клиентов: IPv4 VPS или домен. Домен должен заранее указывать DNS A-записью на IPv4 VPS.

После установки Phobos использует два внешних порта:

```text
<HTTP_PORT>/tcp        - выдача клиентского установщика, например http://vpn.example.com:3485/init/<token>.sh
<OBFUSCATOR_PORT>/udp  - рабочий порт VPN-туннеля через wg-obfuscator
```

Пример команды клиента:

```bash
wget -qO- http://vpn.example.com:3485/init/deb790bbace89dbc20cf1d03be3aa5c1.sh | sh
```

Для такого примера на VPS или в панели хостинга нужно открыть минимум:

```bash
ufw allow 3485/tcp
ufw allow <OBFUSCATOR_PORT>/udp
```

Точный `OBFUSCATOR_PORT` показывает меню Phobos и команда выдачи ссылки клиенту. Порт WireGuard `51820/udp` наружу обычно открывать не нужно: он используется локально, а внешний трафик принимает `wg-obfuscator`.

Изменить адрес позже можно в меню `phobos` → настройки obfuscator → `Endpoint для клиентов`. После смены endpoint Phobos пересоберёт клиентские пакеты и новые ссылки будут использовать выбранный домен или IP.

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


## Каскад VPS1 → VPS2

Phobos поддерживает серверный каскад:

```text
клиент / роутер → VPS1 Phobos entry-node → VPS2 exit-node → интернет
```

Клиент продолжает подключаться только к VPS1 обычной командой установки. Внешние сайты будут видеть IP VPS2.

### Быстрая настройка каскада

1. Установите Phobos на VPS1 обычным способом.
2. На VPS1 откройте меню:

```bash
phobos
```

3. Перейдите в `Системные функции` → `Каскад VPS1 -> VPS2` → `Показать публичный ключ этого VPS`. Скопируйте ключ VPS1.
4. На VPS2 установите Phobos или хотя бы загрузите репозиторий Phobos, затем откройте меню `phobos` и выберите `Настроить этот VPS как VPS2 exit-node`. Вставьте публичный ключ VPS1.
5. VPS2 покажет свой публичный ключ. Вернитесь на VPS1 и выберите `Настроить этот VPS как VPS1 entry-node`. Укажите IP/домен VPS2, UDP-порт каскада и публичный ключ VPS2.

По умолчанию каскад использует:

```text
wg-exit интерфейс: wg-exit
сеть каскада: 10.77.0.0/30
порт каскада: 51830/udp
клиентская сеть Phobos: 10.25.0.0/16
таблица маршрутизации: phobos_exit / 77
```

На VPS2 нужно открыть порт каскада:

```bash
ufw allow 51830/udp
```

На VPS1 дополнительные внешние порты для каскада открывать не нужно. Policy routing настроен так, что через VPS2 уходит только клиентская сеть Phobos, а SSH, HTTP-установщик и obfuscator самого VPS1 остаются на обычном маршруте VPS1.

Проверка и отключение доступны в том же меню: `Статус каскада` и `Отключить каскад`.


## VPS1 → VPS2 через Xray/Remnawave

Альтернативный режим для схемы:

```text
клиент / роутер Keenetic → VPS1 Phobos → VPS2 Remnawave/Xray → интернет
```

В этом режиме Keenetic и VPS1 продолжают использовать обычный Phobos/WireGuard с `wg-obfuscator`. На VPS2 не нужен Phobos exit-node: VPS2 работает как Remnawave Node/Xray-сервер, а VPS1 запускает локальный Xray-клиент и прозрачно отправляет в него только трафик клиентской сети Phobos.

### Быстрая настройка

1. На VPS2 создайте пользователя/подписку в Remnawave и получите `vless://...` ссылку. Рекомендуемый профиль: VLESS + TCP + REALITY.
2. На VPS1 откройте меню:

```bash
phobos
```

3. Перейдите в `Системные функции` → `Выход VPS1 через VPS2 Xray/Remnawave` → `Настроить выход через VPS2 Remnawave`.
4. Вставьте VLESS-ссылку из Remnawave.

Скрипт на VPS1:

- устанавливает Xray-core, если он ещё не установлен;
- создаёт `/usr/local/etc/xray/config.json`;
- добавляет `dokodemo-door` TPROXY inbound на порт `12345`;
- добавляет тестовый SOCKS inbound `127.0.0.1:10808`;
- настраивает `iptables -t mangle` и policy routing так, чтобы только сеть клиентов Phobos `10.25.0.0/16` с интерфейса `wg0` уходила в Xray outbound на VPS2.

Проверка на VPS1:

```bash
/opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh status
/opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh test
```

Проверка с клиента за Keenetic:

```bash
curl -4 ifconfig.me
```

Должен отображаться IP VPS2.

Отключение:

```bash
/opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh disable
```

Этот режим не использует `wg-exit` и не требует открытия каскадного UDP-порта `51830` на VPS2. На VPS2 должны быть открыты только порты Remnawave/Xray inbound, например `443/tcp`, и служебный `NODE_PORT` только для IP панели Remnawave.

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
