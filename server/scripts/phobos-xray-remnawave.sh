#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PHOBOS_DIR="/opt/Phobos"
SERVER_DIR="$PHOBOS_DIR/server"
XRAY_CONFIG="$SERVER_DIR/xray-remnawave.json"
XRAY_SOURCE_CONFIG="$SERVER_DIR/xray-remnawave-source.json"
XRAY_ENV="$SERVER_DIR/xray-remnawave.env"
ROUTING_SCRIPT="$SERVER_DIR/xray-remnawave-routing.sh"
SERVICE_FILE="/etc/systemd/system/phobos-xray-remnawave.service"
SERVICE_NAME="phobos-xray-remnawave"
XRAY_BIN="/usr/local/bin/xray"
DEFAULT_TPROXY_PORT="12345"
DEFAULT_MARK="1"
DEFAULT_TABLE="100"
DEFAULT_WG_IFACE="wg0"
DEFAULT_OUTBOUND_TAG="vps2-remnawave"

log_info() { echo "[INFO] $*"; }
log_ok() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_err() { echo "[ERROR] $*" >&2; }
die() { log_err "$*"; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run as root: sudo $0 $*"
  fi
}

ensure_dirs() {
  mkdir -p "$SERVER_DIR"
  chmod 700 "$SERVER_DIR"
}

install_packages() {
  local missing=()
  for cmd in curl jq ip iptables systemctl python3 base64; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log_info "Installing dependencies: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq iproute2 iptables systemd python3 coreutils ca-certificates unzip kmod >/dev/null
  else
    die "Automatic dependency installation is implemented only for Debian/Ubuntu. Missing: ${missing[*]}"
  fi
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    log_ok "Xray is already installed: $XRAY_BIN"
    return 0
  fi

  log_info "Installing Xray core with the official XTLS installer"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-logfiles

  [[ -x "$XRAY_BIN" ]] || die "Xray binary was not installed at $XRAY_BIN"
  log_ok "Xray installed"
}

fetch_subscription() {
  local sub_url="$1"
  local out_file="$2"
  local tmp
  tmp=$(mktemp)

  log_info "Fetching Remnawave subscription"
  if ! curl -fsSL \
      -H 'User-Agent: v2rayN/7 Phobos-Xray-Remnawave' \
      -H 'Accept: application/json,text/plain,*/*' \
      "$sub_url" -o "$tmp"; then
    rm -f "$tmp"
    die "Failed to fetch subscription URL"
  fi

  if jq . "$tmp" >/dev/null 2>&1; then
    cp "$tmp" "$out_file"
    rm -f "$tmp"
    log_ok "Subscription returned Xray JSON"
    return 0
  fi

  local decoded
  decoded=$(mktemp)
  if base64 -d "$tmp" > "$decoded" 2>/dev/null; then
    if grep -Eq '(vless|vmess|trojan)://' "$decoded"; then
      cp "$decoded" "$out_file"
      rm -f "$tmp" "$decoded"
      log_ok "Subscription returned base64 share links"
      return 0
    fi
  fi

  if grep -Eq '(vless|vmess|trojan)://' "$tmp"; then
    cp "$tmp" "$out_file"
    rm -f "$tmp" "$decoded"
    log_ok "Subscription returned plain share links"
    return 0
  fi

  rm -f "$tmp" "$decoded"
  die "Subscription is neither valid Xray JSON nor supported share links. Use the Remnawave Xray JSON subscription URL, often the /json variant."
}

