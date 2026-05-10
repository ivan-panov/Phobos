#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib-core.sh"

check_root
load_env
ensure_dirs

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
XRAY_CONFIG_DIR="$(dirname "$XRAY_CONFIG")"
XRAY_PHOBOS_MANAGED_MARKER="${XRAY_PHOBOS_MANAGED_MARKER:-/usr/local/etc/xray/phobos-managed}"
XRAY_PHOBOS_INSTALLED_MARKER="${XRAY_PHOBOS_INSTALLED_MARKER:-/usr/local/etc/xray/phobos-installed-by-phobos}"
XRAY_TPROXY_PORT="${XRAY_TPROXY_PORT:-12345}"
XRAY_SOCKS_PORT="${XRAY_SOCKS_PORT:-10808}"
XRAY_MARK="${XRAY_MARK:-1}"
XRAY_ROUTE_TABLE_ID="${XRAY_ROUTE_TABLE_ID:-100}"
XRAY_ROUTE_TABLE_NAME="${XRAY_ROUTE_TABLE_NAME:-phobos_xray}"
XRAY_CLIENT_NET="${XRAY_CLIENT_NET:-${SERVER_WG_IPV4_NETWORK:-10.25.0.0/16}}"
XRAY_WG_INTERFACE="${XRAY_WG_INTERFACE:-wg0}"
XRAY_OUTBOUND_TAG="${XRAY_OUTBOUND_TAG:-vps2-remnawave}"
XRAY_RULE_CHAIN="XRAY_PHOBOS"
XRAY_DIVERT_CHAIN="XRAY_PHOBOS_DIVERT"

usage() {
  cat <<USAGE
Использование: $0 <command>

Команды:
  setup        Настроить VPS1: Phobos clients -> Xray/Remnawave VPS2
  apply        Применить TPROXY правила для Phobos-клиентов
  disable      Отключить Xray/Remnawave-выход и убрать правила
  status       Показать статус Xray/Remnawave-выхода
  test         Проверить Xray outbound через локальный SOCKS
  stabilize    Включить автоперезапуск Xray и watchdog проверки SOCKS
  watchdog     Одноразовая watchdog-проверка SOCKS и восстановление при сбое
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  local missing=()
  for cmd in curl jq python3 ip iptables; do
    need_cmd "$cmd" || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    if need_cmd apt-get; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq python3 iproute2 iptables ca-certificates
    elif need_cmd dnf; then
      dnf install -y curl jq python3 iproute iptables ca-certificates
    elif need_cmd yum; then
      yum install -y curl jq python3 iproute iptables ca-certificates
    else
      die "Не найден apt/dnf/yum. Установите зависимости вручную: ${missing[*]}"
    fi
  fi
}

install_xray_if_needed() {
  if need_cmd xray; then
    return 0
  fi

  log_info "Xray не найден. Устанавливаю Xray-core..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if ! need_cmd xray; then
    die "Xray не установился. Проверьте доступ к GitHub и повторите."
  fi

  mkdir -p "$XRAY_CONFIG_DIR"
  touch "$XRAY_PHOBOS_INSTALLED_MARKER"
  log_info "Xray помечен как установленный Phobos: $XRAY_PHOBOS_INSTALLED_MARKER"
}

json_escape_to_file() {
  local content="$1"
  local output="$2"
  printf '%s' "$content" > "$output"
}

parse_vless_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import json
import sys
from urllib.parse import urlparse, parse_qs, unquote

url = sys.argv[1].strip()
parsed = urlparse(url)
if parsed.scheme.lower() != "vless":
    raise SystemExit("ERROR: поддерживается только vless:// ссылка из Remnawave")

