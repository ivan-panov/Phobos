#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib-core.sh"

check_root
load_env
ensure_dirs

WG_IFACE="${WG_IFACE:-wg0}"
WAN_IFACE="${WAN_IFACE:-$(ip -4 route show default | awk '/^default/{print $5; exit}')}"

save_env_var() {
  local key="$1"
  local value="$2"
  touch "$SERVER_ENV"
  if grep -qE "^${key}=" "$SERVER_ENV"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_ENV"
  else
    echo "${key}=${value}" >> "$SERVER_ENV"
  fi
}

remove_ipv4_rule() {
  while iptables "$@" 2>/dev/null; do :; done
}

remove_ipv6_rule() {
  while ip6tables "$@" 2>/dev/null; do :; done
}

killswitch_on() {
  [[ -n "$WAN_IFACE" ]] || die "Не удалось определить WAN-интерфейс VPS1. Укажите: WAN_IFACE=eth0 $0 on"

  save_env_var PHOBOS_VPS2_ONLY 1
  save_env_var PHOBOS_VPS2_MODE manual

  modprobe iptable_filter 2>/dev/null || true
  modprobe xt_REJECT 2>/dev/null || true

  remove_ipv4_rule -D FORWARD -i "$WG_IFACE" -o "$WAN_IFACE" -j REJECT --reject-with icmp-net-unreachable
  iptables -I FORWARD 1 -i "$WG_IFACE" -o "$WAN_IFACE" -j REJECT --reject-with icmp-net-unreachable

  if command -v ip6tables >/dev/null 2>&1; then
    remove_ipv6_rule -D FORWARD -i "$WG_IFACE" -j REJECT
    ip6tables -I FORWARD 1 -i "$WG_IFACE" -j REJECT
  fi

  log_success "VPS2-only kill-switch включен: ${WG_IFACE} не может выходить напрямую через ${WAN_IFACE}."
}

killswitch_off() {
  [[ -n "$WAN_IFACE" ]] || die "Не удалось определить WAN-интерфейс VPS1. Укажите: WAN_IFACE=eth0 $0 off"

  remove_ipv4_rule -D FORWARD -i "$WG_IFACE" -o "$WAN_IFACE" -j REJECT --reject-with icmp-net-unreachable
  if command -v ip6tables >/dev/null 2>&1; then
    remove_ipv6_rule -D FORWARD -i "$WG_IFACE" -j REJECT
  fi

  save_env_var PHOBOS_VPS2_ONLY 0
  log_warn "VPS2-only kill-switch выключен. При сбое VPS2 возможен прямой выход через IP VPS1."
}

killswitch_status() {
  echo "WG interface:  ${WG_IFACE}"
  echo "WAN interface: ${WAN_IFACE:-unknown}"
  echo "PHOBOS_VPS2_ONLY=${PHOBOS_VPS2_ONLY:-0}"
  echo ""
  echo "IPv4 FORWARD reject rules:"
  iptables -S FORWARD 2>/dev/null | grep -E "^-A FORWARD -i ${WG_IFACE} .* -j REJECT" || echo "not found"
  echo ""
  echo "IPv6 FORWARD reject rules:"
  ip6tables -S FORWARD 2>/dev/null | grep -E "^-A FORWARD -i ${WG_IFACE} .* -j REJECT" || echo "not found or IPv6 disabled"
}

usage() {
  cat <<USAGE
Использование: $0 <on|off|status>

  on      Запретить клиентам Phobos прямой выход VPS1 -> WAN, оставить только путь через VPS2
  off     Убрать запрет прямого выхода VPS1 -> WAN
  status  Показать активные правила kill-switch

Переменные:
  WG_IFACE=wg0       WireGuard-интерфейс клиентов Phobos
  WAN_IFACE=eth0     WAN-интерфейс VPS1, если автоопределение ошиблось
USAGE
}

case "${1:-status}" in
  on) killswitch_on ;;
  off) killswitch_off ;;
  status) killswitch_status ;;
  *) usage; exit 1 ;;
esac
