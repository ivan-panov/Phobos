#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_DATA="${1:-}"

source "$SCRIPT_DIR/lib-core.sh"

check_root

echo "=========================================="
echo "  Удаление Phobos VPS"
echo "=========================================="
echo ""


remove_xray_remnawave_phobos() {
  local xray_config="/usr/local/etc/xray/config.json"
  local xray_dir="/usr/local/etc/xray"
  local managed_marker="/usr/local/etc/xray/phobos-managed"
  local installed_marker="/usr/local/etc/xray/phobos-installed-by-phobos"
  local phobos_managed=0
  local phobos_installed=0

  echo ""
  echo "==> Удаление Phobos Xray/Remnawave..."

  if [[ -x "$SCRIPT_DIR/phobos-xray-remnawave.sh" ]]; then
    "$SCRIPT_DIR/phobos-xray-remnawave.sh" disable >/dev/null 2>&1 || true
  fi

  systemctl stop phobos-xray-remnawave-watchdog.timer 2>/dev/null || true
  systemctl disable phobos-xray-remnawave-watchdog.timer 2>/dev/null || true
  systemctl stop phobos-xray-remnawave-watchdog.service 2>/dev/null || true
  systemctl disable phobos-xray-remnawave-watchdog.service 2>/dev/null || true
  systemctl stop phobos-xray-remnawave-rules.service 2>/dev/null || true
  systemctl disable phobos-xray-remnawave-rules.service 2>/dev/null || true

  rm -f /etc/systemd/system/phobos-xray-remnawave-watchdog.timer
  rm -f /etc/systemd/system/phobos-xray-remnawave-watchdog.service
  rm -f /etc/systemd/system/phobos-xray-remnawave-rules.service
  rm -f /usr/local/sbin/phobos-xray-remnawave-watchdog.sh

  # Remove TPROXY/routing leftovers even if the helper script is already gone.
  iptables -t mangle -D PREROUTING -i wg0 -p tcp -m socket -j XRAY_PHOBOS_DIVERT 2>/dev/null || true
  iptables -t mangle -D PREROUTING -s 10.25.0.0/16 -i wg0 -j XRAY_PHOBOS 2>/dev/null || true
  iptables -t mangle -F XRAY_PHOBOS 2>/dev/null || true
  iptables -t mangle -X XRAY_PHOBOS 2>/dev/null || true
  iptables -t mangle -F XRAY_PHOBOS_DIVERT 2>/dev/null || true
  iptables -t mangle -X XRAY_PHOBOS_DIVERT 2>/dev/null || true
  ip rule del fwmark 1 table phobos_xray 2>/dev/null || true
  ip route flush table phobos_xray 2>/dev/null || true
  sed -i '/^[[:space:]]*100[[:space:]]\+phobos_xray$/d' /etc/iproute2/rt_tables 2>/dev/null || true

  [[ -f "$managed_marker" ]] && phobos_managed=1
  if [[ -f "$installed_marker" ]]; then
    phobos_installed=1
    phobos_managed=1
  fi

  if [[ -f "$xray_config" ]] && grep -qE 'phobos-tproxy|phobos-socks-test|vps2-remnawave' "$xray_config" 2>/dev/null; then
    phobos_managed=1
  fi

  if [[ -f /etc/systemd/system/xray.service.d/phobos-tproxy.conf ]]; then
    phobos_managed=1
  fi

  rm -f /etc/systemd/system/xray.service.d/phobos-tproxy.conf
  rm -f /etc/systemd/system/xray.service.d/phobos-restart.conf
  rm -f /etc/systemd/system/xray.service.d/20-phobos-run-as-root.conf

  if [[ -d /etc/systemd/system/xray.service.d ]] && ! find /etc/systemd/system/xray.service.d -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true
  fi

  if [[ "$phobos_managed" == "1" ]]; then
    systemctl stop xray 2>/dev/null || true
    rm -f "$xray_config" "$managed_marker" "$installed_marker"
    echo "  ✓ Phobos Xray config удалён"
  else
    echo "  - Phobos Xray config не найден, системный Xray не тронут"
  fi

  if [[ "$phobos_installed" == "1" ]]; then
    systemctl disable xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray
    rmdir "$xray_dir" 2>/dev/null || true
    echo "  ✓ Xray, установленный Phobos, удалён"
  elif [[ "$phobos_managed" == "1" ]]; then
    echo "  - Xray binary/service оставлены: нет маркера установки Phobos"
  fi

  systemctl daemon-reload
}

if [[ "$KEEP_DATA" != "--keep-data" ]]; then
  echo "ВНИМАНИЕ: Это действие удалит все компоненты Phobos:"
  echo "  - Systemd сервисы (WireGuard, obfuscator, HTTP, Phobos Xray/Remnawave)"
  echo "  - Все конфигурации клиентов"
  echo "  - Ключи и сертификаты"
  echo "  - Логи и данные"
  echo ""
  echo "Для сохранения клиентских данных запустите: $0 --keep-data"
  echo ""
  read -p "Вы уверены? Введите 'yes' для подтверждения: " confirmation

  if [[ "$confirmation" != "yes" ]]; then
    echo "Отмена удаления"
    exit 0
  fi
