#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib-core.sh"

set -euo pipefail

check_root
load_env
ensure_dirs

CMD="${1:-status}"
XRAY_META="$PHOBOS_DIR/server/xray-upstream.env"

# Defaults used by vps-xray-upstream.sh when xray-upstream.env does not exist yet.
DEFAULT_XRAY_WG_IFACE="wg0"
DEFAULT_XRAY_PROXY_PORT="12345"

if [[ -f "$XRAY_META" ]]; then
  # shellcheck disable=SC1090
  source "$XRAY_META"
fi

PHOBOS_HTTP_PORT="${HTTP_PORT:-80}"
PHOBOS_OBF_PORT="${OBFUSCATOR_PORT:-51821}"
PHOBOS_WG_ENDPOINT="${WG_LOCAL_ENDPOINT:-127.0.0.1:51820}"
XRAY_WG_IFACE_EFFECTIVE="${XRAY_WG_IFACE:-${WG_IFACE:-$DEFAULT_XRAY_WG_IFACE}}"
XRAY_PROXY_PORT_EFFECTIVE="${XRAY_TPROXY_PORT:-${TPROXY_PORT:-$DEFAULT_XRAY_PROXY_PORT}}"
XRAY_ENABLED="${XRAY_UPSTREAM_ENABLED:-0}"

require_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    die "ufw не установлен. Установите: apt-get install -y ufw"
  fi
}

ufw_is_active() {
  ufw status 2>/dev/null | grep -qi '^Status: active'
}

ufw_reload_if_active() {
  if ufw_is_active; then
    ufw reload >/dev/null
  else
    log_warn "UFW сейчас не активен. Правила добавлены/удалены, но применятся после: ufw enable"
  fi
}

ufw_status_text() {
  ufw status verbose 2>/dev/null || true
}

open_rule() {
  local description="$1"
  shift
  log_info "Открытие: $description"
  ufw allow "$@"
}

close_rule() {
  local description="$1"
  shift
  log_info "Закрытие: $description"
  ufw delete allow "$@" 2>/dev/null || log_warn "Правило не найдено: $description"
}

print_ports_plan() {
  echo "Порты Phobos:"
  echo "  ОТКРЫТЬ наружу:"
  echo "    - ${PHOBOS_OBF_PORT}/udp: вход клиентов в wg-obfuscator"
  echo "    - ${PHOBOS_HTTP_PORT}/tcp: HTTP-ссылки установки Phobos"
  echo "  ОТКРЫТЬ только на ${XRAY_WG_IFACE_EFFECTIVE}, если включен Xray upstream:"
  echo "    - ${XRAY_PROXY_PORT_EFFECTIVE}/tcp: локальный TPROXY вход Xray"
  echo "    - ${XRAY_PROXY_PORT_EFFECTIVE}/udp: локальный TPROXY вход Xray"
  echo "  НЕ ОТКРЫВАТЬ наружу:"
  echo "    - 51820/udp WireGuard, если endpoint ${PHOBOS_WG_ENDPOINT} локальный/за obfuscator"
  echo "    - 12346/tcp Xray keepalive SOCKS: только 127.0.0.1, наружу не нужен"
  echo ""
  echo "SSH-порт не трогаю, чтобы не отрезать доступ к VPS."
}

open_ports() {
  require_ufw
  print_ports_plan
  echo ""

  open_rule "Phobos Obfuscator ${PHOBOS_OBF_PORT}/udp" "${PHOBOS_OBF_PORT}/udp" comment "Phobos Obfuscator"
  open_rule "Phobos HTTP ${PHOBOS_HTTP_PORT}/tcp" "${PHOBOS_HTTP_PORT}/tcp" comment "Phobos HTTP"

  if [[ "$XRAY_ENABLED" == "1" || -f "$XRAY_META" ]]; then
    open_rule "Phobos Xray ${XRAY_WG_IFACE_EFFECTIVE} -> ${XRAY_PROXY_PORT_EFFECTIVE}/tcp" in on "$XRAY_WG_IFACE_EFFECTIVE" to any port "$XRAY_PROXY_PORT_EFFECTIVE" proto tcp comment "Phobos Xray"
    open_rule "Phobos Xray ${XRAY_WG_IFACE_EFFECTIVE} -> ${XRAY_PROXY_PORT_EFFECTIVE}/udp" in on "$XRAY_WG_IFACE_EFFECTIVE" to any port "$XRAY_PROXY_PORT_EFFECTIVE" proto udp comment "Phobos Xray"
  else
    log_warn "Xray upstream ещё не настроен; внутренние правила ${XRAY_PROXY_PORT_EFFECTIVE}/tcp+udp на ${XRAY_WG_IFACE_EFFECTIVE} пропущены."
  fi

  ufw_reload_if_active
  log_success "Порты Phobos открыты."
}