query = {k: v[-1] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
user_id = unquote(parsed.username or "")
host = parsed.hostname or ""
port = parsed.port or 443

if not user_id or not host:
    raise SystemExit("ERROR: не удалось разобрать UUID/host из VLESS ссылки")

network = query.get("type") or query.get("network") or "tcp"
security = query.get("security") or "reality"
flow = query.get("flow") or ""
encryption = query.get("encryption") or "none"

result = {
    "protocol": "vless",
    "address": host,
    "port": int(port),
    "id": user_id,
    "encryption": encryption,
    "flow": flow,
    "network": network,
    "security": security,
    "fingerprint": query.get("fp") or query.get("fingerprint") or "chrome",
    "serverName": query.get("sni") or query.get("serverName") or "",
    "publicKey": query.get("pbk") or query.get("publicKey") or "",
    "shortId": query.get("sid") or query.get("shortId") or "",
    "spiderX": unquote(query.get("spx") or query.get("spiderX") or "/"),
    "alpn": query.get("alpn") or "",
    "path": unquote(query.get("path") or "/"),
    "hostHeader": query.get("host") or "",
    "serviceName": query.get("serviceName") or "",
    "allowInsecure": query.get("allowInsecure") or "0",
}

if security == "reality":
    missing = [k for k in ("serverName", "publicKey") if not result.get(k)]
    if missing:
        raise SystemExit("ERROR: для REALITY не хватает параметров: " + ", ".join(missing))

print(json.dumps(result, ensure_ascii=False))
PY
}

build_outbound_json() {
  local parsed_json="$1"
  jq -n --argjson p "$parsed_json" --arg tag "$XRAY_OUTBOUND_TAG" '
    def streamSettings:
      if $p.network == "tcp" then
        {
          "network": "tcp",
          "security": $p.security
        }
      elif $p.network == "ws" then
        {
          "network": "ws",
          "security": $p.security,
          "wsSettings": {
            "path": $p.path,
            "headers": (if $p.hostHeader != "" then {"Host": $p.hostHeader} else {} end)
          }
        }
      elif $p.network == "grpc" then
        {
          "network": "grpc",
          "security": $p.security,
          "grpcSettings": {"serviceName": $p.serviceName}
        }
      else
        {
          "network": $p.network,
          "security": $p.security
        }
      end;

    def addSecurity($s):
      if $p.security == "reality" then
        $s + {
          "realitySettings": {
            "fingerprint": $p.fingerprint,
            "serverName": $p.serverName,
            "publicKey": $p.publicKey,
            "shortId": $p.shortId,
            "spiderX": $p.spiderX
          }
        }
      elif $p.security == "tls" then
        $s + {
          "tlsSettings": {
            "serverName": $p.serverName,
            "allowInsecure": ($p.allowInsecure == "1" or $p.allowInsecure == "true")
          }
        }
      else
        $s
      end;

    {
      "tag": $tag,
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": $p.address,
            "port": $p.port,
            "users": [
              {
                "id": $p.id,
                "encryption": $p.encryption
              } + (if $p.flow != "" then {"flow": $p.flow} else {} end)
            ]
          }
        ]
      },
      "streamSettings": addSecurity(streamSettings)
    }
  '
}

xray_service_user() {
  local user
  user="$(systemctl show -p User --value xray 2>/dev/null || true)"
  [[ -n "$user" ]] || user="root"
  echo "$user"
}

xray_service_group() {
  local user group
  user="$(xray_service_user)"
  group="$(systemctl show -p Group --value xray 2>/dev/null || true)"

  if [[ -z "$group" ]]; then
    if [[ "$user" == "root" ]]; then
      group="root"
    else
      group="$(id -gn "$user" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$group" ]]; then
    if getent group nogroup >/dev/null 2>&1; then
      group="nogroup"
    elif getent group nobody >/dev/null 2>&1; then
      group="nobody"
    else
      group="root"
    fi
  fi

  echo "$group"
}