share_uri_to_xray_json() {
  local source_file="$1"
  local tag="$2"
  local first_uri
  first_uri=$(grep -Eo '(vless|vmess|trojan)://[^[:space:]]+' "$source_file" | head -n 1 || true)
  [[ -n "$first_uri" ]] || die "No supported share URI found in subscription"

  python3 - "$first_uri" "$tag" <<'PYCONVERT'
import base64
import json
import sys
import urllib.parse

uri = sys.argv[1]
tag = sys.argv[2]


def q(params, key, default=""):
    return params.get(key, [default])[0]


def split_list(value):
    if not value:
        return []
    return [x for x in value.split(',') if x]


def add_tls_like_settings(stream, params, kind):
    sni = q(params, 'sni') or q(params, 'peer') or q(params, 'host')
    fp = q(params, 'fp') or 'chrome'
    alpn = split_list(q(params, 'alpn'))
    if kind == 'reality':
        stream['realitySettings'] = {
            'serverName': sni,
            'fingerprint': fp,
            'publicKey': q(params, 'pbk'),
            'shortId': q(params, 'sid'),
            'spiderX': urllib.parse.unquote(q(params, 'spx') or '/')
        }
    elif kind == 'tls':
        tls = {'serverName': sni, 'fingerprint': fp}
        if alpn:
            tls['alpn'] = alpn
        stream['tlsSettings'] = tls


def add_network_settings(stream, params, network):
    host = q(params, 'host') or q(params, 'sni')
    path = urllib.parse.unquote(q(params, 'path') or '/')
    if network == 'ws':
        settings = {'path': path}
        if host:
            settings['headers'] = {'Host': host}
        stream['wsSettings'] = settings
    elif network == 'grpc':
        stream['grpcSettings'] = {'serviceName': q(params, 'serviceName') or q(params, 'service')}
    elif network in ('xhttp', 'splithttp'):
        settings = {'path': path}
        if host:
            settings['host'] = host
        mode = q(params, 'mode')
        if mode:
            settings['mode'] = mode
        stream['xhttpSettings'] = settings
    elif network == 'httpupgrade':
        settings = {'path': path}
        if host:
            settings['host'] = host
        stream['httpupgradeSettings'] = settings
    elif network == 'tcp' and (q(params, 'headerType') == 'http'):
        stream['tcpSettings'] = {
            'header': {
                'type': 'http',
                'request': {
                    'path': [path],
                    'headers': {'Host': [host] if host else []}
                }
            }
        }


if uri.startswith('vmess://'):
    raw = uri[len('vmess://'):]
    pad = '=' * (-len(raw) % 4)
    data = json.loads(base64.urlsafe_b64decode(raw + pad).decode())
    network = data.get('net') or 'tcp'
    security = data.get('tls') or 'none'
    stream = {'network': network, 'security': security}
    params = {k: [str(v)] for k, v in data.items() if v is not None}
    add_tls_like_settings(stream, params, security)
    add_network_settings(stream, params, network)
    outbound = {
        'protocol': 'vmess',
        'tag': tag,
        'settings': {
            'vnext': [{
                'address': data['add'],
                'port': int(data.get('port') or 443),
                'users': [{
                    'id': data['id'],
                    'alterId': int(data.get('aid') or 0),
                    'security': data.get('scy') or 'auto'
                }]
            }]
        },
        'streamSettings': stream
    }
else:
    u = urllib.parse.urlparse(uri)
    params = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    network = q(params, 'type') or q(params, 'network') or 'tcp'
    security = q(params, 'security') or 'none'
    stream = {'network': network, 'security': security}
    add_tls_like_settings(stream, params, security)
    add_network_settings(stream, params, network)

    if u.scheme == 'vless':
        user = {'id': urllib.parse.unquote(u.username or ''), 'encryption': q(params, 'encryption') or 'none'}
        flow = q(params, 'flow')
        if flow:
            user['flow'] = flow
        outbound = {
            'protocol': 'vless',
            'tag': tag,
            'settings': {'vnext': [{'address': u.hostname, 'port': int(u.port or 443), 'users': [user]}]},
            'streamSettings': stream
        }
    elif u.scheme == 'trojan':
        outbound = {
            'protocol': 'trojan',
            'tag': tag,
            'settings': {'servers': [{'address': u.hostname, 'port': int(u.port or 443), 'password': urllib.parse.unquote(u.username or '')}]},
            'streamSettings': stream
        }
    else:
        raise SystemExit(f'Unsupported URI scheme: {u.scheme}')

config = {
    'log': {'loglevel': 'warning'},
    'outbounds': [
        outbound,
        {'protocol': 'freedom', 'tag': 'direct'},
        {'protocol': 'blackhole', 'tag': 'block'}
    ]
}
print(json.dumps(config, ensure_ascii=False, indent=2))
PYCONVERT
}

build_tproxy_inbound() {
  local port="$1"
  jq -n --argjson port "$port" '{
    "tag": "phobos-tproxy",
    "port": $port,
    "protocol": "dokodemo-door",
    "settings": {
      "network": "tcp,udp",
      "followRedirect": true
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    },
    "streamSettings": {
      "sockopt": {
        "tproxy": "tproxy"
      }
    }
  }'
}

