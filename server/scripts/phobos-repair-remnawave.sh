#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib-core.sh"

check_root
ensure_dirs
load_env

actual_obfuscator_port() {
  if [[ -f "$OBF_CONFIG" ]]; then
    awk -F= '/^[[:space:]]*source-lport[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$OBF_CONFIG"
  fi
}

sync_env_value() {
  local key="$1"
  local value="$2"
  if [[ -f "$SERVER_ENV" ]]; then
    grep -vE "^${key}=" "$SERVER_ENV" > "$SERVER_ENV.tmp" || true
    mv "$SERVER_ENV.tmp" "$SERVER_ENV"
  else
    : > "$SERVER_ENV"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$SERVER_ENV"
  chmod 600 "$SERVER_ENV"
}

print_header() {
  echo "=========================================="
  echo " Phobos Remnawave/Xray repair for Ubuntu 24.04"
  echo "=========================================="
}

print_header

actual_port="$(actual_obfuscator_port || true)"
if [[ -n "$actual_port" && "$actual_port" != "$OBFUSCATOR_PORT" ]]; then
  log_warn "server.env: OBFUSCATOR_PORT=$OBFUSCATOR_PORT, но wg-obfuscator.conf слушает $actual_port"
  log_info "Исправляю server.env на фактический порт $actual_port"
  sync_env_value OBFUSCATOR_PORT "$actual_port"
  OBFUSCATOR_PORT="$actual_port"
fi

if [[ -z "${OBFUSCATOR_PORT:-}" ]]; then
  die "Не найден OBFUSCATOR_PORT"
fi

if ! systemctl is-active --quiet wg-obfuscator; then
  log_warn "wg-obfuscator не запущен, запускаю"
  systemctl restart wg-obfuscator
else
  log_success "wg-obfuscator запущен"
fi

if ! ss -ulpn | grep -q ":$OBFUSCATOR_PORT "; then
  log_error "UDP $OBFUSCATOR_PORT не слушается. Логи: journalctl -u wg-obfuscator -n 80 --no-pager"
else
  log_success "Obfuscator слушает UDP $OBFUSCATOR_PORT"
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$OBFUSCATOR_PORT/udp" comment 'Phobos wg-obfuscator' >/dev/null || true
  ufw allow "${HTTP_PORT:-11144}/tcp" comment 'Phobos package HTTP' >/dev/null || true
  if ufw status | grep -qi '^Status: active'; then
    ufw reload >/dev/null || true
  fi
  log_success "UFW правила добавлены: UDP $OBFUSCATOR_PORT, TCP ${HTTP_PORT:-11144}"
fi

client_script="$SCRIPT_DIR/phobos-client.sh"
if [[ -x "$client_script" && -d "$CLIENTS_DIR" ]]; then
  for d in "$CLIENTS_DIR"/*; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    log_info "Обновляю пакет клиента $id под порт $OBFUSCATOR_PORT"
    "$client_script" package "$id" >/dev/null || log_warn "Не удалось обновить пакет $id"
  done
fi

if [[ -x "$SCRIPT_DIR/phobos-system.sh" ]]; then
  "$SCRIPT_DIR/phobos-system.sh" ports || true
fi

echo ""
echo "Проверь входящие пакеты так:"
echo "  sudo tcpdump -ni any udp port $OBFUSCATOR_PORT"
echo ""
echo "После переустановки клиента должно появиться:"
echo "  sudo wg show"
echo "  sudo iptables -t mangle -vnL PHOBOS_XRAY"
echo ""
echo "Важно: в firewall панели провайдера тоже открыть UDP $OBFUSCATOR_PORT и TCP ${HTTP_PORT:-11144}."
