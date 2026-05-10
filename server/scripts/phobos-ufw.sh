#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib-core.sh"

set -euo pipefail

check_root
load_env
ensure_dirs

CMD="${1:-status}"
XRAY_ENV="$PHOBOS_DIR/server/xray-remnawave.env"

# Defaults used by phobos-xray-remnawave.sh when xray-remnawave.env does not exist yet.
XRAY_WG_IFACE="wg0"
XRAY_PROXY_PORT="12345"

if [[ -f "$XRAY_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$XRAY_ENV"
  XRAY_WG_IFACE="${WG_IFACE:-$XRAY_WG_IFACE}"
  XRAY_PROXY_PORT="${TPROXY_PORT:-$XRAY_PROXY_PORT}"
fi

PHOBOS_HTTP_PORT="${HTTP_PORT:-80}"
PHOBOS_OBF_PORT="${OBFUSCATOR_PORT:-51821}"

require_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    die "ufw не установлен. Установите: apt-get install -y ufw"
  fi
}

ufw_reload_if_active() {
  if ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw reload >/dev/null
  else
    log_warn "UFW сейчас не активен. Правила добавлены/удалены, но применятся после: ufw enable"
  fi
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

open_ports() {
  require_ufw

  echo "Будут открыты только порты, которые использует Phobos:"
  echo "  - ${PHOBOS_OBF_PORT}/udp: вход клиентов в wg-obfuscator"
  echo "  - ${PHOBOS_HTTP_PORT}/tcp: HTTP-ссылки установки Phobos"
  echo "  - ${XRAY_PROXY_PORT}/tcp на ${XRAY_WG_IFACE}: локальный вход клиентов WireGuard в Xray"
  echo "  - ${XRAY_PROXY_PORT}/udp на ${XRAY_WG_IFACE}: UDP для Xray TPROXY, если используется"
  echo ""
  echo "SSH-порт не трогаю, чтобы не отрезать доступ к VPS."
  echo ""

  open_rule "Phobos Obfuscator ${PHOBOS_OBF_PORT}/udp" "${PHOBOS_OBF_PORT}/udp" comment "Phobos Obfuscator"
  open_rule "Phobos HTTP ${PHOBOS_HTTP_PORT}/tcp" "${PHOBOS_HTTP_PORT}/tcp" comment "Phobos HTTP"
  open_rule "Phobos Xray ${XRAY_WG_IFACE} -> ${XRAY_PROXY_PORT}/tcp" in on "$XRAY_WG_IFACE" to any port "$XRAY_PROXY_PORT" proto tcp comment "Phobos Xray"
  open_rule "Phobos Xray ${XRAY_WG_IFACE} -> ${XRAY_PROXY_PORT}/udp" in on "$XRAY_WG_IFACE" to any port "$XRAY_PROXY_PORT" proto udp comment "Phobos Xray"

  ufw_reload_if_active
  log_success "Порты Phobos открыты."
}

close_ports() {
  require_ufw

  echo "Будут закрыты правила UFW для Phobos:"
  echo "  - ${PHOBOS_OBF_PORT}/udp"
  echo "  - ${PHOBOS_HTTP_PORT}/tcp"
  echo "  - ${XRAY_PROXY_PORT}/tcp на ${XRAY_WG_IFACE}"
  echo "  - ${XRAY_PROXY_PORT}/udp на ${XRAY_WG_IFACE}"
  echo ""
  echo "SSH-порт не трогаю. Лишние старые порты 80/443/другие сервисы тоже не трогаю."
  echo ""

  close_rule "Phobos Obfuscator ${PHOBOS_OBF_PORT}/udp" "${PHOBOS_OBF_PORT}/udp"
  close_rule "Phobos HTTP ${PHOBOS_HTTP_PORT}/tcp" "${PHOBOS_HTTP_PORT}/tcp"
  close_rule "Phobos Xray ${XRAY_WG_IFACE} -> ${XRAY_PROXY_PORT}/tcp" in on "$XRAY_WG_IFACE" to any port "$XRAY_PROXY_PORT" proto tcp
  close_rule "Phobos Xray ${XRAY_WG_IFACE} -> ${XRAY_PROXY_PORT}/udp" in on "$XRAY_WG_IFACE" to any port "$XRAY_PROXY_PORT" proto udp

  ufw_reload_if_active
  log_success "Правила Phobos закрыты."
}

status_ports() {
  require_ufw

  echo "== Используемые порты Phobos =="
  echo "Obfuscator: ${PHOBOS_OBF_PORT}/udp"
  echo "HTTP:       ${PHOBOS_HTTP_PORT}/tcp"
  echo "Xray:       ${XRAY_PROXY_PORT}/tcp на ${XRAY_WG_IFACE}"
  echo "Xray UDP:   ${XRAY_PROXY_PORT}/udp на ${XRAY_WG_IFACE}"
  echo "WireGuard:  ${WG_LOCAL_ENDPOINT:-127.0.0.1:51820} — наружу не открывается, если 127.0.0.1"
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
EOF_USAGE
}

case "$CMD" in
  open) open_ports ;;
  close) close_ports ;;
  status) status_ports ;;
  *) usage; exit 1 ;;
esac
