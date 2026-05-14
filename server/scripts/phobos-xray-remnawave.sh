#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PHOBOS_DIR="/opt/Phobos"
SERVER_DIR="$PHOBOS_DIR/server"
SERVER_ENV="$SERVER_DIR/server.env"
XRAY_CONFIG="$SERVER_DIR/xray-remnawave.json"
XRAY_SOURCE_CONFIG="$SERVER_DIR/xray-remnawave-source.json"
XRAY_ENV="$SERVER_DIR/xray-remnawave.env"
ROUTING_SCRIPT="$SERVER_DIR/xray-remnawave-routing.sh"
SERVICE_FILE="/etc/systemd/system/phobos-xray-remnawave.service"
SERVICE_NAME="phobos-xray-remnawave"
XRAY_BIN="/usr/local/bin/xray"
DEFAULT_TPROXY_PORT="12345"
DEFAULT_SOCKS_PORT="10808"
DEFAULT_MARK="1"
DEFAULT_TABLE="100"
DEFAULT_WG_IFACE="wg0"
DEFAULT_OUTBOUND_TAG="vps2-remnawave"
DEFAULT_REMNAWAVE_UA="v2rayNG/1.10.5"
DEFAULT_DEVICE_OS="Linux"
DEFAULT_DEVICE_MODEL="Phobos-VPS1"

log_info() { echo "[INFO] $*"; }
log_ok() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_err() { echo "[ERROR] $*" >&2; }
die() { log_err "$*"; exit 1; }

save_server_env_var() {
  local key="$1"
  local value="$2"
  mkdir -p "$SERVER_DIR"
  touch "$SERVER_ENV"
  if grep -qE "^${key}=" "$SERVER_ENV"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_ENV"
  else
    echo "${key}=${value}" >> "$SERVER_ENV"
  fi
}

enable_vps2_only_mode() {
  save_server_env_var PHOBOS_VPS2_ONLY 1
  save_server_env_var PHOBOS_VPS2_MODE xray-remnawave

  local fw_script="$SERVER_DIR/wg0-fw.sh"
  if [[ -x "$fw_script" ]]; then
    PHOBOS_VPS2_ONLY=1 "$fw_script" killswitch-up || log_warn "Failed to apply wg0 VPS1 leak kill-switch via $fw_script"
  else
    log_warn "wg0 firewall helper not found: $fw_script. Re-run the Phobos installer or apply the VPS1 leak kill-switch manually."
  fi
}


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

json_variant_url() {
  local url="$1"
  python3 - "$url" <<'PYURL'
import sys
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
path = u.path.rstrip('/')
if not path.endswith('/json'):
    path = path + '/json'
print(urlunsplit((u.scheme, u.netloc, path, u.query, u.fragment)))
PYURL
}

machine_hwid() {
  if [[ -n "${REMNAWAVE_HWID:-}" ]]; then
    printf '%s\n' "$REMNAWAVE_HWID"
    return 0
  fi
  if [[ -n "${PHOBOS_REMNAWAVE_HWID:-}" ]]; then
    printf '%s\n' "$PHOBOS_REMNAWAVE_HWID"
    return 0
  fi
  if [[ -r /etc/machine-id ]]; then
    printf 'phobos-vps1-%s\n' "$(sha256sum /etc/machine-id | awk '{print substr($1,1,24)}')"
    return 0
  fi
  printf 'phobos-vps1-%s\n' "$(hostname | sha256sum | awk '{print substr($1,1,24)}')"
}

