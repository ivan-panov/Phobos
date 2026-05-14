#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-core.sh"

check_root
load_env
ensure_dirs

XRAY_CONFIG="$PHOBOS_DIR/server/xray-upstream.json"
XRAY_META="$PHOBOS_DIR/server/xray-upstream.env"
XRAY_FW="$PHOBOS_DIR/server/xray-upstream-fw.sh"
XRAY_SERVICE="/etc/systemd/system/phobos-xray-upstream.service"
XRAY_BIN="/usr/local/bin/xray"
TPROXY_PORT="${TPROXY_PORT:-12345}"
TPROXY_MARK="${TPROXY_MARK:-1}"
TPROXY_TABLE="${TPROXY_TABLE:-100}"
WG_IFACE="${WG_IFACE:-wg0}"

usage() {
  cat <<USAGE
Usage: $0 {configure|status|start|stop|restart|disable|logs}

configure  - настроить VPS1 как Xray/VLESS клиент к VPS2 (Remnawave vless:// link)
status     - показать состояние upstream
start      - запустить phobos-xray-upstream
stop       - остановить phobos-xray-upstream и снять TPROXY правила
restart    - перезапустить upstream
logs       - показать логи сервиса

disable    - отключить upstream, удалить systemd service и TPROXY правила
USAGE
}

install_deps() {
  log_info "Установка зависимостей Xray upstream..."
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates unzip jq python3 iproute2 iptables >/dev/null
  log_success "Зависимости установлены"
}

arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) echo "Xray-linux-arm32-v7a.zip" ;;
    *) die "Архитектура $arch пока не поддержана установщиком Xray" ;;
  esac
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    log_success "Xray уже установлен: $XRAY_BIN"
    return 0
  fi

  install_deps
  local asset url tmp
  asset="$(arch_asset)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  log_info "Скачивание Xray-core ($asset)..."
  url="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' | head -1)"
  [[ -n "$url" && "$url" != "null" ]] || die "Не удалось найти release asset $asset"

  curl -fL --retry 3 -o "$tmp/xray.zip" "$url"
  unzip -q "$tmp/xray.zip" -d "$tmp/xray"
  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN"
  mkdir -p /usr/local/share/xray
  [[ -f "$tmp/xray/geoip.dat" ]] && install -m 0644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat
  [[ -f "$tmp/xray/geosite.dat" ]] && install -m 0644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  log_success "Xray установлен: $XRAY_BIN"
}

