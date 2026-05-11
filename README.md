# Phobos

**Phobos** — набор Bash-скриптов для автоматического развертывания WireGuard с обфускацией трафика через `wg-obfuscator`. Проект помогает поднять серверную часть на VPS, создать клиентов, выдать одноразовые установочные ссылки и настроить подключение на роутерах Keenetic/Netcraze, OpenWrt/ImmortalWrt и Linux-системах.

> Проект предназначен для администрирования собственных серверов и устройств. Используйте его только в рамках законов вашей юрисдикции и правил ваших провайдеров.

---

## Содержание

- [Возможности](#возможности)
- [Как это работает](#как-это-работает)
- [Структура репозитория](#структура-репозитория)
- [Поддерживаемые платформы](#поддерживаемые-платформы)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Установка на VPS](#установка-на-vps)
- [Управление через меню `phobos`](#управление-через-меню-phobos)
- [Управление клиентами](#управление-клиентами)
- [Установка клиента](#установка-клиента)
- [Настройка UFW](#настройка-ufw)
- [Настройка obfuscator](#настройка-obfuscator)
- [Xray → VPS2 Remnawave](#xray--vps2-remnawave)
- [Каскад VPS1 → VPS2](#каскад-vps1--vps2)
- [3x-ui режим](#3x-ui-режим)
- [Файлы и директории](#файлы-и-директории)
- [Службы systemd](#службы-systemd)
- [Безопасность](#безопасность)
- [Диагностика](#диагностика)
- [Удаление](#удаление)
- [Разработка и сборка](#разработка-и-сборка)
- [Лицензия](#лицензия)
- [Благодарности](#благодарности)
- [Поддержка автора](#поддержка-автора)

---

## Возможности

- Автоматическая установка WireGuard на VPS.
- Автоматическая установка и запуск `wg-obfuscator`.
- Генерация серверных и клиентских WireGuard-ключей.
- Генерация клиентских конфигураций и архивов установки.
- Одноразовые/временные HTTP-ссылки для установки клиентов.
- Интерактивное меню управления на VPS через команду `phobos`.
- Управление клиентами: создание, удаление, пересборка, проверка актуальности конфигурации, выдача ссылки.
- Автоматическая настройка клиентов:
  - Keenetic / Netcraze через Entware и RCI API;
  - OpenWrt / LEDE / ImmortalWrt через `opkg`, `uci` и firewall-зону;
  - Ubuntu / Debian через `apt-get` и `systemd`.
- Поддержка нескольких архитектур `wg-obfuscator`:
  - `x86_64`;
  - `mips`;
  - `mipsel`;
  - `aarch64`;
  - `armv7`.
- Настройка UFW-правил только для портов Phobos.
- Опциональная интеграция с Xray и Remnawave на второй VPS.
- Опциональный каскад WireGuard: клиенты → VPS1 → VPS2 → интернет.
- Автоматическое удаление устаревших токенов через cron.
- Скрипты удаления для VPS и клиентов.

---

## Как это работает

Базовая схема подключения:

```text
Client device
  └─ WireGuard client -> 127.0.0.1:<client_local_port>
      └─ local wg-obfuscator
          └─ internet UDP traffic with masking
              └─ VPS wg-obfuscator
                  └─ WireGuard wg0 on VPS
                      └─ internet through VPS NAT
```

По умолчанию WireGuard на клиенте подключается не напрямую к публичному IP VPS, а к локальному `wg-obfuscator` на `127.0.0.1`. Локальный obfuscator отправляет трафик на серверный obfuscator, а серверный obfuscator проксирует его в локальный WireGuard на VPS.

На VPS:

```text
Public UDP port -> wg-obfuscator -> 127.0.0.1:51820 -> wg0
```

Клиенты получают установочный архив по временной HTTP-ссылке. Архив содержит:

- WireGuard-конфиг клиента;
- конфиг `wg-obfuscator`;
- бинарники `wg-obfuscator` под разные архитектуры;
- установщик клиента;
- скрипт удаления;
- вспомогательные скрипты настройки роутеров и Linux.

---

## Структура репозитория

```text
Phobos/
├── phobos-deploy.sh
├── server/
│   └── scripts/
│       ├── lib-core.sh
│       ├── phobos-installer.sh
│       ├── phobos-menu.sh
│       ├── phobos-client.sh
│       ├── phobos-system.sh
│       ├── phobos-ufw.sh
│       ├── phobos-cascade.sh
│       ├── phobos-xray-remnawave.sh
│       ├── vps-obfuscator-config.sh
│       ├── vps-build-obfuscator.sh
│       └── vps-uninstall.sh
├── client/
│   └── templates/
│       ├── install-router.sh.template
│       ├── install-obfuscator.sh
│       ├── install-wireguard.sh
│       ├── lib-client.sh
│       ├── router-configure-wireguard.sh
│       ├── router-configure-wireguard-openwrt.sh
│       ├── 3xui.sh
│       └── phobos-uninstall.sh
└── wg-obfuscator/
    ├── bin/
    │   ├── wg-obfuscator-aarch64
    │   ├── wg-obfuscator-armv7
    │   ├── wg-obfuscator-mips
    │   ├── wg-obfuscator-mipsel
    │   └── wg-obfuscator-x86_64
    ├── build-all-architectures.sh
    ├── Makefile
    └── *.c / *.h
```

### Основные компоненты

| Компонент | Назначение |
|---|---|
| `phobos-deploy.sh` | Главный bootstrap-скрипт установки на VPS. |
| `phobos-installer.sh` | Настраивает зависимости, WireGuard, `wg-obfuscator`, HTTP-сервер и cron. |
| `phobos-menu.sh` | Интерактивная панель управления `phobos`. |
| `phobos-client.sh` | Создание, удаление, упаковка и выдача ссылок клиентам. |
| `phobos-system.sh` | Проверка состояния, очистка токенов, мониторинг клиентов. |
| `phobos-ufw.sh` | Открытие/закрытие UFW-правил Phobos. |
| `vps-obfuscator-config.sh` | Изменение портов, ключа, masking, dummy-параметров и WG-пула. |
| `phobos-xray-remnawave.sh` | Маршрутизация трафика клиентов через Xray и Remnawave. |
| `phobos-cascade.sh` | Настройка каскада VPS1 → VPS2 через WireGuard. |
| `vps-uninstall.sh` | Удаление Phobos с VPS. |
| `install-router.sh.template` | Основной клиентский установщик. |
| `3xui.sh` | Интеграция WireGuard-конфига в 3x-ui как Xray outbound. |
| `wg-obfuscator/` | Исходники, конфиги и готовые бинарники `wg-obfuscator`. |

---

## Поддерживаемые платформы

### VPS / сервер

Рекомендуется чистый VPS на:

- Ubuntu 20.04;
- Ubuntu 22.04;
- Ubuntu 24.04;
- Debian-подобной системе с `apt-get` и `systemd`.

> Установка на другие дистрибутивы может потребовать ручных правок. Автоматическая установка зависимостей реализована через `apt-get`.

### Клиенты

#### Роутеры

- Keenetic с Entware;
- Netcraze с Entware;
- OpenWrt;
- LEDE;
- ImmortalWrt.

#### Linux

- Ubuntu;
- Debian;
- Linux-системы с `systemd` и `apt-get`.

#### Специальный режим

- Серверы с установленной панелью 3x-ui.

В режиме 3x-ui Phobos не поднимает обычный WireGuard-интерфейс клиента. Вместо этого он устанавливает `wg-obfuscator` и добавляет WireGuard outbound в конфигурацию 3x-ui/Xray.

### Архитектуры клиентов

- `x86_64`;
- `mips`;
- `mipsel`;
- `aarch64` / `arm64`;
- `armv7` / `armv6l`.

---

## Требования

### Для VPS

- Root-доступ.
- Чистый Ubuntu/Debian VPS.
- Рабочий default route для NAT.
- Доступ в интернет для установки пакетов и загрузки зависимостей.
- Открытый входящий UDP-порт для `wg-obfuscator`.
- Открытый TCP-порт для временного HTTP-сервера установки клиентов.
- Не блокировать SSH при настройке firewall.

Скрипт устанавливает или использует:

- `git`;
- `wireguard` / `wireguard-tools`;
- `jq`;
- `curl`;
- `build-essential`;
- `ufw`;
- `iptables`;
- `nftables`;
- `darkhttpd`.

### Для Keenetic / Netcraze

- Установленный Entware.
- Доступ по SSH/терминалу Entware.
- Наличие `/opt/etc/init.d/rc.func`.
- Доступ к RCI API роутера через `http://localhost:79/rci/` для автоматической настройки WireGuard.
- Установленные или доступные через Entware утилиты: `curl`, `jq`, `tar`, `grep`, `cut`.

### Для OpenWrt / ImmortalWrt

- Root-доступ по SSH.
- `opkg`.
- `uci`.
- Доступные пакеты WireGuard:
  - `kmod-wireguard`;
  - `wireguard-tools`;
  - `luci-proto-wireguard`;
  - опционально `luci-app-wireguard`.

### Для Linux-клиента

- Root-доступ.
- Ubuntu/Debian.
- `systemd`.
- `apt-get`.

---

## Быстрый старт

### 1. Установить Phobos на VPS

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ivan-panov/Phobos/main/phobos-deploy.sh)" </dev/tty
```

Во время установки скрипт спросит:

1. имя первого клиента;
2. уровень маскировки трафика.

После завершения будет создан первый клиент и установлена команда управления:

```bash
sudo phobos
```

### 2. Открыть порты Phobos в UFW

Через меню:

```bash
sudo phobos
```

Далее:

```text
6) UFW / порты Phobos
1) Открыть порты Phobos
```

Или напрямую:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh open
```

### 3. Получить ссылку установки клиента

```bash
sudo phobos
```

Далее:

```text
1) Управление клиентами
6) Ссылка на установку
```

Команда будет выглядеть примерно так:

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sh
```

### 4. Запустить команду на клиентском устройстве

Keenetic / Netcraze / OpenWrt:

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sh
```

Linux:

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sudo sh
```

Если `curl` недоступен:

```bash
wget -O - http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sh
```

---

## Установка на VPS

### Автоматическая установка из GitHub

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ivan-panov/Phobos/main/phobos-deploy.sh)" </dev/tty
```

`</dev/tty` нужен, чтобы интерактивные вопросы работали корректно при запуске через `curl | bash`.

### Что делает установщик

1. Проверяет root-права.
2. Устанавливает `git`, если он отсутствует.
3. Клонирует репозиторий в `/opt/Phobos/repo` через sparse checkout.
4. Спрашивает имя первого клиента.
5. Спрашивает уровень маскировки.
6. Запускает серверный установщик.
7. Создает первого клиента.
8. Собирает пакет клиента.
9. Устанавливает команду `phobos`.

### Уровни маскировки

При установке можно выбрать уровень маскировки:

| Уровень | Название в меню | Длина ключа | `max-dummy` |
|---:|---|---:|---:|
| 1 | Легкая | 3 | 4 |
| 2 | Достаточная | 6 | 10 |
| 3 | Средняя | 20 | 20 |
| 4 | Выше среднего | 50 | 50 |
| 5 | Кошмар! | 255 | 100 |

Чем выше уровень, тем больше накладные расходы на трафик и CPU.

### Ручной запуск из локального клона

```bash
git clone https://github.com/ivan-panov/Phobos.git
cd Phobos
sudo ./phobos-deploy.sh
```

Или напрямую серверный установщик:

```bash
sudo ./server/scripts/phobos-installer.sh
```

---

## Управление через меню `phobos`

После установки на VPS доступна команда:

```bash
sudo phobos
```

Главное меню:

```text
1) Управление клиентами
2) Управление службами
3) Настройка Obfuscator
4) Xray -> VPS2 Remnawave
5) Системные функции
6) UFW / порты Phobos
0) Выход
```

### Управление клиентами

```text
1) Список клиентов
2) Создать клиента
3) Удалить клиента
4) Мониторинг (Live)
5) Пересоздать клиента
6) Ссылка на установку
```

### Управление службами

```text
1) WireGuard    - Запуск/Рестарт
2) WireGuard    - Стоп
3) WireGuard    - Логи
4) Obfuscator   - Запуск/Рестарт
5) Obfuscator   - Стоп
6) Obfuscator   - Логи
7) HTTP Server  - Запуск/Рестарт
8) HTTP Server  - Стоп
9) HTTP Server  - Логи
10) РЕСТАРТ ВСЕГО
11) СТОП ВСЕГО
```

### Системные функции

```text
1) Проверка состояния
2) Очистка токенов и временных файлов
3) Показать server.env
```

---

## Управление клиентами

Все операции с клиентами выполняет скрипт:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh <command>
```

### Команды

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh add <client_name> [ip]
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh remove <client_name>
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh list
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh package <client_name>
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh link <client_name> [ttl_seconds]
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh check <client_name>
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh rebuild <client_name>
```

### Создать клиента

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh add home-router
```

Скрипт:

- нормализует имя клиента;
- ищет свободный IPv4 в пуле WireGuard;
- при наличии IPv6 на VPS генерирует IPv6-адрес клиента;
- генерирует ключи WireGuard;
- создает WireGuard-конфиг клиента;
- создает конфиг `wg-obfuscator`;
- добавляет peer в `/etc/wireguard/wg0.conf`;
- применяет конфигурацию через `wg syncconf`;
- собирает клиентский архив;
- выдает временную ссылку установки.

### Создать клиента с заданным IP

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh add office-router 10.25.0.50
```

### Список клиентов

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh list
```

### Выдать ссылку установки

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh link home-router 86400
```

`86400` — TTL ссылки в секундах. Если TTL не указан, используется значение по умолчанию.

### Пересоздать клиента

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh rebuild home-router
```

Это удалит старые ключи/конфиги клиента, создаст новые и пересоберет пакет.

Используйте пересоздание, если менялись:

- публичный IP VPS;
- порт obfuscator;
- ключ obfuscator;
- WireGuard-пул;
- публичный ключ сервера;
- параметры dummy/idle.

---

## Установка клиента

Клиентский установщик сам определяет платформу и архитектуру.

### Keenetic / Netcraze

В терминале Entware:

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sh
```

Что делает установщик:

- определяет платформу как `keenetic`;
- выбирает директорию `/opt/etc/Phobos`;
- копирует `wg-obfuscator` в `/opt/bin`;
- создает init-скрипт `/opt/etc/init.d/S49wg-obfuscator`;
- запускает obfuscator;
- пытается автоматически создать WireGuard-интерфейс через RCI API;
- если автоматическая настройка не удалась, показывает инструкцию для ручного импорта WireGuard-конфига.

Автоматический интерфейс получает описание вида:

```text
Phobos-<client_name>
```

### OpenWrt / ImmortalWrt

По SSH на роутере:

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sh
```

Что делает установщик:

- определяет платформу как `openwrt`;
- выбирает директорию `/etc/Phobos`;
- устанавливает WireGuard-пакеты через `opkg`;
- копирует `wg-obfuscator` в `/usr/bin`;
- создает init-скрипт через Entware init или OpenWrt procd;
- запускает obfuscator;
- настраивает WireGuard-интерфейс через UCI;
- создает firewall-зону `phobos`;
- если автоматическая настройка не удалась, показывает инструкцию для ручной настройки через LuCI/UCI.

### Linux Ubuntu/Debian

```bash
curl -s http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh | sudo sh
```

Что делает установщик:

- определяет платформу как `linux`;
- выбирает директорию `/opt/Phobos`;
- устанавливает WireGuard через `apt-get`;
- копирует `wg-obfuscator` в `/usr/local/bin`;
- создает systemd service `phobos-obfuscator`;
- создает WireGuard-конфиг `/etc/wireguard/phobos.conf`;
- добавляет зависимость WireGuard от obfuscator;
- включает и запускает `wg-quick@phobos`.

На Linux-клиенте VPN настраивается как запасной маршрут: в конфиг добавляется `Table = off`, а маршрут к WireGuard-пулу добавляется через `PostUp`.

---

## Настройка UFW

Phobos включает отдельный скрипт для управления UFW-правилами:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh open
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh close
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh status
```

### Что открывается

Скрипт открывает только порты, которые использует Phobos:

| Порт | Протокол | Назначение |
|---:|---|---|
| `${OBFUSCATOR_PORT}` | UDP | Вход клиентов в серверный `wg-obfuscator`. |
| `${HTTP_PORT}` | TCP | Временный HTTP-сервер выдачи установочных пакетов. |
| `${TPROXY_PORT}` | TCP/UDP на `wg0` | Локальный вход клиентов WireGuard в Xray TPROXY, если включен Xray→Remnawave. |

Скрипт не трогает SSH-порт, чтобы не отрезать доступ к VPS.

Проверить текущие порты:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh status
```

---

## Настройка obfuscator

Интерактивная настройка доступна через меню:

```bash
sudo phobos
```

Далее:

```text
3) Настройка Obfuscator
```

Или напрямую:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-obfuscator-config.sh
```

Доступные действия:

```text
1) Применить шаблон уровня маскировки
2) Изменить порт obfuscator
3) Изменить локальный порт клиента
4) Изменить IP интерфейса
5) Изменить ключ obfuscator
6) Изменить masking
7) Изменить log level
8) Изменить idle timeout
9) Изменить max dummy
10) Изменить WireGuard pool
11) Изменить WireGuard listen port
12) Изменить публичный IP сервера
```

После изменения критичных параметров может потребоваться пересоздать клиентские пакеты и заново установить клиентов.

---

## Xray → VPS2 Remnawave

Phobos умеет отправлять трафик WireGuard-клиентов через Xray outbound, полученный из Remnawave-подписки.

Схема:

```text
Client -> Phobos WireGuard/wg-obfuscator -> Xray on Phobos VPS -> VPS2 Remnawave outbound -> internet
```

Настройка через меню:

```bash
sudo phobos
```

Далее:

```text
4) Xray -> VPS2 Remnawave
1) Настроить через URL подписки Remnawave
```

Настройка напрямую:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh configure "https://<remnawave-subscription-url>/json" vps2-remnawave
```

Полезные команды:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh refresh
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh enable
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh disable
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh status
sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh show-config
```

### Что делает скрипт

- Устанавливает зависимости.
- Устанавливает Xray Core через официальный установщик XTLS, если Xray отсутствует.
- Загружает Remnawave-подписку.
- Предпочитает Xray JSON-подписку.
- Если подписка содержит share-ссылки, пытается преобразовать первый поддерживаемый `vless://`, `vmess://` или `trojan://` outbound.
- Добавляет TPROXY inbound `phobos-tproxy`.
- Создает iptables mangle-правила только для трафика, входящего с `wg0`.
- Создает systemd service `phobos-xray-remnawave`.

Переменные окружения для настройки:

```bash
TPROXY_PORT=12345 TPROXY_MARK=1 TPROXY_TABLE=100 WG_IFACE=wg0 \
  sudo /opt/Phobos/repo/server/scripts/phobos-xray-remnawave.sh configure "https://<subscription>/json" vps2-remnawave
```

---

## Каскад VPS1 → VPS2

Скрипт `phobos-cascade.sh` позволяет настроить отдельный WireGuard-каскад:

```text
Clients -> VPS1 Phobos -> VPS2 exit-node -> internet
```

В этом режиме сайты будут видеть IP второго VPS.

Скрипт:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh <command>
```

Команды:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh key
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh entry
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh exit
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh status
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh disable
```

### Настройка VPS2 как exit-node

На VPS2:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh exit
```

Скрипт покажет публичный ключ VPS2. Его нужно указать на VPS1.

### Настройка VPS1 как entry-node

На VPS1:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-cascade.sh entry
```

Скрипт попросит:

- публичный IP или домен VPS2;
- UDP-порт каскада;
- публичный ключ VPS2.

По умолчанию используется:

| Параметр | Значение |
|---|---|
| Интерфейс | `wg-exit` |
| Порт | `51830/udp` |
| Сеть каскада | `10.77.0.0/30` |
| VPS1 IP | `10.77.0.1` |
| VPS2 IP | `10.77.0.2` |
| Клиентская сеть | `10.25.0.0/16` |
| Routing table | `phobos_exit` / `77` |

---

## 3x-ui режим

Если клиентский установщик запускается на Linux-системе и обнаруживает файл:

```text
/etc/x-ui/x-ui.db
```

он автоматически включает режим 3x-ui.

В этом режиме:

- WireGuard как системный `wg-quick` интерфейс не устанавливается;
- устанавливается и запускается только `wg-obfuscator`;
- WireGuard-конфиг преобразуется в Xray outbound;
- outbound `Phobos` добавляется в конфигурацию 3x-ui;
- скрипт `3xui.sh` сохраняется в `/opt/Phobos/3xui.sh` для повторной интеграции.

Проверка obfuscator:

```bash
sudo systemctl status phobos-obfuscator
```

WireGuard в этом режиме управляется через 3x-ui/Xray.

---

## Файлы и директории

### На VPS

| Путь | Назначение |
|---|---|
| `/opt/Phobos` | Основная директория Phobos. |
| `/opt/Phobos/repo` | Копия репозитория. |
| `/opt/Phobos/server/server.env` | Основные переменные сервера. |
| `/opt/Phobos/server/wg-obfuscator.conf` | Конфиг серверного obfuscator. |
| `/opt/Phobos/server/wg0-fw.sh` | Правила NAT/FORWARD для `wg0`. |
| `/opt/Phobos/clients/<client_id>` | Ключи, конфиги и metadata клиента. |
| `/opt/Phobos/packages` | Готовые `.tar.gz` пакеты клиентов. |
| `/opt/Phobos/tokens/tokens.json` | Активные токены установочных ссылок. |
| `/opt/Phobos/www` | Корень HTTP-сервера для выдачи пакетов. |
| `/opt/Phobos/bin` | Бинарники `wg-obfuscator` и `darkhttpd`. |
| `/etc/wireguard/wg0.conf` | Серверный WireGuard-конфиг. |
| `/usr/local/bin/phobos` | Ссылка на интерактивное меню. |

### На Keenetic / Netcraze

| Путь | Назначение |
|---|---|
| `/opt/etc/Phobos` | Конфиги и скрипты Phobos. |
| `/opt/bin/wg-obfuscator` | Бинарник obfuscator. |
| `/opt/etc/init.d/S49wg-obfuscator` | Init-скрипт obfuscator. |
| `/opt/etc/Phobos/phobos-uninstall.sh` | Скрипт удаления. |

### На OpenWrt / ImmortalWrt

| Путь | Назначение |
|---|---|
| `/etc/Phobos` | Конфиги и скрипты Phobos. |
| `/usr/bin/wg-obfuscator` | Бинарник obfuscator. |
| `/etc/init.d/phobos-obfuscator` | Procd init-скрипт. |
| `/etc/Phobos/phobos-uninstall.sh` | Скрипт удаления. |

### На Linux-клиенте

| Путь | Назначение |
|---|---|
| `/opt/Phobos` | Конфиги и скрипты Phobos. |
| `/usr/local/bin/wg-obfuscator` | Бинарник obfuscator. |
| `/etc/systemd/system/phobos-obfuscator.service` | Service obfuscator. |
| `/etc/wireguard/phobos.conf` | WireGuard-конфиг клиента. |
| `/etc/systemd/system/wg-quick@phobos.service.d/override.conf` | Зависимость WireGuard от obfuscator. |
| `/opt/Phobos/phobos-uninstall.sh` | Скрипт удаления. |

---

## Службы systemd

На VPS создаются службы:

```text
wg-quick@wg0.service
wg-obfuscator.service
phobos-http.service
```

Опционально:

```text
phobos-xray-remnawave.service
wg-quick@wg-exit.service
```

На Linux-клиенте:

```text
phobos-obfuscator.service
wg-quick@phobos.service
```

Проверка:

```bash
sudo systemctl status wg-quick@wg0
sudo systemctl status wg-obfuscator
sudo systemctl status phobos-http
```

Логи:

```bash
sudo journalctl -u wg-quick@wg0 -n 100 --no-pager
sudo journalctl -u wg-obfuscator -n 100 --no-pager
sudo journalctl -u phobos-http -n 100 --no-pager
```

---

## Безопасность

### Временные ссылки установки

Phobos выдает клиенту tokenized HTTP-ссылку вида:

```text
http://<VPS_PUBLIC_IP>:<HTTP_PORT>/init/<token>.sh
```

Токен имеет TTL. Устаревшие токены очищаются скриптом:

```bash
/opt/Phobos/repo/server/scripts/phobos-system.sh cleanup
```

Cron-задача создается автоматически:

```text
*/10 * * * * root /opt/Phobos/repo/server/scripts/phobos-system.sh cleanup
```

### Важные рекомендации

- Не публикуйте установочные ссылки в открытых чатах и issue.
- Не коммитьте содержимое `/opt/Phobos/clients`, `/opt/Phobos/tokens`, `/opt/Phobos/server/server.env`.
- Клиентские архивы содержат приватные ключи.
- После массовой выдачи клиентов можно остановить HTTP-сервер:

```bash
sudo systemctl stop phobos-http
```

- Перед включением UFW убедитесь, что SSH разрешен:

```bash
sudo ufw allow OpenSSH
sudo ufw status verbose
```

- `wg-obfuscator` маскирует WireGuard-трафик, но не является полноценной системой анонимности.

---

## Диагностика

### Проверить состояние Phobos

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-system.sh status
```

Или через меню:

```bash
sudo phobos
```

Далее:

```text
5) Системные функции
1) Проверка состояния
```

### Проверить WireGuard на VPS

```bash
sudo wg show wg0
ip addr show wg0
sudo systemctl status wg-quick@wg0
```

### Проверить obfuscator на VPS

```bash
sudo systemctl status wg-obfuscator
sudo journalctl -u wg-obfuscator -n 100 --no-pager
```

### Проверить HTTP-сервер установки

```bash
sudo systemctl status phobos-http
sudo journalctl -u phobos-http -n 100 --no-pager
```

Проверить порт:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh status
```

### Проверить клиента Linux

```bash
sudo systemctl status phobos-obfuscator
sudo systemctl status wg-quick@phobos
sudo wg show phobos
ip route
```

### Проверить клиента OpenWrt

```bash
/etc/init.d/phobos-obfuscator status
wg show
uci show network | grep phobos
uci show firewall | grep phobos
```

### Проверить клиента Keenetic / Entware

```bash
/opt/etc/init.d/S49wg-obfuscator status
ps | grep wg-obfuscator
```

### Частые проблемы

#### Клиентская ссылка не скачивается

Проверьте:

```bash
sudo systemctl status phobos-http
sudo /opt/Phobos/repo/server/scripts/phobos-ufw.sh status
```

Возможные причины:

- истек TTL токена;
- закрыт HTTP-порт;
- остановлен `phobos-http`;
- VPS-провайдер блокирует порт;
- клиент не может достучаться до публичного IP VPS.

#### WireGuard не поднимается на VPS

Проверьте:

```bash
sudo journalctl -xeu wg-quick@wg0.service
sudo iptables -t nat -S
sudo modprobe wireguard
```

#### Клиент не получает handshake

Проверьте:

```bash
sudo wg show wg0
sudo journalctl -u wg-obfuscator -n 100 --no-pager
```

Также проверьте, что:

- открыт UDP-порт `OBFUSCATOR_PORT`;
- клиент использует актуальный пакет;
- не менялся ключ obfuscator после создания клиента;
- на клиенте запущен локальный `wg-obfuscator`;
- WireGuard-клиент подключается к `127.0.0.1:<client_local_port>`.

#### После изменения порта или ключа старые клиенты не работают

Пересоздайте или пересоберите клиента и выдайте новую ссылку:

```bash
sudo /opt/Phobos/repo/server/scripts/phobos-client.sh rebuild <client_name>
```

---

## Удаление

### Удаление с VPS

Полное удаление:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-uninstall.sh
```

Удаление с сохранением данных клиентов:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-uninstall.sh --keep-data
```

### Удаление с Keenetic / Netcraze

```bash
/opt/etc/Phobos/phobos-uninstall.sh
```

### Удаление с OpenWrt / ImmortalWrt

```bash
/etc/Phobos/phobos-uninstall.sh
```

### Удаление с Linux-клиента

```bash
sudo /opt/Phobos/phobos-uninstall.sh
```

Скрипт удаления останавливает службы, удаляет конфиги, init/systemd-файлы, WireGuard-интерфейс и файлы Phobos.

---

## Разработка и сборка

### Локальная структура разработки

```bash
git clone https://github.com/ivan-panov/Phobos.git
cd Phobos
```

### Сборка wg-obfuscator

В репозитории уже есть готовые бинарники в `wg-obfuscator/bin/`.

Для пересборки используйте:

```bash
cd wg-obfuscator
./build-all-architectures.sh
```

Или установку серверного бинарника из уже собранных файлов:

```bash
sudo /opt/Phobos/repo/server/scripts/vps-build-obfuscator.sh
```

### Проверка Shell-скриптов

Рекомендуется проверять изменения через `shellcheck`:

```bash
shellcheck phobos-deploy.sh server/scripts/*.sh client/templates/*.sh
```

### Что не стоит коммитить

Не добавляйте в репозиторий сгенерированные данные:

```text
/opt/Phobos/server/server.env
/opt/Phobos/clients/*
/opt/Phobos/packages/*
/opt/Phobos/tokens/*
/etc/wireguard/*.conf
```

---

## GitHub About

Короткое описание для поля **About**:

```text
Автоматизация развертывания WireGuard с wg-obfuscator на VPS и клиентах: Keenetic/Netcraze, OpenWrt, ImmortalWrt, Ubuntu/Debian. Меню управления, клиенты, UFW, Xray/Remnawave.
```

Topics:

```text
wireguard vpn wg-obfuscator bash linux vps openwrt keenetic immortalwrt debian ubuntu xray remnawave ufw networking
```

---

## Лицензия

Проект распространяется под лицензией **GPL-3.0**.

См. файл [LICENSE](./LICENSE).

---

## Благодарности

- [ClusterM/wg-obfuscator](https://github.com/ClusterM/wg-obfuscator) — исходный проект `wg-obfuscator`.
- [Alexey Cluster](https://github.com/ClusterM) — автор и мейнтейнер исходного проекта.
- [WireGuard](https://www.wireguard.com/) — современный VPN-протокол.
- [Xray-core](https://github.com/XTLS/Xray-core) — Xray Core для расширенных сценариев маршрутизации.

---

## Поддержка автора

Угостить автора чашечкой какао можно на Boosty:

[https://boosty.to/ground_zerro](https://boosty.to/ground_zerro)