normalize_xray_config() {
  local source_file="$1"
  local tag="$2"
  local port="$3"
  local tmp_json
  tmp_json=$(mktemp)

  if jq . "$source_file" >/dev/null 2>&1; then
    cp "$source_file" "$tmp_json"
  else
    share_uri_to_xray_json "$source_file" "$tag" > "$tmp_json"
  fi

  if ! jq -e 'type == "object" and (.outbounds | type == "array") and ((.outbounds | length) > 0)' "$tmp_json" >/dev/null; then
    rm -f "$tmp_json"
    die "Xray JSON must contain a non-empty outbounds array"
  fi

  local first_index
  first_index=$(jq -r '
    [.outbounds[] | (.tag // "")] as $tags
    | [range(0; $tags|length) | select(($tags[.] | test("^(direct|freedom|block|blackhole|dns|api)$"; "i") | not))][0] // 0
  ' "$tmp_json")

  local tagged
  tagged=$(mktemp)
  jq --argjson idx "$first_index" --arg tag "$tag" '
    .outbounds[$idx].tag = ((.outbounds[$idx].tag // "") | if . == "" then $tag else . end)
  ' "$tmp_json" > "$tagged"

  local proxy_tag
  proxy_tag=$(jq -r --argjson idx "$first_index" '.outbounds[$idx].tag' "$tagged")
  [[ -n "$proxy_tag" && "$proxy_tag" != "null" ]] || proxy_tag="$tag"

  local inbound
  inbound=$(build_tproxy_inbound "$port")

  jq --argjson inbound "$inbound" --arg proxy_tag "$proxy_tag" '
    .log = (.log // {"loglevel": "warning"})
    | .inbounds = ([.inbounds[]? | select((.tag // "") != "phobos-tproxy")] | [$inbound] + .)
    | .routing = (.routing // {})
    | .routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch")
    | .routing.rules = ([
        {"type": "field", "inboundTag": ["phobos-tproxy"], "outboundTag": $proxy_tag}
      ] + ((.routing.rules // []) | map(select(((.inboundTag // []) | tostring | contains("phobos-tproxy")) | not))))
  ' "$tagged" > "$XRAY_CONFIG"

  chmod 600 "$XRAY_CONFIG"
  cp "$source_file" "$XRAY_SOURCE_CONFIG"
  chmod 600 "$XRAY_SOURCE_CONFIG"
  rm -f "$tmp_json" "$tagged"

  log_ok "Xray config built: $XRAY_CONFIG"
  log_ok "Remnawave outbound tag: $proxy_tag"
}

write_env() {
  local sub_url="$1"
  local tag="$2"
  local tproxy_port="$3"
  local mark="$4"
  local table="$5"
  local wg_iface="$6"

  {
    printf 'SUBSCRIPTION_URL=%q\n' "$sub_url"
    printf 'OUTBOUND_TAG=%q\n' "$tag"
    printf 'TPROXY_PORT=%q\n' "$tproxy_port"
    printf 'TPROXY_MARK=%q\n' "$mark"
    printf 'TPROXY_TABLE=%q\n' "$table"
    printf 'WG_IFACE=%q\n' "$wg_iface"
  } > "$XRAY_ENV"
  chmod 600 "$XRAY_ENV"
}

write_routing_script() {
  local tproxy_port="$1"
  local mark="$2"
  local table="$3"
  local wg_iface="$4"

  cat > "$ROUTING_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TPROXY_PORT="$tproxy_port"
TPROXY_MARK="$mark"
TPROXY_TABLE="$table"
WG_IFACE="$wg_iface"
CHAIN="PHOBOS_XRAY"

add_rule_once() {
  local table_name="\$1"
  local chain="\$2"
  shift 2
  iptables -t "\$table_name" -C "\$chain" "\$@" 2>/dev/null || iptables -t "\$table_name" -A "\$chain" "\$@"
}

up() {
  modprobe xt_TPROXY 2>/dev/null || true
  modprobe nf_tproxy_ipv4 2>/dev/null || true
  modprobe iptable_mangle 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  ip rule add fwmark "\$TPROXY_MARK" table "\$TPROXY_TABLE" 2>/dev/null || true
  ip route add local 0.0.0.0/0 dev lo table "\$TPROXY_TABLE" 2>/dev/null || true

  iptables -t mangle -N "\$CHAIN" 2>/dev/null || true
  iptables -t mangle -F "\$CHAIN"

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
    iptables -t mangle -A "\$CHAIN" -d "\$cidr" -j RETURN
  done

  iptables -t mangle -A "\$CHAIN" -p tcp -j TPROXY --on-port "\$TPROXY_PORT" --tproxy-mark "\$TPROXY_MARK"
  iptables -t mangle -A "\$CHAIN" -p udp -j TPROXY --on-port "\$TPROXY_PORT" --tproxy-mark "\$TPROXY_MARK"
  add_rule_once mangle PREROUTING -i "\$WG_IFACE" -j "\$CHAIN"
}

down() {
  iptables -t mangle -D PREROUTING -i "\$WG_IFACE" -j "\$CHAIN" 2>/dev/null || true
  iptables -t mangle -F "\$CHAIN" 2>/dev/null || true
  iptables -t mangle -X "\$CHAIN" 2>/dev/null || true
  ip rule del fwmark "\$TPROXY_MARK" table "\$TPROXY_TABLE" 2>/dev/null || true
  ip route flush table "\$TPROXY_TABLE" 2>/dev/null || true
}

case "\${1:-}" in
  up) up ;;
  down) down ;;
  restart) down; up ;;
  *) echo "Usage: \$0 {up|down|restart}" >&2; exit 1 ;;
esac
EOF
  chmod 700 "$ROUTING_SCRIPT"
  log_ok "Routing helper written: $ROUTING_SCRIPT"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Phobos Xray route to VPS2 Remnawave
Wants=network-online.target
After=network-online.target wg-quick@wg0.service

[Service]
Type=simple
ExecStartPre=$ROUTING_SCRIPT up
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
ExecStopPost=$ROUTING_SCRIPT down
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  log_ok "Systemd service written: $SERVICE_FILE"
}

test_xray_config() {
  if [[ -x "$XRAY_BIN" ]]; then
    log_info "Testing Xray config"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null
    log_ok "Xray config test passed"
  fi
}

configure() {
  local sub_url="$1"
  local tag="${2:-$DEFAULT_OUTBOUND_TAG}"
  local tproxy_port="${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}"
  local mark="${TPROXY_MARK:-$DEFAULT_MARK}"
  local table="${TPROXY_TABLE:-$DEFAULT_TABLE}"
  local wg_iface="${WG_IFACE:-$DEFAULT_WG_IFACE}"

  [[ -n "$sub_url" ]] || die "Subscription URL is required"

  require_root
  ensure_dirs
  install_packages
  install_xray

  local raw
  raw=$(mktemp)
  fetch_subscription "$sub_url" "$raw"
  normalize_xray_config "$raw" "$tag" "$tproxy_port"
  rm -f "$raw"

  write_env "$sub_url" "$tag" "$tproxy_port" "$mark" "$table" "$wg_iface"
  write_routing_script "$tproxy_port" "$mark" "$table" "$wg_iface"
  write_service
  test_xray_config

  systemctl enable --now "$SERVICE_NAME"
  log_ok "Enabled route: Phobos WireGuard clients -> Xray -> VPS2 Remnawave"
}

refresh() {
  require_root
  [[ -f "$XRAY_ENV" ]] || die "No saved configuration. Run: $0 configure <remnawave_subscription_url> [tag]"
  # shellcheck disable=SC1090
  source "$XRAY_ENV"
  local raw
  raw=$(mktemp)
  fetch_subscription "$SUBSCRIPTION_URL" "$raw"
  normalize_xray_config "$raw" "${OUTBOUND_TAG:-$DEFAULT_OUTBOUND_TAG}" "${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}"
  rm -f "$raw"
  test_xray_config
  systemctl restart "$SERVICE_NAME"
  log_ok "Subscription refreshed and service restarted"
}

enable_service() {
  require_root
  [[ -f "$SERVICE_FILE" ]] || die "Service is not configured. Run configure first."
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  log_ok "Service enabled"
}

disable_service() {
  require_root
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  if [[ -x "$ROUTING_SCRIPT" ]]; then
    "$ROUTING_SCRIPT" down || true
  fi
  log_ok "Service disabled and routing rules removed"
}

status() {
  echo "== $SERVICE_NAME =="
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  echo
  echo "== saved env =="
  if [[ -f "$XRAY_ENV" ]]; then
    sed 's/^SUBSCRIPTION_URL=.*/SUBSCRIPTION_URL=<hidden>/' "$XRAY_ENV"
  else
    echo "not configured"
  fi
  echo
  echo "== tproxy rules =="
  iptables -t mangle -S PHOBOS_XRAY 2>/dev/null || echo "no PHOBOS_XRAY chain"
}

show_config() {
  [[ -f "$XRAY_CONFIG" ]] || die "No config at $XRAY_CONFIG"
  jq . "$XRAY_CONFIG"
}

usage() {
  cat <<EOF
Usage:
  $0 configure <remnawave_subscription_url> [outbound_tag]
  $0 refresh
  $0 enable
  $0 disable
  $0 status
  $0 show-config

Environment overrides for configure:
  TPROXY_PORT=$DEFAULT_TPROXY_PORT TPROXY_MARK=$DEFAULT_MARK TPROXY_TABLE=$DEFAULT_TABLE WG_IFACE=$DEFAULT_WG_IFACE
EOF
}

case "${1:-}" in
  configure)
    shift
    configure "${1:-}" "${2:-$DEFAULT_OUTBOUND_TAG}"
    ;;
  refresh)
    refresh
    ;;
  enable)
    enable_service
    ;;
  disable)
    disable_service
    ;;
  status)
    status
    ;;
  show-config)
    show_config
    ;;
  *)
    usage
    exit 1
    ;;
esac