write_config_from_vless() {
  local vless_link="$1"
  local parsed_json
  parsed_json="$(python3 - "$vless_link" <<'PY'
import json
import sys
from urllib.parse import urlparse, parse_qs, unquote

link = sys.argv[1].strip()
if not link.startswith('vless://'):
    raise SystemExit('ERROR: Нужна ссылка формата vless://...')

u = urlparse(link)
if not u.username or not u.hostname or not u.port:
    raise SystemExit('ERROR: В vless:// ссылке должны быть UUID, host и port')

params = {k: unquote(v[-1]) for k, v in parse_qs(u.query, keep_blank_values=True).items()}
link_network = params.get('type', 'tcp') or 'tcp'
network_aliases = {
    'tcp': 'raw',
    'raw': 'raw',
    'ws': 'websocket',
    'websocket': 'websocket',
    'xhttp': 'xhttp',
    'splithttp': 'xhttp',
    'grpc': 'grpc',
    'httpupgrade': 'httpupgrade',
}
network = network_aliases.get(link_network.lower(), link_network.lower())
security = params.get('security', 'none') or 'none'
user = {
    'id': unquote(u.username),
    'encryption': params.get('encryption', 'none') or 'none',
}
flow = params.get('flow', '')
if flow:
    user['flow'] = flow

outbound = {
    'tag': 'vps2-vless',
    'protocol': 'vless',
    'settings': {
        'vnext': [{
            'address': u.hostname,
            'port': int(u.port),
            'users': [user],
        }]
    },
    'streamSettings': {
        'network': network,
        'security': security,
    },
    'mux': {'enabled': False},
}

stream = outbound['streamSettings']
fingerprint = params.get('fp') or params.get('fingerprint') or 'chrome'
sni = params.get('sni') or params.get('serverName') or u.hostname
alpn = [x.strip() for x in params.get('alpn', '').split(',') if x.strip()]

if security == 'tls':
    tls = {'serverName': sni, 'fingerprint': fingerprint}
    if alpn:
        tls['alpn'] = alpn
    stream['tlsSettings'] = tls
elif security == 'reality':
    public_key = params.get('pbk') or params.get('publicKey')
    if not public_key:
        raise SystemExit('ERROR: Для security=reality в ссылке нужен pbk/publicKey')
    reality = {
        'serverName': sni,
        'fingerprint': fingerprint,
        'publicKey': public_key,
        'shortId': params.get('sid', ''),
        'spiderX': params.get('spx', '/') or '/',
    }
    stream['realitySettings'] = reality

if network == 'websocket':
    ws = {'path': params.get('path', '/') or '/'}
    host = params.get('host') or params.get('Host')
    if host:
        ws['headers'] = {'Host': host}
    stream['wsSettings'] = ws
elif network == 'grpc':
    stream['grpcSettings'] = {
        'serviceName': params.get('serviceName') or params.get('service') or '',
        'multiMode': (params.get('mode') == 'multi'),
    }
elif network == 'httpupgrade':
    stream['httpupgradeSettings'] = {
        'path': params.get('path', '/') or '/',
        'host': params.get('host') or params.get('Host') or '',
    }
elif network == 'xhttp':
    stream['xhttpSettings'] = {
        'path': params.get('path', '/') or '/',
        'host': params.get('host') or params.get('Host') or '',
    }
elif network == 'raw':
    header_type = params.get('headerType') or params.get('header')
    if header_type and header_type != 'none':
        stream['rawSettings'] = {'header': {'type': header_type}}

config = {
    'log': {'loglevel': 'warning'},
    'inbounds': [{
        'tag': 'phobos-tproxy-in',
        'listen': '127.0.0.1',
        'port': 12345,
        'protocol': 'dokodemo-door',
        'settings': {'network': 'tcp,udp', 'followRedirect': True},
        'streamSettings': {'sockopt': {'tproxy': 'tproxy'}},
        'sniffing': {
            'enabled': True,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': False,
        },
    }],
    'outbounds': [
        outbound,
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
    ],
    'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [{
            'type': 'field',
            'ip': [
                '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
                '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
                '224.0.0.0/4', '240.0.0.0/4', '::1/128', 'fc00::/7', 'fe80::/10'
            ],
            'outboundTag': 'direct',
        }]
    }
}

print(json.dumps({'config': config, 'meta': {
    'address': u.hostname,
    'port': int(u.port),
    'uuid': unquote(u.username),
    'network': stream['network'],
    'security': security,
    'sni': sni,
}}, ensure_ascii=False, indent=2))
PY
)"

  local tmp_json
  tmp_json="$(mktemp)"
  printf '%s\n' "$parsed_json" > "$tmp_json"

  TPROXY_PORT="$TPROXY_PORT" jq '.config | .inbounds[0].port = (env.TPROXY_PORT | tonumber)' "$tmp_json" > "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"

  {
    echo "XRAY_UPSTREAM_ENABLED=1"
    echo "XRAY_TPROXY_PORT=$TPROXY_PORT"
    echo "XRAY_TPROXY_MARK=$TPROXY_MARK"
    echo "XRAY_TPROXY_TABLE=$TPROXY_TABLE"
    echo "XRAY_WG_IFACE=$WG_IFACE"
    echo "XRAY_VPS2_ADDRESS=$(jq -r '.meta.address' "$tmp_json")"
    echo "XRAY_VPS2_PORT=$(jq -r '.meta.port' "$tmp_json")"
    echo "XRAY_VLESS_NETWORK=$(jq -r '.meta.network' "$tmp_json")"
    echo "XRAY_VLESS_SECURITY=$(jq -r '.meta.security' "$tmp_json")"
    echo "XRAY_VLESS_SNI=$(jq -r '.meta.sni' "$tmp_json")"
  } > "$XRAY_META"
  chmod 600 "$XRAY_META"
  rm -f "$tmp_json"
}