fix_xray_config_permissions() {
  local config_dir service_group
  config_dir="$(dirname "$XRAY_CONFIG")"
  service_group="$(xray_service_group)"

  mkdir -p "$config_dir"

  # xray.service in XTLS packages can run as User=nobody.  The config is
  # written by this root script, so keep root ownership but grant read/execute
  # to the service group.  Parent directories must remain traversable too.
  chmod 755 /usr /usr/local /usr/local/etc 2>/dev/null || true
  chown root:"$service_group" "$config_dir" 2>/dev/null || true
  chmod 750 "$config_dir" 2>/dev/null || true

  if [[ -f "$XRAY_CONFIG" ]]; then
    chown root:"$service_group" "$XRAY_CONFIG" 2>/dev/null || true
    chmod 640 "$XRAY_CONFIG" 2>/dev/null || true
  fi

  for marker in "$XRAY_PHOBOS_MANAGED_MARKER" "$XRAY_PHOBOS_INSTALLED_MARKER"; do
    if [[ -f "$marker" ]]; then
      chown root:"$service_group" "$marker" 2>/dev/null || true
      chmod 640 "$marker" 2>/dev/null || true
    fi
  done
}

write_xray_config() {
  local outbound_json="$1"
  mkdir -p "$(dirname "$XRAY_CONFIG")"

  jq -n \
    --argjson ob "$outbound_json" \
    --arg tproxy_port "$XRAY_TPROXY_PORT" \
    --arg socks_port "$XRAY_SOCKS_PORT" \
    --arg out_tag "$XRAY_OUTBOUND_TAG" '
    {
      "log": {"loglevel": "warning"},
      "inbounds": [
        {
          "tag": "phobos-tproxy",
          "listen": "0.0.0.0",
          "port": ($tproxy_port | tonumber),
          "protocol": "dokodemo-door",
          "settings": {
            "network": "tcp,udp",
            "followRedirect": true
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
          },
          "streamSettings": {
            "sockopt": {"tproxy": "tproxy"}
          }
        },
        {
          "tag": "phobos-socks-test",
          "listen": "127.0.0.1",
          "port": ($socks_port | tonumber),
          "protocol": "socks",
          "settings": {"udp": true},
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }
      ],
      "outbounds": [
        $ob,
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
      ],
      "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
          {
            "type": "field",
            "ip": ["geoip:private"],
            "outboundTag": "direct"
          },
          {
            "type": "field",
            "inboundTag": ["phobos-tproxy", "phobos-socks-test"],
            "outboundTag": $out_tag
          }
        ]
      }
    }
  ' > "$XRAY_CONFIG"

  cat > "$XRAY_PHOBOS_MANAGED_MARKER" <<EOF_MARKER
managed_by=phobos
component=xray-remnawave
config=$XRAY_CONFIG
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MARKER

  fix_xray_config_permissions
  xray run -test -config "$XRAY_CONFIG" >/dev/null
}

ensure_rt_table() {
  if ! grep -qE "^[[:space:]]*${XRAY_ROUTE_TABLE_ID}[[:space:]]+${XRAY_ROUTE_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "${XRAY_ROUTE_TABLE_ID} ${XRAY_ROUTE_TABLE_NAME}" >> /etc/iproute2/rt_tables
  fi
}

iptables_insert_once() {
  local table="$1"
  shift
  if ! iptables -t "$table" -C "$@" 2>/dev/null; then
    iptables -t "$table" -A "$@"
  fi
}

