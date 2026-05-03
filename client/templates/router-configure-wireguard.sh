#!/bin/sh
set -e

RCI_URL="http://localhost:79/rci/"
MAX_INTERFACE_NUM=9

check_dependencies() {
    local missing=""

    for cmd in curl jq date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: Missing required utilities:$missing" >&2
        echo "Please install them using: opkg update && opkg install$missing" >&2
        return 1
    fi

    return 0
}

CLIENT_NAME=""
PHOBOS_PROFILE="phobos"
CLIENT_PRIVATE_KEY=""
CLIENT_IP=""
CLIENT_IPV6=""
SERVER_PUBLIC_KEY=""
ENDPOINT_PORT=13255
KEEPALIVE=25
MTU=1420
FALLBACK_CONFIG=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    log "ERROR: $*"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --client-name NAME          Client name (required)
  --interface-name NAME       Phobos profile/interface label (default: phobos)
  --client-private-key KEY    WireGuard private key (required)
  --client-ip IP              Client tunnel IPv4 address (required)
  --client-ipv6 IP            Client tunnel IPv6 address (optional, use none to disable)
  --server-public-key KEY     Server WireGuard public key (required)
  --endpoint-port PORT        Local obfuscator port (default: 13255)
  --keepalive SECONDS         Keepalive interval (default: 25)
  --mtu MTU                   Interface MTU (default: 1420)
  --fallback-config PATH      Path to fallback .conf file
  --help                      Show this help

Example:
  $0 --client-name Pegacomp \\
     --client-private-key "ABCD..." \\
     --client-ip 10.25.0.4 \\
     --client-ipv6 fd00:10:25::4 \\
     --server-public-key "EFGH..." \\
     --endpoint-port 13255 \\
     --fallback-config /opt/etc/Phobos/Pegacomp.conf

EOF
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --client-name)
                CLIENT_NAME="$2"
                shift 2
                ;;
            --interface-name)
                PHOBOS_PROFILE="$2"
                shift 2
                ;;
            --client-private-key)
                CLIENT_PRIVATE_KEY="$2"
                shift 2
                ;;
            --client-ip)
                CLIENT_IP="$2"
                shift 2
                ;;
            --client-ipv6)
                CLIENT_IPV6="$2"
                shift 2
                ;;
            --server-public-key)
                SERVER_PUBLIC_KEY="$2"
                shift 2
                ;;
            --endpoint-port)
                ENDPOINT_PORT="$2"
                shift 2
                ;;
            --keepalive)
                KEEPALIVE="$2"
                shift 2
                ;;
            --mtu)
                MTU="$2"
                shift 2
                ;;
            --fallback-config)
                FALLBACK_CONFIG="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [ -z "${CLIENT_NAME}" ] || [ -z "${CLIENT_PRIVATE_KEY}" ] || \
       [ -z "${CLIENT_IP}" ] || [ -z "${SERVER_PUBLIC_KEY}" ]; then
        error "Missing required parameters"
        usage
    fi
}

find_phobos_interface() {
    local target_desc="$1"

    log "Поиск существующего интерфейса Phobos: ${target_desc}..." >&2

    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        local interface_json=$(curl -s "${RCI_URL}show/rc/interface/Wireguard${i}" 2>/dev/null)

        if [ -n "${interface_json}" ] && echo "${interface_json}" | jq -e . >/dev/null 2>&1; then
            local desc=$(echo "${interface_json}" | jq -r '.description // empty' 2>/dev/null)
            if [ "${desc}" = "${target_desc}" ]; then
                log "Найден существующий интерфейс: Wireguard${i}" >&2
                echo "Wireguard${i}"
                return 0
            fi
        fi
    done

    log "Существующий интерфейс Phobos не найден" >&2
    echo ""
    return 0
}

find_free_wireguard_interface() {
    log "Поиск свободного интерфейса WireGuard..." >&2

    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        local interface_json=$(curl -s "${RCI_URL}show/interface/Wireguard${i}" 2>/dev/null)

        if [ -z "${interface_json}" ] || ! echo "${interface_json}" | jq -e '.id' >/dev/null 2>&1; then
            log "Найден свободный интерфейс: Wireguard${i}" >&2
            echo "Wireguard${i}"
            return 0
        fi
    done

    error "Нет свободных интерфейсов WireGuard (0-${MAX_INTERFACE_NUM})"
    return 1
}