write_fw_script() {
  cat > "$XRAY_FW" <<FW_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

WG_IFACE="${WG_IFACE}"
TPROXY_PORT="${TPROXY_PORT}"
TPROXY_MARK="${TPROXY_MARK}"
TPROXY_TABLE="${TPROXY_TABLE}"
CHAIN="PHOBOS_XRAY"

iptables_has_chain() {
  iptables -t mangle -S "\$CHAIN" >/dev/null 2>&1
}

rule_exists() {
  iptables "\$@" >/dev/null 2>&1
}

load_mods() {
  for m in xt_TPROXY nf_tproxy_ipv4 nf_tproxy_ipv6 xt_socket nf_defrag_ipv4 nf_defrag_ipv6; do
    modprobe "\$m" 2>/dev/null || true
  done
}

add_ip_rule() {
  local mark_hex
  mark_hex="\$(printf '%x' "\$TPROXY_MARK")"
  ip rule show | grep -q "fwmark 0x\${mark_hex} lookup \$TPROXY_TABLE" \
    || ip rule add fwmark "\$TPROXY_MARK" table "\$TPROXY_TABLE"
  ip route show table "\$TPROXY_TABLE" | grep -q "local default dev lo" \
    || ip route add local 0.0.0.0/0 dev lo table "\$TPROXY_TABLE"
}

del_ip_rule() {
  local mark_hex
  mark_hex="\$(printf '%x' "\$TPROXY_MARK")"
  while ip rule show | grep -q "fwmark 0x\${mark_hex} lookup \$TPROXY_TABLE"; do
    ip rule del fwmark "\$TPROXY_MARK" table "\$TPROXY_TABLE" 2>/dev/null || break
  done
  ip route flush table "\$TPROXY_TABLE" 2>/dev/null || true
}

up() {
  load_mods
  [[ -d "/sys/class/net/\$WG_IFACE" ]] || { echo "Interface \$WG_IFACE not found" >&2; exit 1; }
  add_ip_rule

  iptables_has_chain || iptables -t mangle -N "\$CHAIN"
  iptables -t mangle -F "\$CHAIN"

  # Не перехватываем локальные и служебные диапазоны.
  for cidr in \
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
    169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
    224.0.0.0/4 240.0.0.0/4; do
    iptables -t mangle -A "\$CHAIN" -d "\$cidr" -j RETURN
  done

  iptables -t mangle -A "\$CHAIN" -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port "\$TPROXY_PORT" --tproxy-mark "\$TPROXY_MARK/\$TPROXY_MARK"
  iptables -t mangle -A "\$CHAIN" -p udp -j TPROXY --on-ip 127.0.0.1 --on-port "\$TPROXY_PORT" --tproxy-mark "\$TPROXY_MARK/\$TPROXY_MARK"

  rule_exists -t mangle -C PREROUTING -i "\$WG_IFACE" -j "\$CHAIN" \
    || iptables -t mangle -A PREROUTING -i "\$WG_IFACE" -j "\$CHAIN"
}

down() {
  iptables -t mangle -D PREROUTING -i "\$WG_IFACE" -j "\$CHAIN" 2>/dev/null || true
  if iptables_has_chain; then
    iptables -t mangle -F "\$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "\$CHAIN" 2>/dev/null || true
  fi
  del_ip_rule
}

case "\${1:-}" in
  up) up ;;
  down) down ;;
  restart) down; up ;;
  *) echo "Usage: \$0 {up|down|restart}" >&2; exit 1 ;;
esac
FW_SCRIPT
  chmod 700 "$XRAY_FW"
}

write_service() {
  cat > "$XRAY_SERVICE" <<SERVICE
[Unit]
Description=Phobos Xray VLESS upstream to VPS2
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Type=simple
ExecStartPre=$XRAY_FW up
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
ExecStopPost=$XRAY_FW down
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable phobos-xray-upstream >/dev/null
}

append_env_if_missing() {
  local key="$1" value="$2"
  touch "$SERVER_ENV"
  if grep -q "^${key}=" "$SERVER_ENV" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_ENV"
  else
    echo "${key}=${value}" >> "$SERVER_ENV"
  fi
}