curl_subscription_once() {
  local url="$1"
  local body_file="$2"
  local meta_file="$3"
  local header_file
  header_file=$(mktemp)

  local ua="${REMNAWAVE_USER_AGENT:-$DEFAULT_REMNAWAVE_UA}"
  local hwid
  hwid="$(machine_hwid)"

  local code
  set +e
  code=$(curl -sSL \
    --connect-timeout "${REMNAWAVE_CONNECT_TIMEOUT:-15}" \
    --max-time "${REMNAWAVE_MAX_TIME:-60}" \
    -D "$header_file" \
    -o "$body_file" \
    -w '%{http_code}' \
    -H "User-Agent: ${ua}" \
    -H 'Accept: application/json,text/plain,*/*' \
    -H "x-hwid: ${hwid}" \
    -H "x-device-os: ${REMNAWAVE_DEVICE_OS:-$DEFAULT_DEVICE_OS}" \
    -H "x-device-model: ${REMNAWAVE_DEVICE_MODEL:-$DEFAULT_DEVICE_MODEL}" \
    "$url")
  local rc=$?
  set -e

  local ctype=""
  ctype=$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$header_file" | tr -d '\r' || true)
  local hwid_problem=""
  hwid_problem=$(awk 'BEGIN{IGNORECASE=1} /^x-hwid-not-supported:/ || /^x-hwid-limit:/ || /^x-hwid-active:/ {print}' "$header_file" | tr -d '\r' | paste -sd '; ' - || true)
  {
    printf 'rc=%s\n' "$rc"
    printf 'http_code=%s\n' "${code:-000}"
    printf 'content_type=%s\n' "$ctype"
    printf 'hwid_headers=%s\n' "$hwid_problem"
    printf 'user_agent=%s\n' "$ua"
  } > "$meta_file"
  rm -f "$header_file"

  [[ "$rc" -eq 0 && "${code:-000}" =~ ^2[0-9][0-9]$ ]]
}

subscription_body_supported() {
  local in_file="$1"
  local decoded

  [[ -s "$in_file" ]] || return 1

  if jq . "$in_file" >/dev/null 2>&1; then
    return 0
  fi

  decoded=$(mktemp)
  if base64 -d "$in_file" > "$decoded" 2>/dev/null; then
    if grep -Eq '(vless|vmess|trojan|ss)://' "$decoded"; then
      rm -f "$decoded"
      return 0
    fi
  fi
  rm -f "$decoded"

  grep -Eq '(vless|vmess|trojan|ss)://' "$in_file"
}

save_supported_subscription_body() {
  local in_file="$1"
  local out_file="$2"
  local decoded

  if jq . "$in_file" >/dev/null 2>&1; then
    cp "$in_file" "$out_file"
    log_ok "Subscription returned Xray JSON"
    return 0
  fi

  decoded=$(mktemp)
  if base64 -d "$in_file" > "$decoded" 2>/dev/null; then
    if grep -Eq '(vless|vmess|trojan|ss)://' "$decoded"; then
      cp "$decoded" "$out_file"
      rm -f "$decoded"
      log_ok "Subscription returned base64 share links"
      return 0
    fi
  fi
  rm -f "$decoded"

  if grep -Eq '(vless|vmess|trojan|ss)://' "$in_file"; then
    cp "$in_file" "$out_file"
    log_ok "Subscription returned plain share links"
    return 0
  fi

  return 1
}

fetch_subscription() {
  local sub_url="$1"
  local out_file="$2"
  local tmp meta json_url tmp_json meta_json
  tmp=$(mktemp)
  meta=$(mktemp)
  tmp_json=$(mktemp)
  meta_json=$(mktemp)

  log_info "Fetching Remnawave subscription"
  if curl_subscription_once "$sub_url" "$tmp" "$meta" && subscription_body_supported "$tmp"; then
    save_supported_subscription_body "$tmp" "$out_file"
    rm -f "$tmp" "$meta" "$tmp_json" "$meta_json"
    return 0
  fi

  json_url="$(json_variant_url "$sub_url")"
  if [[ "$json_url" != "$sub_url" ]]; then
    log_warn "Bare URL did not return usable Xray data; retrying explicit /json subscription endpoint"
    if curl_subscription_once "$json_url" "$tmp_json" "$meta_json" && subscription_body_supported "$tmp_json"; then
      save_supported_subscription_body "$tmp_json" "$out_file"
      rm -f "$tmp" "$meta" "$tmp_json" "$meta_json"
      return 0
    fi
  fi

  log_err "Remnawave subscription fetch failed or returned unsupported content."
  log_err "First attempt: $(tr '\n' ' ' < "$meta")"
  if [[ "$json_url" != "$sub_url" ]]; then
    log_err "JSON attempt: $(tr '\n' ' ' < "$meta_json")"
  fi
  if grep -qiE '<html|<!doctype html' "$tmp" "$tmp_json" 2>/dev/null; then
    log_err "The endpoint returned HTML. Use the user's subscription URL, not the browser landing/admin URL, or force /json."
  fi
  if grep -qi 'x-hwid-not-supported' "$meta" "$meta_json" 2>/dev/null; then
    log_err "The panel likely has HWID enabled. Set REMNAWAVE_HWID=<stable-id> and run configure again."
  fi
  rm -f "$tmp" "$meta" "$tmp_json" "$meta_json"
  die "Use a Remnawave user subscription URL like https://sub.example.com/<shortUuid> or https://sub.example.com/<shortUuid>/json."
}

