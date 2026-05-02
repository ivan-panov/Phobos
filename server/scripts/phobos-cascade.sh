#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib-core.sh"

check_root
load_env
ensure_dirs

CASCADE_DIR="$PHOBOS_DIR/cascade"
CASCADE_IFACE="${CASCADE_WG_INTERFACE:-wg-exit}"
CASCADE_CONFIG="/etc/wireguard/${CASCADE_IFACE}.conf"
CASCADE_TABLE_ID="${CASCADE_TABLE_ID:-77}"
CASCADE_TABLE_NAME="${CASCADE_TABLE_NAME:-phobos_exit}"
CASCADE_PORT="${CASCADE_WG_PORT:-51830}"
CASCADE_NET="${CASCADE_NET:-10.77.0.0/30}"
CASCADE_ENTRY_IP="${CASCADE_ENTRY_IP:-10.77.0.1}"
CASCADE_EXIT_IP="${CASCADE_EXIT_IP:-10.77.0.2}"
CASCADE_CLIENT_NET="${CASCADE_CLIENT_NET:-${SERVER_WG_IPV4_NETWORK:-10.25.0.0/16}}"

mkdir -p "$CASCADE_DIR" /etc/wireguard

usage() {
  cat <<USAGE
Использование: $0 <command>

Команды:
  key          Показать публичный ключ этого VPS для каскада
  entry        Настроить этот VPS как VPS1 entry-node: клиенты -> VPS1 -> VPS2
  exit         Настроить этот VPS как VPS2 exit-node: VPS1 -> VPS2 -> интернет
  status       Показать статус каскада
  disable      Отключить каскад на этом VPS
USAGE
}

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

ensure_cascade_keys() {
  local private_key_file="$CASCADE_DIR/${CASCADE_IFACE}.private"
  local public_key_file="$CASCADE_DIR/${CASCADE_IFACE}.public"

  if [[ ! -s "$private_key_file" ]]; then
    umask 077
    wg genkey | tee "$private_key_file" | wg pubkey > "$public_key_file"
  elif [[ ! -s "$public_key_file" ]]; then
    wg pubkey < "$private_key_file" > "$public_key_file"
  fi
}

get_private_key() {
  ensure_cascade_keys
  cat "$CASCADE_DIR/${CASCADE_IFACE}.private"
}

get_public_key() {
  ensure_cascade_keys
  cat "$CASCADE_DIR/${CASCADE_IFACE}.public"
}

get_default_iface() {
  ip route | awk '/^default/{print $5; exit}'
}

ensure_rt_table() {
  if ! grep -qE "^[[:space:]]*${CASCADE_TABLE_ID}[[:space:]]+${CASCADE_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "${CASCADE_TABLE_ID} ${CASCADE_TABLE_NAME}" >> /etc/iproute2/rt_tables
  fi
}

restart_cascade() {
  systemctl enable "wg-quick@${CASCADE_IFACE}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${CASCADE_IFACE}"
}

open_ufw_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${port}/udp" >/dev/null || true
  fi
}

prompt_non_empty() {
  local prompt="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -rp "$prompt" value
    value="$(echo "$value" | tr -d '[:space:]')"
  done
  echo "$value"
}