close_ports() {
  require_ufw

  echo "Будут закрыты правила UFW для Phobos:"
  echo "  - ${PHOBOS_OBF_PORT}/udp"
  echo "  - ${PHOBOS_HTTP_PORT}/tcp"
  echo "  - ${XRAY_PROXY_PORT_EFFECTIVE}/tcp на ${XRAY_WG_IFACE_EFFECTIVE}"
  echo "  - ${XRAY_PROXY_PORT_EFFECTIVE}/udp на ${XRAY_WG_IFACE_EFFECTIVE}"
  echo ""
  echo "SSH-порт не трогаю. Лишние старые порты 80/443/другие сервисы тоже не трогаю."
  echo ""

  close_rule "Phobos Obfuscator ${PHOBOS_OBF_PORT}/udp" "${PHOBOS_OBF_PORT}/udp"
  close_rule "Phobos HTTP ${PHOBOS_HTTP_PORT}/tcp" "${PHOBOS_HTTP_PORT}/tcp"
  close_rule "Phobos Xray ${XRAY_WG_IFACE_EFFECTIVE} -> ${XRAY_PROXY_PORT_EFFECTIVE}/tcp" in on "$XRAY_WG_IFACE_EFFECTIVE" to any port "$XRAY_PROXY_PORT_EFFECTIVE" proto tcp
  close_rule "Phobos Xray ${XRAY_WG_IFACE_EFFECTIVE} -> ${XRAY_PROXY_PORT_EFFECTIVE}/udp" in on "$XRAY_WG_IFACE_EFFECTIVE" to any port "$XRAY_PROXY_PORT_EFFECTIVE" proto udp

  ufw_reload_if_active
  log_success "Правила Phobos закрыты."
}

port_is_listening() {
  local proto="$1" port="$2"
  case "$proto" in
    tcp) ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$" ;;
    udp) ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$" ;;
    *) return 1 ;;
  esac
}

ufw_has_port_rule() {
  local proto="$1" port="$2"
  ufw_status_text | grep -Eiq "(^|[[:space:]])${port}/${proto}([[:space:]]|$)"
}

print_check_line() {
  local name="$1" proto="$2" port="$3" scope="$4"
  local listener="NO"
  local ufw_rule="NO"
  port_is_listening "$proto" "$port" && listener="YES"
  ufw_has_port_rule "$proto" "$port" && ufw_rule="YES"
  printf '  %-28s %-10s listener=%-3s ufw_rule=%-3s %s\n' "$name" "${port}/${proto}" "$listener" "$ufw_rule" "$scope"
}

check_ports() {
  require_ufw

  echo "=========================================="
  echo "  PHOBOS PORT CHECK"
  echo "=========================================="
  echo "UFW: $(ufw status 2>/dev/null | awk -F': ' '/^Status:/{print $2}' | head -1)"
  echo ""
  print_ports_plan
  echo ""
  echo "Проверка локального прослушивания и UFW-правил:"
  print_check_line "wg-obfuscator" udp "$PHOBOS_OBF_PORT" "public"
  print_check_line "phobos-http" tcp "$PHOBOS_HTTP_PORT" "public"
  if [[ "$XRAY_ENABLED" == "1" || -f "$XRAY_META" ]]; then
    print_check_line "xray-tproxy" tcp "$XRAY_PROXY_PORT_EFFECTIVE" "wg iface: ${XRAY_WG_IFACE_EFFECTIVE}"
    print_check_line "xray-tproxy" udp "$XRAY_PROXY_PORT_EFFECTIVE" "wg iface: ${XRAY_WG_IFACE_EFFECTIVE}"
  else
    echo "  xray-tproxy                 ${XRAY_PROXY_PORT_EFFECTIVE}/tcp+udp  skipped: Xray upstream not configured"
  fi
  echo ""
  echo "Важно: этот тест проверяет локальный listener и UFW. Firewall/security group у провайдера надо сверять в панели VPS."
}

status_ports() {
  require_ufw

  echo "== Используемые порты Phobos =="
  echo "Obfuscator: ${PHOBOS_OBF_PORT}/udp"
  echo "HTTP:       ${PHOBOS_HTTP_PORT}/tcp"
  if [[ "$XRAY_ENABLED" == "1" || -f "$XRAY_META" ]]; then
    echo "Xray:       ${XRAY_PROXY_PORT_EFFECTIVE}/tcp на ${XRAY_WG_IFACE_EFFECTIVE}"
    echo "Xray UDP:   ${XRAY_PROXY_PORT_EFFECTIVE}/udp на ${XRAY_WG_IFACE_EFFECTIVE}"
  else
    echo "Xray:       не настроен"
  fi
  echo "WireGuard:  ${PHOBOS_WG_ENDPOINT} — наружу не открывается, если 127.0.0.1"
  echo ""
  echo "== UFW status =="
  ufw status verbose
}

usage() {
  cat <<EOF_USAGE
Usage:
  $0 open     Открыть UFW-правила Phobos
  $0 close    Закрыть UFW-правила Phobos
  $0 status   Показать UFW и используемые порты
  $0 check    Проверить listener и UFW-правила портов
EOF_USAGE
}

case "$CMD" in
  open) open_ports ;;
  close) close_ports ;;
  status) status_ports ;;
  check|probe) check_ports ;;
  *) usage; exit 1 ;;
esac