fi

echo ""
echo "==> Остановка и удаление systemd сервисов..."

remove_xray_remnawave_phobos

if systemctl is-active --quiet wg-obfuscator 2>/dev/null; then
  systemctl stop wg-obfuscator
  echo "  ✓ wg-obfuscator остановлен"
fi

if systemctl is-enabled --quiet wg-obfuscator 2>/dev/null; then
  systemctl disable wg-obfuscator
  echo "  ✓ wg-obfuscator отключен из автозапуска"
fi

if [[ -f /etc/systemd/system/wg-obfuscator.service ]]; then
  rm /etc/systemd/system/wg-obfuscator.service
  echo "  ✓ wg-obfuscator.service удален"
fi

if systemctl is-active --quiet phobos-http 2>/dev/null; then
  systemctl stop phobos-http
  echo "  ✓ phobos-http остановлен"
fi

if systemctl is-enabled --quiet phobos-http 2>/dev/null; then
  systemctl disable phobos-http
  echo "  ✓ phobos-http отключен из автозапуска"
fi

if [[ -f /etc/systemd/system/phobos-http.service ]]; then
  rm /etc/systemd/system/phobos-http.service
  echo "  ✓ phobos-http.service удален"
fi

if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
  systemctl stop wg-quick@wg0
  echo "  ✓ WireGuard остановлен"
fi

if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
  systemctl disable wg-quick@wg0
  echo "  ✓ WireGuard отключен из автозапуска"
fi

if systemctl is-active --quiet wg-quick@wg-exit 2>/dev/null; then
  systemctl stop wg-quick@wg-exit
  echo "  ✓ Cascade wg-exit остановлен"
fi

if systemctl is-enabled --quiet wg-quick@wg-exit 2>/dev/null; then
  systemctl disable wg-quick@wg-exit
  echo "  ✓ Cascade wg-exit отключен из автозапуска"
fi

systemctl daemon-reload
echo "  ✓ Systemd daemon перезагружен"

echo ""
echo "==> Удаление WireGuard конфигурации..."

if [[ -f /etc/wireguard/wg0.conf ]]; then
  rm /etc/wireguard/wg0.conf
  echo "  ✓ wg0.conf удален"
fi

if [[ -f /etc/wireguard/wg-exit.conf ]]; then
  rm /etc/wireguard/wg-exit.conf
  echo "  ✓ wg-exit.conf удален"
fi

if [[ -f /etc/sysctl.d/99-phobos.conf ]]; then
  rm /etc/sysctl.d/99-phobos.conf
  sysctl -p 2>/dev/null || true
  echo "  ✓ 99-phobos.conf удален"
fi

echo ""
echo "==> Удаление cron задач..."

if [[ -f /etc/cron.d/phobos-cleanup ]]; then
  rm /etc/cron.d/phobos-cleanup
  echo "  ✓ /etc/cron.d/phobos-cleanup удален"
else
  echo "  - Cron задачи не найдены"
fi

echo ""
echo "==> Удаление бинарных файлов..."

if [[ -f /usr/local/bin/wg-obfuscator ]]; then
  rm /usr/local/bin/wg-obfuscator
  echo "  ✓ wg-obfuscator удален"
fi

if [[ -L /usr/local/bin/phobos ]]; then
  rm /usr/local/bin/phobos
  echo "  ✓ phobos (симлинк) удален"
fi

if [[ "$KEEP_DATA" == "--keep-data" ]]; then
  echo ""
  echo "==> Сохранение клиентских данных..."

  BACKUP_DIR="/root/phobos-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"

  if [[ -d "$PHOBOS_DIR/clients" ]]; then
    cp -r "$PHOBOS_DIR/clients" "$BACKUP_DIR/"
    echo "  ✓ Клиенты сохранены в $BACKUP_DIR/clients"
  fi

  if [[ -d "$PHOBOS_DIR/packages" ]]; then
    cp -r "$PHOBOS_DIR/packages" "$BACKUP_DIR/"
    echo "  ✓ Пакеты сохранены в $BACKUP_DIR/packages"
  fi

  if [[ -f "$PHOBOS_DIR/server/server.env" ]]; then
    cp "$PHOBOS_DIR/server/server.env" "$BACKUP_DIR/"
    echo "  ✓ Конфигурация (включая ключи) сохранена в $BACKUP_DIR/server.env"
  fi

  echo ""
  echo "  Резервная копия создана: $BACKUP_DIR"
fi

echo ""
echo "==> Удаление директорий..."

if [[ -d "$PHOBOS_DIR" ]]; then
  rm -rf "$PHOBOS_DIR"
  echo "  ✓ $PHOBOS_DIR удален"
fi

echo ""
echo "=========================================="
echo "  Phobos успешно удален!"
echo "=========================================="
echo ""

if [[ "$KEEP_DATA" == "--keep-data" ]]; then
  echo "Резервная копия данных: $BACKUP_DIR"
  echo ""
fi

echo "Для полной очистки системы также удалите:"
echo "  - WireGuard: apt remove --purge wireguard wireguard-tools"
echo "  - Xray не удалён автоматически, если он не был помечен как установленный Phobos"
echo "  - Зависимости: apt autoremove"
echo ""