remove_wireguard_interface() {
    local interface_name="$1"

    log "Удаление существующего интерфейса: ${interface_name}..."

    if command -v ndmc >/dev/null 2>&1; then
        if ndmc -c "no interface ${interface_name}" >/dev/null 2>&1; then
            log "Интерфейс ${interface_name} успешно удален ✓"
            return 0
        else
            log "Предупреждение: не удалось удалить интерфейс через ndmc"
            return 1
        fi
    else
        log "Предупреждение: команда ndmc не найдена"
        return 1
    fi
}

configure_wireguard_interface() {
    local interface_name="$1"

    local description="Phobos-${CLIENT_NAME}"
    local client_ip_addr=$(echo "${CLIENT_IP}" | cut -d'/' -f1)
    local client_ipv6_block="${CLIENT_IPV6}"

    log "Настройка интерфейса ${interface_name}..."

    local ipv6_json=""
    local allow_ips_json='{
                "address": "0.0.0.0",
                "mask": "0.0.0.0"
              }'

    if [ "${client_ipv6_block}" != "none" ] && [ -n "${client_ipv6_block}" ]; then
        ipv6_json=',
      "ipv6": {
        "address": [
          {"auto": false},
          {"block": "'"${client_ipv6_block}"'"}
        ],
        "prefix": [
          {"auto": false}
        ]
      }'
        allow_ips_json="${allow_ips_json},
              {
                "address": "::",
                "mask": "0"
              }"
    fi

    local config_json=$(cat <<EOF
{
  "interface": {
    "${interface_name}": {
      "description": "${description}",
      "security-level": {
        "public": true
      },
      "ip": {
        "address": {
          "address": "${client_ip_addr}",
          "mask": "255.255.255.255"
        },
        "mtu": ${MTU},
        "global": true,
        "defaultgw": false,
        "priority": 26622,
        "tcp": {
          "adjust-mss": {
            "pmtu": true
          }
        }
      }${ipv6_json},
      "wireguard": {
        "private-key": "${CLIENT_PRIVATE_KEY}",
        "peer": [
          {
            "key": "${SERVER_PUBLIC_KEY}",
            "comment": "Phobos VPS Server",
            "endpoint": {
              "address": "127.0.0.1:${ENDPOINT_PORT}"
            },
            "keepalive-interval": {
              "interval": ${KEEPALIVE}
            },
            "allow-ips": [
              ${allow_ips_json}
            ]
          }
        ]
      },
      "up": true
    }
  }
}
EOF
)

    local result=$(echo "${config_json}" | curl -s -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "${RCI_URL}" 2>/dev/null)

    if echo "${result}" | jq -e '.status == "error"' >/dev/null 2>&1; then
        local error_msg=$(echo "${result}" | jq -r '.message // "Unknown error"' 2>/dev/null)
        error "RCI API отклонил конфигурацию: ${error_msg}"
        log "JSON запрос:"
        log "${config_json}"
        return 1
    fi

    log "Интерфейс ${interface_name} создан ✓"

    return 0
}

save_configuration() {
    log "Сохранение конфигурации..."

    local result=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"system":{"configuration":{"save":{}}}}' \
        "${RCI_URL}" 2>/dev/null)

    if echo "${result}" | grep -q '"status"[[:space:]]*:[[:space:]]*"message"'; then
        log "Конфигурация сохранена ✓"
        return 0
    else
        error "Ошибка сохранения конфигурации"
        return 1
    fi
}