share_uri_to_xray_json() {
  local source_file="$1"
  local tag="$2"
  local first_uri
  first_uri=$(grep -Eo '(vless|vmess|trojan|ss)://[^[:space:]]+' "$source_file" | head -n 1 || true)
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
    elif u.scheme == 'ss':
        # SIP002: ss://base64(method:password)@host:port or ss://base64(method:password@host:port)
        raw = uri[len('ss://'):].split('#', 1)[0]
        raw = raw.split('?', 1)[0]
        method = password = address = None
        port = None
        if '@' in raw:
            userinfo, server = raw.rsplit('@', 1)
            pad = '=' * (-len(userinfo) % 4)
            decoded_userinfo = base64.urlsafe_b64decode(userinfo + pad).decode()
            method, password = decoded_userinfo.split(':', 1)
            if server.startswith('['):
                address, port_s = server.rsplit(']:', 1)
                address = address[1:]
            else:
                address, port_s = server.rsplit(':', 1)
            port = int(port_s)
        else:
            pad = '=' * (-len(raw) % 4)
            decoded = base64.urlsafe_b64decode(raw + pad).decode()
            userinfo, server = decoded.rsplit('@', 1)
            method, password = userinfo.split(':', 1)
            if server.startswith('['):
                address, port_s = server.rsplit(']:', 1)
                address = address[1:]
            else:
                address, port_s = server.rsplit(':', 1)
            port = int(port_s)
        outbound = {
            'protocol': 'shadowsocks',
            'tag': tag,
            'settings': {'servers': [{'address': address, 'port': port, 'method': method, 'password': password}]}
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

build_socks_test_inbound() {
  local port="$1"
  jq -n --argjson port "$port" '{
    "tag": "phobos-socks-test",
    "listen": "127.0.0.1",
    "port": $port,
    "protocol": "socks",
    "settings": {
      "auth": "noauth",
      "udp": true
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }'
}

normalize_xray_config() {
  local source_file="$1"
  local tag="$2"
  local port="$3"
  local socks_port="${4:-$DEFAULT_SOCKS_PORT}"
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

  local inbound socks_inbound
  inbound=$(build_tproxy_inbound "$port")
  socks_inbound=$(build_socks_test_inbound "$socks_port")

  jq --argjson inbound "$inbound" --argjson socks_inbound "$socks_inbound" --arg proxy_tag "$proxy_tag" '
    .log = (.log // {"loglevel": "warning"})
    | .inbounds = ([.inbounds[]? | select(((.tag // "") != "phobos-tproxy") and ((.tag // "") != "phobos-socks-test"))] | [$inbound, $socks_inbound] + .)
    | .routing = (.routing // {})
    | .routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch")
    | .routing.rules = ([
        {"type": "field", "inboundTag": ["phobos-socks-test"], "outboundTag": $proxy_tag},
        {"type": "field", "inboundTag": ["phobos-tproxy"], "outboundTag": $proxy_tag}
      ] + ((.routing.rules // []) | map(select((((.inboundTag // []) | tostring | contains("phobos-tproxy")) or (((.inboundTag // []) | tostring | contains("phobos-socks-test"))) | not))))
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
  local socks_port="${7:-$DEFAULT_SOCKS_PORT}"

  {
    printf 'SUBSCRIPTION_URL=%q\n' "$sub_url"
    printf 'OUTBOUND_TAG=%q\n' "$tag"
    printf 'TPROXY_PORT=%q\n' "$tproxy_port"
    printf 'TPROXY_MARK=%q\n' "$mark"
    printf 'TPROXY_TABLE=%q\n' "$table"
    printf 'WG_IFACE=%q\n' "$wg_iface"
    printf 'SOCKS_TEST_PORT=%q\n' "$socks_port"
    printf 'REMNAWAVE_USER_AGENT=%q\n' "${REMNAWAVE_USER_AGENT:-$DEFAULT_REMNAWAVE_UA}"
    printf 'REMNAWAVE_HWID=%q\n' "$(machine_hwid)"
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

remove_ipv4_rule() {
  while iptables "\$@" 2>/dev/null; do :; done
}

remove_ipv6_rule() {
  while ip6tables "\$@" 2>/dev/null; do :; done
}

get_default_iface() {
  ip -4 route show default | awk '/^default/{print \$5; exit}'
}

apply_vps2_killswitch() {
  local wan_iface
  wan_iface="\$(get_default_iface || true)"
  [[ -n "\$wan_iface" ]] || return 0

  # Fail closed: packets from Phobos clients must never be forwarded directly
  # from VPS1 to its public WAN. If Xray/VPS2 is down, connections fail instead
  # of revealing VPS1 IP.
  remove_ipv4_rule -D FORWARD -i "\$WG_IFACE" -o "\$wan_iface" -j REJECT --reject-with icmp-net-unreachable
  iptables -I FORWARD 1 -i "\$WG_IFACE" -o "\$wan_iface" -j REJECT --reject-with icmp-net-unreachable

  # IPv6 TPROXY is intentionally blocked until a real IPv6 VPS2 path exists.
  if command -v ip6tables >/dev/null 2>&1; then
    remove_ipv6_rule -D FORWARD -i "\$WG_IFACE" -j REJECT
    ip6tables -I FORWARD 1 -i "\$WG_IFACE" -j REJECT
  fi
}

up() {
  modprobe xt_TPROXY 2>/dev/null || true
  modprobe nf_tproxy_ipv4 2>/dev/null || true
  modprobe iptable_mangle 2>/dev/null || true
  modprobe xt_REJECT 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  apply_vps2_killswitch

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
  # Do not remove the VPS2-only kill-switch here. Service stop/restart must not
  # create a direct VPS1 fallback window.
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
Description=Phobos VPS1 Xray route to VPS2 Remnawave
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
  local socks_port="${SOCKS_TEST_PORT:-$DEFAULT_SOCKS_PORT}"
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
  normalize_xray_config "$raw" "$tag" "$tproxy_port" "$socks_port"
  rm -f "$raw"

  write_env "$sub_url" "$tag" "$tproxy_port" "$mark" "$table" "$wg_iface" "$socks_port"
  write_routing_script "$tproxy_port" "$mark" "$table" "$wg_iface"
  write_service
  test_xray_config
  enable_vps2_only_mode

  systemctl enable --now "$SERVICE_NAME"
  log_ok "Enabled route: Phobos WireGuard clients -> VPS1 Xray -> VPS2 Remnawave"
  log_ok "VPS1 leak kill-switch enabled: Phobos clients cannot bypass VPS2 via VPS1 WAN"
}

refresh() {
  require_root
  [[ -f "$XRAY_ENV" ]] || die "No saved configuration. Run: $0 configure <remnawave_subscription_url> [tag]"
  # shellcheck disable=SC1090
  source "$XRAY_ENV"
  local raw
  raw=$(mktemp)
  fetch_subscription "$SUBSCRIPTION_URL" "$raw"
  normalize_xray_config "$raw" "${OUTBOUND_TAG:-$DEFAULT_OUTBOUND_TAG}" "${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}" "${SOCKS_TEST_PORT:-$DEFAULT_SOCKS_PORT}"
  rm -f "$raw"
  test_xray_config
  systemctl restart "$SERVICE_NAME"
  log_ok "Subscription refreshed and service restarted"
}

enable_service() {
  require_root
  [[ -f "$SERVICE_FILE" ]] || die "Service is not configured. Run configure first."
  systemctl daemon-reload
  enable_vps2_only_mode
  systemctl enable --now "$SERVICE_NAME"
  log_ok "Service enabled"
  log_ok "VPS1 leak kill-switch enabled"
}

disable_service() {
  require_root
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  if [[ -x "$ROUTING_SCRIPT" ]]; then
    "$ROUTING_SCRIPT" down || true
  fi
  log_ok "Service disabled and routing rules removed"
  log_warn "VPS1 leak kill-switch is intentionally kept so clients cannot leak via VPS1 WAN"
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
  echo
  echo "== local SOCKS test listener =="
  ss -lntup 2>/dev/null | grep -E ":${SOCKS_TEST_PORT:-10808}\b" || echo "SOCKS test listener not found"
  echo
  echo "== VPS1 leak kill-switch: direct wg0 -> WAN blocked =="
  iptables -S FORWARD 2>/dev/null | grep -E "^-A FORWARD -i ${WG_IFACE:-wg0} .* -j REJECT" || echo "IPv4 kill-switch rule not found"
  ip6tables -S FORWARD 2>/dev/null | grep -E "^-A FORWARD -i ${WG_IFACE:-wg0} .* -j REJECT" || echo "IPv6 kill-switch rule not found or IPv6 disabled"
}

show_config() {
  [[ -f "$XRAY_CONFIG" ]] || die "No config at $XRAY_CONFIG"
  jq . "$XRAY_CONFIG"
}

test_connection() {
  require_root
  [[ -f "$XRAY_ENV" ]] || die "No saved configuration. Run: $0 configure <remnawave_subscription_url> [tag]"
  # shellcheck disable=SC1090
  source "$XRAY_ENV"
  local socks_port="${SOCKS_TEST_PORT:-$DEFAULT_SOCKS_PORT}"

  systemctl is-active --quiet "$SERVICE_NAME" || systemctl start "$SERVICE_NAME"

  echo "== Xray service =="
  systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,18p' || true
  echo
  echo "== Local SOCKS test, should trigger Remnawave online status =="
  echo "Using socks5h://127.0.0.1:${socks_port}"

  local rc=0
  curl -4 -sS --max-time 25 --socks5-hostname "127.0.0.1:${socks_port}" https://api.ipify.org || rc=$?
  echo

  if [[ "$rc" -eq 0 ]]; then
    log_ok "VPS1 -> Xray -> Remnawave/VPS2 test request succeeded. Refresh Remnawave: the user should no longer show 'Не подключался'."
    return 0
  fi

  log_err "SOCKS test failed. Last Xray logs:"
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  die "Xray did not establish a working outbound connection to the Remnawave node. Check subscription, HWID, node status, SNI/REALITY settings, firewall, and system time."
}

usage() {
  cat <<EOF
Usage:
  $0 configure <remnawave_subscription_url> [outbound_tag]
  $0 refresh
  $0 enable
  $0 disable
  $0 status
  $0 test
  $0 show-config

Environment overrides for configure:
  TPROXY_PORT=$DEFAULT_TPROXY_PORT SOCKS_TEST_PORT=$DEFAULT_SOCKS_PORT TPROXY_MARK=$DEFAULT_MARK TPROXY_TABLE=$DEFAULT_TABLE WG_IFACE=$DEFAULT_WG_IFACE
  REMNAWAVE_USER_AGENT=$DEFAULT_REMNAWAVE_UA REMNAWAVE_HWID=<stable-device-id>
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
  test)
    test_connection
    ;;
  show-config)
    show_config
    ;;
  *)
    usage
    exit 1
    ;;
esac