configure_exit() {
  local private_key entry_public_key nat_iface port
  private_key="$(get_private_key)"

  echo ""
  echo "Этот VPS будет VPS2 / exit-node. Сайты будут видеть IP этого VPS."
  echo ""
  echo "Публичный ключ этого VPS2, его нужно указать на VPS1:"
  echo "  $(get_public_key)"
  echo ""
  entry_public_key="$(prompt_non_empty "Вставьте публичный ключ VPS1 entry-node: ")"
  read -rp "UDP порт каскада на VPS2 [${CASCADE_PORT}]: " port
  port="${port:-$CASCADE_PORT}"
  nat_iface="$(get_default_iface)"
  read -rp "Внешний интерфейс для выхода в интернет [${nat_iface}]: " nat_iface_input
  nat_iface="${nat_iface_input:-$nat_iface}"

  [[ -z "$nat_iface" ]] && die "Не удалось определить внешний интерфейс. Укажите его вручную, например eth0/ens3."

  cat > "$CASCADE_CONFIG" <<CFG
[Interface]
Address = ${CASCADE_EXIT_IP}/30
ListenPort = ${port}
PrivateKey = ${private_key}
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s ${CASCADE_CLIENT_NET} -o ${nat_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${CASCADE_CLIENT_NET} -o ${nat_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${CASCADE_CLIENT_NET} -o ${nat_iface} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${entry_public_key}
AllowedIPs = ${CASCADE_ENTRY_IP}/32, ${CASCADE_CLIENT_NET}
CFG

  chmod 600 "$CASCADE_CONFIG"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi

  restart_cascade
  open_ufw_udp "$port"

  save_env_var PHOBOS_CASCADE_ENABLED 1
  save_env_var PHOBOS_CASCADE_ROLE exit
  save_env_var CASCADE_WG_INTERFACE "$CASCADE_IFACE"
  save_env_var CASCADE_WG_PORT "$port"
  save_env_var CASCADE_CLIENT_NET "$CASCADE_CLIENT_NET"
  save_env_var CASCADE_EXIT_NAT_IFACE "$nat_iface"

  log_success "VPS2 exit-node настроен и запущен."
  echo "Откройте на VPS2 в firewall: ${port}/udp"
}

configure_entry() {
  local private_key exit_public_key exit_host exit_port
  private_key="$(get_private_key)"

  echo ""
  echo "Этот VPS будет VPS1 / entry-node. Клиенты подключаются к нему, а выходят через VPS2."
  echo ""
  echo "Публичный ключ этого VPS1, его нужно указать на VPS2:"
  echo "  $(get_public_key)"
  echo ""
  exit_host="$(prompt_non_empty "Введите публичный IP или домен VPS2 без http:// и без порта: ")"
  exit_host="$(sanitize_public_endpoint "$exit_host")"
  [[ -z "$exit_host" ]] && die "Endpoint VPS2 пустой."
  read -rp "UDP порт каскада на VPS2 [${CASCADE_PORT}]: " exit_port
  exit_port="${exit_port:-$CASCADE_PORT}"
  exit_public_key="$(prompt_non_empty "Вставьте публичный ключ VPS2 exit-node: ")"

  ensure_rt_table

  cat > "$CASCADE_CONFIG" <<CFG
[Interface]
Address = ${CASCADE_ENTRY_IP}/30
PrivateKey = ${private_key}
Table = off
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; ip rule add from ${CASCADE_CLIENT_NET} table ${CASCADE_TABLE_NAME} priority 1077 2>/dev/null || true; ip route replace default dev %i table ${CASCADE_TABLE_NAME}; iptables -C FORWARD -i wg0 -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -o %i -j ACCEPT; iptables -C FORWARD -i %i -o wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -o wg0 -j ACCEPT
PostDown = ip rule del from ${CASCADE_CLIENT_NET} table ${CASCADE_TABLE_NAME} priority 1077 2>/dev/null || true; ip route flush table ${CASCADE_TABLE_NAME} 2>/dev/null || true; iptables -D FORWARD -i wg0 -o %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i %i -o wg0 -j ACCEPT 2>/dev/null || true

[Peer]
PublicKey = ${exit_public_key}
Endpoint = ${exit_host}:${exit_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CFG

  chmod 600 "$CASCADE_CONFIG"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi

  restart_cascade

  save_env_var PHOBOS_CASCADE_ENABLED 1
  save_env_var PHOBOS_CASCADE_ROLE entry
  save_env_var CASCADE_WG_INTERFACE "$CASCADE_IFACE"
  save_env_var CASCADE_EXIT_PUBLIC_ENDPOINT "$exit_host"
  save_env_var CASCADE_WG_PORT "$exit_port"
  save_env_var CASCADE_CLIENT_NET "$CASCADE_CLIENT_NET"
  save_env_var CASCADE_TABLE_ID "$CASCADE_TABLE_ID"
  save_env_var CASCADE_TABLE_NAME "$CASCADE_TABLE_NAME"

  log_success "VPS1 entry-node настроен и запущен."
  echo "Клиенты Phobos теперь маршрутизируются через VPS2 по правилу: from ${CASCADE_CLIENT_NET} table ${CASCADE_TABLE_NAME}"
}

status_cascade() {
  echo ""
  echo "PHOBOS CASCADE STATUS"
  echo "---------------------"
  echo "Роль: ${PHOBOS_CASCADE_ROLE:-off}"
  echo "Интерфейс: ${CASCADE_IFACE}"
  echo "Конфиг: ${CASCADE_CONFIG}"
  echo "Клиентская сеть: ${CASCADE_CLIENT_NET}"
  echo ""

  if [[ -f "$CASCADE_CONFIG" ]]; then
    echo "wg-exit.conf: есть"
  else
    echo "wg-exit.conf: нет"
  fi

  if systemctl is-active --quiet "wg-quick@${CASCADE_IFACE}"; then
    echo "Служба: RUNNING"
  else
    echo "Служба: STOPPED"
  fi

  echo ""
  echo "WireGuard:"
  wg show "$CASCADE_IFACE" 2>/dev/null || echo "Интерфейс ${CASCADE_IFACE} не активен"

  echo ""
  echo "Policy routing:"
  ip rule show | grep -E "${CASCADE_CLIENT_NET}|${CASCADE_TABLE_NAME}|${CASCADE_TABLE_ID}" || echo "Правил policy routing не найдено"
  ip route show table "$CASCADE_TABLE_NAME" 2>/dev/null || true

  echo ""
  echo "Проверка туннеля:"
  if ping -c 2 -W 2 "$CASCADE_EXIT_IP" >/dev/null 2>&1 || ping -c 2 -W 2 "$CASCADE_ENTRY_IP" >/dev/null 2>&1; then
    echo "ping peer: OK"
  else
    echo "ping peer: нет ответа или роль не соответствует этому адресу"
  fi
}

disable_cascade() {
  echo "Отключение каскада ${CASCADE_IFACE}..."
  systemctl stop "wg-quick@${CASCADE_IFACE}" 2>/dev/null || true
  systemctl disable "wg-quick@${CASCADE_IFACE}" 2>/dev/null || true
  ip rule del from "$CASCADE_CLIENT_NET" table "$CASCADE_TABLE_NAME" priority 1077 2>/dev/null || true
  ip route flush table "$CASCADE_TABLE_NAME" 2>/dev/null || true

  save_env_var PHOBOS_CASCADE_ENABLED 0
  save_env_var PHOBOS_CASCADE_ROLE off

  log_success "Каскад отключен. Ключи сохранены в ${CASCADE_DIR}. Конфиг оставлен: ${CASCADE_CONFIG}"
}

case "${1:-}" in
  key)
    echo "Публичный ключ каскада этого VPS:"
    echo "$(get_public_key)"
    ;;
  entry) configure_entry ;;
  exit) configure_exit ;;
  status) status_cascade ;;
  disable) disable_cascade ;;
  help|-h|--help|"") usage ;;
  *) usage; exit 1 ;;
esac