update_server_env() {
  append_env_if_missing "XRAY_UPSTREAM_ENABLED" "1"
  append_env_if_missing "XRAY_TPROXY_PORT" "$TPROXY_PORT"
  append_env_if_missing "XRAY_TPROXY_MARK" "$TPROXY_MARK"
  append_env_if_missing "XRAY_TPROXY_TABLE" "$TPROXY_TABLE"
  append_env_if_missing "XRAY_WG_IFACE" "$WG_IFACE"
}

validate_config() {
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null
}

cmd_configure() {
  install_deps
  install_xray

  local link="${1:-}"
  if [[ -z "$link" ]]; then
    echo "Вставьте vless:// ссылку из Remnawave для VPS2."
    read -r -p "VLESS link: " link
  fi
  [[ -n "$link" ]] || die "VLESS ссылка пустая"

  write_config_from_vless "$link"
  write_fw_script
  write_service
  update_server_env

  log_info "Проверка Xray config..."
  validate_config || die "Xray не принял конфиг: $XRAY_CONFIG"

  systemctl restart phobos-xray-upstream
  log_success "VPS1 подключен к VPS2 через Xray/VLESS. Трафик wg0 теперь уходит через upstream."
  cmd_status
}

cmd_status() {
  echo "=========================================="
  echo "   Phobos Xray upstream (VPS1 -> VPS2)"
  echo "=========================================="
  if [[ -f "$XRAY_META" ]]; then
    # shellcheck disable=SC1090
    source "$XRAY_META" || true
    echo "VPS2:      ${XRAY_VPS2_ADDRESS:-?}:${XRAY_VPS2_PORT:-?}"
    echo "Transport: ${XRAY_VLESS_NETWORK:-?} / ${XRAY_VLESS_SECURITY:-?}"
    echo "SNI:       ${XRAY_VLESS_SNI:-?}"
  else
    echo "Конфиг upstream ещё не создан. Запустите: $0 configure"
  fi
  local active enabled
  active="$(systemctl is-active phobos-xray-upstream 2>/dev/null || true)"
  enabled="$(systemctl is-enabled phobos-xray-upstream 2>/dev/null || true)"
  [[ -z "$active" ]] && active="inactive"
  [[ -z "$enabled" || "$enabled" == "not-found" ]] && enabled="disabled"
  echo "Service:   $active"
  echo "Enabled:   $enabled"
  echo "Config:    $XRAY_CONFIG"
  echo "Firewall:  $XRAY_FW"
  echo ""
  ip rule show 2>/dev/null | grep -E "fwmark .* lookup ${TPROXY_TABLE}" || true
  iptables -t mangle -S PHOBOS_XRAY 2>/dev/null || true
}

cmd_disable() {
  systemctl stop phobos-xray-upstream 2>/dev/null || true
  systemctl disable phobos-xray-upstream 2>/dev/null || true
  [[ -x "$XRAY_FW" ]] && "$XRAY_FW" down 2>/dev/null || true
  rm -f "$XRAY_SERVICE"
  systemctl daemon-reload
  append_env_if_missing "XRAY_UPSTREAM_ENABLED" "0"
  log_success "Xray upstream отключен. Phobos снова выходит напрямую через NAT VPS1."
}


ensure_configured() {
  [[ -f "$XRAY_CONFIG" && -f "$XRAY_SERVICE" ]] || die "Xray upstream не настроен. Запустите: $0 configure"
}

cmd="${1:-status}"
shift || true
case "$cmd" in
  configure) cmd_configure "${1:-}" ;;
  status) cmd_status ;;
  start) ensure_configured; systemctl start phobos-xray-upstream; cmd_status ;;
  stop) systemctl stop phobos-xray-upstream 2>/dev/null || true; [[ -x "$XRAY_FW" ]] && "$XRAY_FW" down 2>/dev/null || true; cmd_status ;;
  restart) ensure_configured; systemctl restart phobos-xray-upstream; cmd_status ;;
  logs) journalctl -u phobos-xray-upstream -n 80 --no-pager 2>/dev/null || true ;;
  disable) cmd_disable ;;
  *) usage; exit 1 ;;
esac
