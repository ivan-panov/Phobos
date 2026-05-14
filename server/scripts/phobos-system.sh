#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib-core.sh"

check_root
load_env
ensure_dirs

CMD="${1:-status}"

action_status() {
  log_info "Проверка состояния системы..."
  
  # Services
  local errors=0
  for svc in wg-quick@wg0 wg-obfuscator phobos-http; do
     if systemctl is-active --quiet "$svc"; then
        log_success "Служба $svc активна"
     else
        log_error "Служба $svc ОСТАНОВЛЕНА"
        errors=$((errors + 1))
     fi
  done

  if [[ -f "$PHOBOS_DIR/server/xray-upstream.json" ]]; then
     if systemctl is-active --quiet phobos-xray-upstream; then
        log_success "Служба phobos-xray-upstream активна"
     else
        log_error "Служба phobos-xray-upstream ОСТАНОВЛЕНА"
        errors=$((errors + 1))
     fi
     if iptables -t mangle -S PHOBOS_XRAY >/dev/null 2>&1; then
        log_success "TPROXY правила Xray upstream активны"
     else
        log_error "TPROXY правила Xray upstream не найдены"
        errors=$((errors + 1))
     fi
  fi
  
  # Ports
  if ss -ulpn | grep -q ":$OBFUSCATOR_PORT "; then
     log_success "Порт Obfuscator ($OBFUSCATOR_PORT/udp) прослушивается"
  else
     log_error "Порт Obfuscator НЕ доступен"
     errors=$((errors + 1))
  fi
  
  if ss -tlpn | grep -q ":$HTTP_PORT "; then
     log_success "Порт HTTP ($HTTP_PORT/tcp) прослушивается"
  else
     log_error "Порт HTTP НЕ доступен"
     errors=$((errors + 1))
  fi

  # Disk
  local free_mb=$(df -m / | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt 500 ]]; then
     log_warn "Мало места на диске: ${free_mb}MB"
  else
     log_success "Свободное место: ${free_mb}MB"
  fi
  
  if [[ "$errors" -eq 0 ]]; then
     echo "Система работает нормально."
  else
     echo "Обнаружены проблемы ($errors)."
     exit 1
  fi
}

action_cleanup() {
  log_info "Очистка системы..."
  local now=$(date +%s)
  
  # 1. Tokens
  if [[ -f "$TOKENS_FILE" ]] && command -v jq >/dev/null; then
     local expired=$(jq -r ".[] | select(.expires < $now) | .token" "$TOKENS_FILE")
     for t in $expired; do
        log_info "Удаление просроченного токена: $t"
        rm -f "$WWW_DIR/init/$t.sh"
        rm -rf "$WWW_DIR/packages/$t"
     done
     # Update JSON
     jq "[.[] | select(.expires >= $now)]" "$TOKENS_FILE" > "$TOKENS_FILE.tmp" && mv "$TOKENS_FILE.tmp" "$TOKENS_FILE"
  fi
  
  if [[ -d "$WWW_DIR/packages" ]]; then
     for d in "$WWW_DIR/packages"/*; do
        if [[ -d "$d" ]]; then
           local t=$(basename "$d")
           local in_json=false
           if [[ -f "$TOKENS_FILE" ]]; then
              in_json=$(jq -r --arg t "$t" 'map(select(.token == $t)) | length > 0' "$TOKENS_FILE" 2>/dev/null || echo false)
           fi
           if [[ "$in_json" == "false" ]]; then
              log_warn "Найден осиротевший каталог: $t"
              rm -rf "$d"
              rm -f "$WWW_DIR/init/$t.sh"
           fi
        fi
     done
  fi
  
  log_success "Очистка завершена."
}


actual_obfuscator_port() {
  if [[ -f "$OBF_CONFIG" ]]; then
    awk -F= '/^[[:space:]]*source-lport[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$OBF_CONFIG"
  fi
}

write_firewall_ports_file() {
  load_env
  local actual_port
  actual_port=$(actual_obfuscator_port)
  [[ -n "$actual_port" ]] && OBFUSCATOR_PORT="$actual_port"
  cat > "$PHOBOS_DIR/server/firewall-ports.txt" <<EOF
Phobos firewall ports
=====================

Open these ports on the VPS firewall and in the provider security group:

1) ${OBFUSCATOR_PORT}/udp  - main client connection port (wg-obfuscator)
2) ${HTTP_PORT}/tcp        - HTTP package/download server

Do NOT expose 51820/udp to the Internet. WireGuard is behind wg-obfuscator.

UFW commands:
  sudo ufw allow ${OBFUSCATOR_PORT}/udp comment 'Phobos wg-obfuscator'
  sudo ufw allow ${HTTP_PORT}/tcp comment 'Phobos package HTTP'
  sudo ufw reload

Provider firewall/security group:
  UDP ${OBFUSCATOR_PORT}
  TCP ${HTTP_PORT}
EOF
}

action_ports() {
  load_env
  local actual_port
  actual_port=$(actual_obfuscator_port)
  if [[ -n "$actual_port" && "$actual_port" != "$OBFUSCATOR_PORT" ]]; then
    log_warn "server.env содержит OBFUSCATOR_PORT=$OBFUSCATOR_PORT, но wg-obfuscator.conf слушает $actual_port. Использую фактический порт $actual_port."
    OBFUSCATOR_PORT="$actual_port"
  fi
  write_firewall_ports_file
  echo "Порты, которые нужно открыть:"
  echo ""
  echo "  UDP $OBFUSCATOR_PORT  - основной порт клиентов Phobos / wg-obfuscator"
  echo "  TCP $HTTP_PORT  - HTTP-сервер для скачивания клиентских пакетов"
  echo ""
  echo "Команды для UFW:"
  echo "  sudo ufw allow $OBFUSCATOR_PORT/udp comment 'Phobos wg-obfuscator'"
  echo "  sudo ufw allow $HTTP_PORT/tcp comment 'Phobos package HTTP'"
  echo "  sudo ufw reload"
  echo ""
  echo "Провайдерский firewall/security group: UDP $OBFUSCATOR_PORT и TCP $HTTP_PORT"
  echo "Не открывай 51820/udp наружу: WireGuard должен быть скрыт за obfuscator."
  echo "Сохранено в: $PHOBOS_DIR/server/firewall-ports.txt"
}


action_monitor() {
  echo "Мониторинг клиентов (Live)..."
  echo "Ctrl+C для выхода"
  watch -n 2 "wg show wg0; echo ''; echo '--- Obfuscator ---'; ss -un state established '( dport = :$OBFUSCATOR_PORT )'; echo ''; echo '--- Xray Upstream ---'; systemctl is-active phobos-xray-upstream 2>/dev/null || true; iptables -t mangle -S PHOBOS_XRAY 2>/dev/null | head"
}

case "$CMD" in
  status|health) action_status ;;
  cleanup) action_cleanup ;;
  monitor) action_monitor ;;
  ports|firewall) action_ports ;;
  *)
    echo "Usage: $0 {status|cleanup|monitor|ports}"
    exit 1
    ;;
esac