apply_rules() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ensure_rt_table

  ip rule add fwmark "$XRAY_MARK" table "$XRAY_ROUTE_TABLE_NAME" priority 100 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table "$XRAY_ROUTE_TABLE_NAME"

  iptables -t mangle -N "$XRAY_RULE_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$XRAY_RULE_CHAIN"
  iptables -t mangle -N "$XRAY_DIVERT_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$XRAY_DIVERT_CHAIN"

  iptables -t mangle -A "$XRAY_DIVERT_CHAIN" -j MARK --set-mark "$XRAY_MARK"
  iptables -t mangle -A "$XRAY_DIVERT_CHAIN" -j ACCEPT

  iptables_insert_once mangle PREROUTING -i "$XRAY_WG_INTERFACE" -p tcp -m socket -j "$XRAY_DIVERT_CHAIN"

  for cidr in \
    0.0.0.0/8 \
    10.0.0.0/8 \
    100.64.0.0/10 \
    127.0.0.0/8 \
    169.254.0.0/16 \
    172.16.0.0/12 \
    192.168.0.0/16 \
    224.0.0.0/4 \
    240.0.0.0/4; do
    iptables -t mangle -A "$XRAY_RULE_CHAIN" -d "$cidr" -j RETURN
  done

  iptables -t mangle -A "$XRAY_RULE_CHAIN" -p tcp -j TPROXY --on-port "$XRAY_TPROXY_PORT" --tproxy-mark "${XRAY_MARK}/${XRAY_MARK}"
  iptables -t mangle -A "$XRAY_RULE_CHAIN" -p udp -j TPROXY --on-port "$XRAY_TPROXY_PORT" --tproxy-mark "${XRAY_MARK}/${XRAY_MARK}"

  iptables -t mangle -D PREROUTING -i "$XRAY_WG_INTERFACE" -s "$XRAY_CLIENT_NET" -j "$XRAY_RULE_CHAIN" 2>/dev/null || true
  iptables -t mangle -A PREROUTING -i "$XRAY_WG_INTERFACE" -s "$XRAY_CLIENT_NET" -j "$XRAY_RULE_CHAIN"
}

remove_rules() {
  iptables -t mangle -D PREROUTING -i "$XRAY_WG_INTERFACE" -s "$XRAY_CLIENT_NET" -j "$XRAY_RULE_CHAIN" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i "$XRAY_WG_INTERFACE" -p tcp -m socket -j "$XRAY_DIVERT_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$XRAY_RULE_CHAIN" 2>/dev/null || true
  iptables -t mangle -X "$XRAY_RULE_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$XRAY_DIVERT_CHAIN" 2>/dev/null || true
  iptables -t mangle -X "$XRAY_DIVERT_CHAIN" 2>/dev/null || true
  ip rule del fwmark "$XRAY_MARK" table "$XRAY_ROUTE_TABLE_NAME" priority 100 2>/dev/null || true
  ip route flush table "$XRAY_ROUTE_TABLE_NAME" 2>/dev/null || true
}

write_xray_service_override() {
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/phobos-tproxy.conf <<'EOF_XRAY_SERVICE'
[Service]
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
Restart=always
RestartSec=3
EOF_XRAY_SERVICE

  systemctl daemon-reload
}