verify_interface_created() {
    local interface_description="$1"

    log "Проверка создания интерфейса WireGuard..."

    local interfaces=$(curl -s "http://127.0.0.1:79/rci/show/interface" 2>/dev/null || echo "")

    if [ -z "$interfaces" ]; then
        error "Не удалось получить список интерфейсов через RCI API"
        return 1
    fi

    if ! echo "$interfaces" | jq -e . >/dev/null 2>&1; then
        error "Некорректный JSON ответ от RCI API"
        return 1
    fi

    local found=$(echo "$interfaces" | jq -r --arg desc "$interface_description" 'to_entries[] | select(.value.description == $desc) | .key' 2>/dev/null)

    if [ -n "$found" ]; then
        log "✓ Интерфейс $found ($interface_description) успешно создан"
        return 0
    else
        error "Интерфейс с description '$interface_description' не найден"
        return 1
    fi
}

show_fallback_instructions() {
    cat <<EOF

╔════════════════════════════════════════════════════════════╗
║  RCI API недоступен - требуется ручная настройка          ║
╚════════════════════════════════════════════════════════════╝

Конфигурация сохранена в: ${FALLBACK_CONFIG}

Инструкция по ручному импорту:
1. Откройте веб-панель Keenetic (http://192.168.1.1 или http://my.keenetic.net)
2. Перейдите: Интернет → WireGuard
3. Нажмите: 'Добавить подключение'
4. Выберите: 'Загрузить конфигурацию из файла'
5. Укажите путь: ${FALLBACK_CONFIG}
6. Активируйте подключение

EOF
}

main() {
    parse_args "$@"

    if ! check_dependencies; then
        exit 1
    fi

    mkdir -p /opt/etc/Phobos
    PROFILE_DESCRIPTION="Phobos-${CLIENT_NAME}"

    log "=== Phobos WireGuard RCI Configuration ==="
    log "Клиент: ${CLIENT_NAME}"
    log "Профиль: ${PHOBOS_PROFILE}"

    EXISTING_INTERFACE=$(find_phobos_interface "${PROFILE_DESCRIPTION}") || true

    if [ -n "${EXISTING_INTERFACE}" ]; then
        log "Обнаружен существующий интерфейс: ${EXISTING_INTERFACE}"
        if remove_wireguard_interface "${EXISTING_INTERFACE}"; then
            log "Интерфейс ${EXISTING_INTERFACE} удален, будет создан заново"
        else
            log "Не удалось удалить интерфейс ${EXISTING_INTERFACE}, попытка пересоздать"
        fi
    fi

    INTERFACE_NAME=$(find_free_wireguard_interface) || true
    if [ -z "${INTERFACE_NAME}" ]; then
        show_fallback_instructions
        exit 1
    fi
    log "Создание нового интерфейса: ${INTERFACE_NAME}"

    if ! configure_wireguard_interface "${INTERFACE_NAME}"; then
        error "Не удалось настроить WireGuard через RCI API"
        show_fallback_instructions
        exit 1
    fi

    if ! save_configuration; then
        error "Не удалось сохранить конфигурацию"
        exit 1
    fi

    log "Настройка WireGuard завершена успешно! ✓"
    log "Интерфейс: ${INTERFACE_NAME}"
    log "Description: ${PROFILE_DESCRIPTION}"

    log ""
    log "Проверка статуса wg-obfuscator..."
    if [ -f /opt/etc/init.d/S49wg-obfuscator ]; then
        local obf_status=$(/opt/etc/init.d/S49wg-obfuscator status 2>&1)
        if echo "${obf_status}" | grep -q "dead"; then
            log "⚠ wg-obfuscator остановлен, перезапускаем..."
            /opt/etc/init.d/S49wg-obfuscator start
            sleep 2
            log "✓ wg-obfuscator перезапущен"
        else
            log "✓ wg-obfuscator работает"
        fi
    fi

    log ""
    log "Ожидание применения конфигурации..."
    sleep 5

    if verify_interface_created "${PROFILE_DESCRIPTION}"; then
        log ""
        log "╔════════════════════════════════════════════════════════════╗"
        log "║  WireGuard успешно настроен!                              ║"
        log "╚════════════════════════════════════════════════════════════╝"
        log ""
        exit 0
    else
        log ""
        log "⚠ Не удалось подтвердить создание интерфейса WireGuard"
        log ""
        log "Проверьте вручную в веб-панели Keenetic:"
        log "  Интернет → WireGuard"
        log ""
        exit 1
    fi
}

main "$@"
