#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "$SCRIPT_DIR" != "/opt/Phobos/repo/server/scripts" ]]; then
  echo "[INFO] Копирование файлов репозитория в /opt/Phobos/repo..."
  mkdir -p /opt/Phobos/repo
  cp -r "$REPO_ROOT"/* /opt/Phobos/repo/
  rm -rf /opt/Phobos/repo/.git 2>/dev/null || true

  if [[ -x "/opt/Phobos/repo/server/scripts/phobos-installer.sh" ]]; then
    echo "[INFO] Перезапуск установщика из /opt/Phobos/repo..."
    exec /opt/Phobos/repo/server/scripts/phobos-installer.sh "$@"
  fi
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib-core.sh"

check_root

OBF_LEVEL="${OBF_LEVEL:-2}"

get_obf_params() {
  local level="${1:-2}"
  case "$level" in
    1) echo "3 4" ;;
    2) echo "6 10" ;;
    3) echo "20 20" ;;
    4) echo "50 50" ;;
    5) echo "255 100" ;;
    *) echo "6 10" ;;
  esac
}


choose_public_endpoint() {
  local detected_ip="$1"
  local endpoint="${SERVER_PUBLIC_ENDPOINT:-${PHOBOS_PUBLIC_ENDPOINT:-}}"

  if [[ -n "$endpoint" ]]; then
    endpoint="$(sanitize_public_endpoint "$endpoint")"
    if is_valid_public_endpoint "$endpoint"; then
      echo "$endpoint"
      return 0
    fi
    log_warn "SERVER_PUBLIC_ENDPOINT/PHOBOS_PUBLIC_ENDPOINT имеет неверный формат: $endpoint"
  fi

  echo "" >&2
  echo "Какой публичный адрес использовать в клиентских конфигурациях?" >&2
  echo "  1) IPv4 VPS: ${detected_ip}" >&2
  echo "  2) Домен, например vpn.example.com" >&2
  echo "  3) Другой IPv4" >&2
  read -rp "Выбор [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    2)
      while true; do
        read -rp "Введите домен без http:// и без порта: " endpoint
        endpoint="$(sanitize_public_endpoint "$endpoint")"
        if is_valid_public_endpoint "$endpoint" && [[ ! "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "$endpoint"
          return 0
        fi
        log_error "Неверный домен. Пример: vpn.example.com"
      done
      ;;
    3)
      while true; do
        read -rp "Введите публичный IPv4 VPS: " endpoint
        endpoint="$(sanitize_public_endpoint "$endpoint")"
        if [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "$endpoint"
          return 0
        fi
        log_error "Неверный IPv4. Пример: 89.125.122.115"
      done
      ;;
    *)
      echo "$detected_ip"
      return 0
      ;;
  esac
}

log_info "Остановка существующих служб Phobos..."
systemctl stop wg-obfuscator 2>/dev/null || true
systemctl stop phobos-http 2>/dev/null || true
systemctl stop wg-quick@wg0 2>/dev/null || true

spin() {
  local pid=$1
  local msg=$2
  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  while kill -0 "$pid" 2>/dev/null; do
    for (( i=0; i<${#chars}; i++ )); do
      printf "\r[%s] %s" "${chars:$i:1}" "$msg"
      sleep 0.1
    done
  done
  printf "\r"
}

show_apt_tail() {
  local log_file="$1"
  if [[ -f "$log_file" ]]; then
    echo "" >&2
    log_error "Последние строки apt-лога ($log_file):"
    tail -n 40 "$log_file" >&2 || true
  fi
}

step_deps() {
  log_info "Установка зависимостей..."

  local apt_log="/tmp/phobos-install-apt.log"
  : > "$apt_log"

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none

  log_info "apt log: $apt_log"

  if ! timeout 600 apt-get -o Acquire::ForceIPv4=true update -qq >>"$apt_log" 2>&1; then
    show_apt_tail "$apt_log"
    die "apt-get update не завершился. Проверьте интернет, DNS, apt lock или IPv6/IPv4 маршрутизацию."
  fi

  if ! timeout 900 apt-get -o Acquire::ForceIPv4=true install -y -qq \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      wireguard jq curl build-essential ufw >>"$apt_log" 2>&1; then
    show_apt_tail "$apt_log"
    die "Не удалось установить зависимости. Подробности выше и в $apt_log"
  fi

  log_success "Зависимости установлены."
}

step_build() {
  log_info "Копирование бинарников wg-obfuscator..."

  if [[ -d "$REPO_DIR/wg-obfuscator/bin" ]]; then
    cp -f "$REPO_DIR/wg-obfuscator/bin"/wg-obfuscator-* "$PHOBOS_DIR/bin/" 2>/dev/null || true
  fi

  local arch=$(uname -m)
  if [[ ! -f "$PHOBOS_DIR/bin/wg-obfuscator-$arch" ]]; then
    log_error "Бинарник wg-obfuscator для $arch не найден!"
    exit 1
  fi

  chmod +x "$PHOBOS_DIR/bin/wg-obfuscator-$arch"
  ln -sf "$PHOBOS_DIR/bin/wg-obfuscator-$arch" /usr/local/bin/wg-obfuscator
  chmod +x /usr/local/bin/wg-obfuscator
  log_success "Бинарник wg-obfuscator установлен"

  log_info "Сборка darkhttpd..."
  local darkhttpd_version="1.16"
  local darkhttpd_url="https://github.com/emikulic/darkhttpd/archive/refs/tags/v${darkhttpd_version}.tar.gz"
  local build_dir="/tmp/darkhttpd-build"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  if ! curl -sL "$darkhttpd_url" | tar -xz -C "$build_dir" --strip-components=1; then
    log_error "Не удалось скачать darkhttpd"
    exit 1
  fi

  if ! make -C "$build_dir" darkhttpd >/dev/null 2>&1; then
    log_error "Не удалось собрать darkhttpd"
    exit 1
  fi

  cp "$build_dir/darkhttpd" "$PHOBOS_DIR/bin/darkhttpd"
  chmod +x "$PHOBOS_DIR/bin/darkhttpd"
  ln -sf "$PHOBOS_DIR/bin/darkhttpd" /usr/local/bin/darkhttpd
  rm -rf "$build_dir"

  log_success "darkhttpd собран и установлен"
}

step_wg() {
  log_info "Настройка WireGuard..."
  mkdir -p /etc/wireguard

  local priv=$(wg genkey)
  local pub=$(echo "$priv" | wg pubkey)
  local wg_ipv4_net="10.25.0.0/16"
  local wg_ipv6_net="fd00:10:25::/48"
  local wg_ipv4_addr="10.25.0.1/16"
  local wg_ipv6_addr="fd00:10:25::1/48"
  local pub_ip_v6=""
  pub_ip_v6=$(get_public_ipv6 2>/dev/null || true)
  local ipv6_enabled=0
  [[ -n "$pub_ip_v6" ]] && ipv6_enabled=1

  cat > "$SERVER_ENV" <<EOF
SERVER_WG_PRIVATE_KEY=$priv
SERVER_WG_PUBLIC_KEY=$pub
SERVER_WG_IPV4_NETWORK=$wg_ipv4_net
SERVER_WG_IPV6_NETWORK=$wg_ipv6_net
PHOBOS_IPV6_ENABLED=$ipv6_enabled
EOF

  local iface=$(ip route | grep default | awk '{print $5}' | head -1)
  local address_line="$wg_ipv4_addr"
  local postup="iptables -A FORWARD -i wg0 -o wg0 -j DROP; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE"
  local postdown="iptables -D FORWARD -i wg0 -o wg0 -j DROP; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE"

  if [[ "$ipv6_enabled" == "1" ]]; then
    address_line="$wg_ipv4_addr, $wg_ipv6_addr"
    postup="$postup; ip6tables -A FORWARD -i wg0 -o wg0 -j DROP; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $iface -j MASQUERADE"
    postdown="$postdown; ip6tables -D FORWARD -i wg0 -o wg0 -j DROP; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $iface -j MASQUERADE"
    log_info "IPv6 обнаружен ($pub_ip_v6) — включаю IPv6 в WireGuard"
  else
    log_warn "Публичный IPv6 не обнаружен — WireGuard будет настроен только на IPv4"
  fi

  cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $address_line
ListenPort = 51820
PrivateKey = $priv
PostUp = $postup
PostDown = $postdown
EOF
  chmod 600 "$WG_CONFIG"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  {
    echo "net.ipv4.ip_forward=1"
    if [[ "$ipv6_enabled" == "1" ]]; then
      echo "net.ipv6.conf.all.forwarding=1"
    fi
  } > /etc/sysctl.d/99-phobos.conf
  sysctl -p /etc/sysctl.d/99-phobos.conf >/dev/null

  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0
  log_success "WireGuard настроен"
}

get_public_ipv6() {
  local iface=$(ip route | grep default | awk '{print $5}' | head -1)
  [[ -z "$iface" ]] && return

  local ipv6=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+' | grep -v '^f[cd]' | head -1)
  [[ -n "$ipv6" ]] && echo "$ipv6"
}

step_obf() {
  log_info "Настройка Obfuscator..."

  local params=$(get_obf_params "$OBF_LEVEL")
  local key_len=$(echo "$params" | cut -d' ' -f1)
  local dummy=$(echo "$params" | cut -d' ' -f2)

  local port=$(find_free_port 1024 49151)
  local key=$(head -c $((key_len * 2)) /dev/urandom | base64 | tr -d '+/=\n' | head -c "$key_len")
  local pub_ip_v4
  pub_ip_v4=$(get_public_ipv4) || true
  if [[ -z "$pub_ip_v4" ]]; then
    log_warn "Не удалось определить публичный IP автоматически"
    while true; do
      read -rp "Введите публичный IPv4 сервера: " pub_ip_v4
      [[ "$pub_ip_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
      log_error "Неверный формат IP, повторите"
    done
  fi
  local public_endpoint
  public_endpoint=$(choose_public_endpoint "$pub_ip_v4")

  local pub_ip_v6=""
  if [[ "${PHOBOS_IPV6_ENABLED:-0}" == "1" ]]; then
    pub_ip_v6=$(get_public_ipv6 2>/dev/null || true)
  fi

  cat >> "$SERVER_ENV" <<EOF
OBFUSCATOR_PORT=$port
OBFUSCATOR_KEY=$key
OBFUSCATOR_DUMMY=$dummy
OBFUSCATOR_IDLE=300
OBFUSCATOR_MASKING=STUN
SERVER_PUBLIC_IP_V4=$pub_ip_v4
SERVER_PUBLIC_ENDPOINT=$public_endpoint
SERVER_PUBLIC_IP_V6=$pub_ip_v6
WG_LOCAL_ENDPOINT=127.0.0.1:51820
CLIENT_WG_PORT=13255
EOF

  cat > /etc/systemd/system/wg-obfuscator.service <<EOF
[Unit]
Description=WireGuard Traffic Obfuscator
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wg-obfuscator --config /opt/Phobos/server/wg-obfuscator.conf
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wg-obfuscator

  cat > "$OBF_CONFIG" <<EOF
[instance]
source-if = 0.0.0.0
source-lport = $port
target = 127.0.0.1:51820
key = $key
masking = STUN
verbose = INFO
idle-timeout = 300
max-dummy = $dummy
EOF

  systemctl restart wg-obfuscator
  log_success "Obfuscator настроен на порту $port"
}

step_http() {
  log_info "Настройка HTTP сервера..."

  local port=$(find_free_port 1024 49151)

  cat > /etc/systemd/system/phobos-http.service <<EOF
[Unit]
Description=Phobos HTTP Distribution Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WWW_DIR
ExecStart=/usr/local/bin/darkhttpd $WWW_DIR --port $port --no-listing
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable phobos-http
  systemctl restart phobos-http

  echo "HTTP_PORT=$port" >> "$SERVER_ENV"

  log_success "HTTP сервер настроен на порту $port"
}

step_final() {
  log_info "Настройка Cron..."
  echo "*/10 * * * * root $REPO_DIR/server/scripts/phobos-system.sh cleanup" > /etc/cron.d/phobos-cleanup
  chmod 644 /etc/cron.d/phobos-cleanup

  log_info "Установка меню..."
  ln -sf "$REPO_DIR/server/scripts/phobos-menu.sh" /usr/local/bin/phobos

  print_required_ports

  log_success "Установка завершена! Запустите 'phobos' для управления системой."
}

ensure_dirs
step_deps
step_build
step_wg
step_obf
step_http
step_final