write_watchdog_service() {
  cat > /usr/local/sbin/phobos-xray-remnawave-watchdog.sh <<'EOF_WATCHDOG'
#!/usr/bin/env bash
set -u

SERVER_ENV="/opt/Phobos/server/server.env"
if [[ -f "$SERVER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SERVER_ENV"
fi

SOCKS_PORT="${XRAY_SOCKS_PORT:-10808}"
CHECK_URL="${XRAY_WATCHDOG_URL:-https://ifconfig.me}"

for attempt in 1 2 3; do
  if curl -4 --connect-timeout 5 --max-time 12 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" -fsS "$CHECK_URL" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 3
done

logger -t phobos-xray-remnawave-watchdog "SOCKS check failed on 127.0.0.1:${SOCKS_PORT}; restarting xray and TPROXY rules"
systemctl restart xray
systemctl restart phobos-xray-remnawave-rules.service 2>/dev/null || true
EOF_WATCHDOG

  chmod +x /usr/local/sbin/phobos-xray-remnawave-watchdog.sh

  cat > /etc/systemd/system/phobos-xray-remnawave-watchdog.service <<'EOF_WATCHDOG_SERVICE'
[Unit]
Description=Phobos Xray Remnawave watchdog
After=network-online.target xray.service phobos-xray-remnawave-rules.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/phobos-xray-remnawave-watchdog.sh
EOF_WATCHDOG_SERVICE

  cat > /etc/systemd/system/phobos-xray-remnawave-watchdog.timer <<'EOF_WATCHDOG_TIMER'
[Unit]
Description=Run Phobos Xray Remnawave watchdog every minute

[Timer]
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF_WATCHDOG_TIMER

  systemctl daemon-reload
  systemctl enable --now phobos-xray-remnawave-watchdog.timer >/dev/null 2>&1 || true
}

stabilize() {
  install_deps
  write_xray_service_override
  fix_xray_config_permissions
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  apply_rules
  write_rules_service
  systemctl restart phobos-xray-remnawave-rules.service
  write_watchdog_service
  log_success "Стабилизация включена: Xray автоперезапускается, watchdog проверяет SOCKS каждые 60 секунд."
}

watchdog_cmd() {
  if [[ ! -x /usr/local/sbin/phobos-xray-remnawave-watchdog.sh ]]; then
    write_watchdog_service
  fi
  /usr/local/sbin/phobos-xray-remnawave-watchdog.sh
}

write_rules_service() {
  cat > /etc/systemd/system/phobos-xray-remnawave-rules.service <<EOF_SERVICE
[Unit]
Description=Phobos Xray Remnawave TPROXY rules
After=network-online.target wg-quick@${XRAY_WG_INTERFACE}.service xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/phobos-xray-remnawave.sh apply
ExecStop=$SCRIPT_DIR/phobos-xray-remnawave.sh disable-rules-internal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable phobos-xray-remnawave-rules.service >/dev/null 2>&1 || true
}

setup() {
  local vless_url parsed_json outbound_json
  echo ""
  echo "Вставьте VLESS-ссылку пользователя Remnawave для VPS2."
  echo "Схема должна быть vless://...; лучше VLESS + TCP + REALITY."
  echo ""
  read -rp "VLESS URL: " vless_url
  vless_url="$(echo "$vless_url" | tr -d '\r\n')"
  [[ -z "$vless_url" ]] && die "VLESS URL пустой."

  install_deps
  install_xray_if_needed

  parsed_json="$(parse_vless_url "$vless_url")" || die "Не удалось разобрать VLESS URL."
  outbound_json="$(build_outbound_json "$parsed_json")" || die "Не удалось собрать outbound JSON."
  write_xray_config "$outbound_json" || die "Xray config test failed."

  mkdir -p /etc/systemd/system/xray.service.d
  write_xray_service_override
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray

  apply_rules
  write_rules_service
  systemctl restart phobos-xray-remnawave-rules.service
  write_watchdog_service

  save_env_var PHOBOS_XRAY_REMNAWAVE_ENABLED 1
  save_env_var PHOBOS_XRAY_REMNAWAVE_ROLE entry
  save_env_var XRAY_CONFIG "$XRAY_CONFIG"
  save_env_var XRAY_TPROXY_PORT "$XRAY_TPROXY_PORT"
  save_env_var XRAY_SOCKS_PORT "$XRAY_SOCKS_PORT"
  save_env_var XRAY_MARK "$XRAY_MARK"
  save_env_var XRAY_ROUTE_TABLE_ID "$XRAY_ROUTE_TABLE_ID"
  save_env_var XRAY_ROUTE_TABLE_NAME "$XRAY_ROUTE_TABLE_NAME"
  save_env_var XRAY_CLIENT_NET "$XRAY_CLIENT_NET"
  save_env_var XRAY_WG_INTERFACE "$XRAY_WG_INTERFACE"
  save_env_var XRAY_OUTBOUND_TAG "$XRAY_OUTBOUND_TAG"

  log_success "VPS1 настроен: клиенты Phobos (${XRAY_CLIENT_NET}) выходят через VPS2 Remnawave/Xray."
  echo ""
  echo "Проверка Xray outbound на VPS1:"
  echo "  $SCRIPT_DIR/phobos-xray-remnawave.sh test"
  echo ""
  echo "Проверка с клиента за Keenetic:"
  echo "  curl -4 ifconfig.me"
  echo "Должен быть IP VPS2."
}

status_cmd() {
  echo ""
  echo "PHOBOS XRAY/REMNAWAVE STATUS"
  echo "-----------------------------"
  echo "Включено: ${PHOBOS_XRAY_REMNAWAVE_ENABLED:-0}"
  echo "WG интерфейс клиентов: ${XRAY_WG_INTERFACE}"
  echo "Клиентская сеть: ${XRAY_CLIENT_NET}"
  echo "Xray config: ${XRAY_CONFIG}"
  echo "TPROXY порт: ${XRAY_TPROXY_PORT}"
  echo "SOCKS test порт: 127.0.0.1:${XRAY_SOCKS_PORT}"
  echo "Таблица маршрутизации: ${XRAY_ROUTE_TABLE_NAME}/${XRAY_ROUTE_TABLE_ID}"
  echo ""
  systemctl is-active --quiet xray && echo "xray: RUNNING" || echo "xray: STOPPED"
  systemctl is-active --quiet phobos-xray-remnawave-rules.service && echo "rules service: RUNNING" || echo "rules service: STOPPED"
  systemctl is-active --quiet phobos-xray-remnawave-watchdog.timer && echo "watchdog timer: RUNNING" || echo "watchdog timer: STOPPED"
  echo ""
  echo "ip rule:"
  ip rule show | grep -E "fwmark|${XRAY_ROUTE_TABLE_NAME}|${XRAY_ROUTE_TABLE_ID}" || echo "правил нет"
  echo ""
  echo "iptables mangle PREROUTING:"
  iptables -t mangle -S PREROUTING | grep "$XRAY_RULE_CHAIN" || echo "PREROUTING правила нет"
  echo ""
  echo "Xray inbound ports:"
  ss -lntup 2>/dev/null | grep -E ":(${XRAY_TPROXY_PORT}|${XRAY_SOCKS_PORT})\b" || echo "порты не слушаются"
}

test_cmd() {
  if ! need_cmd curl; then
    if need_cmd apt-get; then
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl
    fi
  fi
  echo "Проверяю IP через Xray SOCKS 127.0.0.1:${XRAY_SOCKS_PORT}..."
  curl -4 --connect-timeout 10 --max-time 20 --socks5-hostname "127.0.0.1:${XRAY_SOCKS_PORT}" https://ifconfig.me || true
  echo ""
}

disable_all() {
  systemctl stop phobos-xray-remnawave-watchdog.timer 2>/dev/null || true
  systemctl disable phobos-xray-remnawave-watchdog.timer 2>/dev/null || true
  systemctl stop phobos-xray-remnawave-rules.service 2>/dev/null || true
  systemctl disable phobos-xray-remnawave-rules.service 2>/dev/null || true
  remove_rules
  save_env_var PHOBOS_XRAY_REMNAWAVE_ENABLED 0
  log_success "Xray/Remnawave-выход для Phobos отключен. Xray config сохранён: ${XRAY_CONFIG}"
}

case "${1:-}" in
  setup) setup ;;
  apply)
    if [[ "${PHOBOS_XRAY_REMNAWAVE_ENABLED:-0}" == "1" ]]; then
      apply_rules
    else
      echo "PHOBOS_XRAY_REMNAWAVE_ENABLED != 1, правила не применены."
    fi
    ;;
  disable) disable_all ;;
  disable-rules-internal) remove_rules ;;
  status) status_cmd ;;
  test) test_cmd ;;
  stabilize) stabilize ;;
  watchdog) watchdog_cmd ;;
  help|-h|--help|"") usage ;;
  *) usage; exit 1 ;;
esac
