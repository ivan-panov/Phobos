#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
    exit 1
}

log_message() {
    echo -e "${GREEN}$1${NC}"
}

wait_for_apt_locks() {
    local waited=0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    while true; do
        local busy=0
        for lock in "${locks[@]}"; do
            if fuser "$lock" >/dev/null 2>&1; then
                busy=1
                break
            fi
        done
        [[ "$busy" -eq 0 ]] && return 0
        if (( waited >= 300 )); then
            echo -e "${YELLOW}apt/dpkg lock занят больше 5 минут. Продолжаю попытку, apt сам вернет ошибку если lock не освободился.${NC}" >&2
            return 0
        fi
        echo -e "${YELLOW}Жду apt/dpkg lock... ${waited}s${NC}" >&2
        sleep 5
        waited=$((waited + 5))
    done
}

_collect_child_pids() {
    local parent="$1"
    local child
    pgrep -P "$parent" 2>/dev/null | while read -r child; do
        [[ -z "$child" ]] && continue
        echo "$child"
        _collect_child_pids "$child"
    done
}

run_logged_command() {
    local max_seconds="$1"
    local log_file="$2"
    local label="$3"
    shift 3

    : > "$log_file"
    echo "Лог: $log_file"
    "$@" >>"$log_file" 2>&1 &
    local pid=$!
    local started
    started=$(date +%s)
    local last_line=""
    local last_report=0

    while kill -0 "$pid" 2>/dev/null; do
        local now elapsed p stat current_line
        now=$(date +%s)
        elapsed=$((now - started))

        for p in $pid $(_collect_child_pids "$pid"); do
            stat=$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ' || true)
            if [[ "$stat" == T* ]]; then
                echo -e "\n${YELLOW}${label}: процесс $p был остановлен (STAT=T), возобновляю kill -CONT.${NC}" >&2
                kill -CONT "$p" 2>/dev/null || true
            fi
        done

        if (( elapsed > max_seconds )); then
            echo -e "\n${RED}${label}: таймаут ${max_seconds}s. Останавливаю процесс.${NC}" >&2
            kill -TERM "$pid" 2>/dev/null || true
            sleep 3
            kill -KILL "$pid" 2>/dev/null || true
            tail -n 60 "$log_file" >&2 || true
            return 124
        fi

        if (( now - last_report >= 5 )); then
            current_line=$(grep -v '^$' "$log_file" | tail -n 1 || true)
            if [[ -n "$current_line" && "$current_line" != "$last_line" ]]; then
                echo "[apt] $current_line"
                last_line="$current_line"
            else
                echo "[apt] ${label}... ${elapsed}s"
            fi
            last_report=$now
        fi
        sleep 1
    done

    wait "$pid"
}

trap 'error_exit "Неожиданная ошибка в строке $LINENO"' ERR

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Скрипт должен быть запущен с правами root"
    fi
}

install_git() {
    if ! command -v git &> /dev/null; then
        log_message "Git не найден. Установка..."
        if [ -f /etc/debian_version ]; then
            export DEBIAN_FRONTEND=noninteractive
            export NEEDRESTART_MODE=a
            export APT_LISTCHANGES_FRONTEND=none
            APT_LOG="/tmp/phobos-deploy-apt.log"
            wait_for_apt_locks
            run_logged_command 600 "$APT_LOG" "apt-get update"                 apt-get -o Acquire::ForceIPv4=true update -q || {
                tail -n 40 "$APT_LOG" >&2 || true
                error_exit "Не удалось обновить список пакетов. Лог: $APT_LOG"
            }
            wait_for_apt_locks
            run_logged_command 600 "$APT_LOG" "apt-get install git"                 apt-get -o Acquire::ForceIPv4=true install -y -q git || {
                tail -n 40 "$APT_LOG" >&2 || true
                error_exit "Не удалось установить git. Лог: $APT_LOG"
            }
        else
            error_exit "Неподдерживаемая ОС"
        fi
    fi
}

clone_repository() {
    PHOBOS_BASE_DIR="/opt/Phobos"
    REPO_DIR="$PHOBOS_BASE_DIR/repo"

    if [ -d "$REPO_DIR" ]; then
        log_message "Удаление существующего репозитория..."
        rm -rf "$REPO_DIR"
    fi

    mkdir -p "$REPO_DIR"

    log_message "Клонирование репозитория Phobos..."

    cd "$REPO_DIR"
    git init >/dev/null 2>&1
    git remote add origin https://github.com/ivan-panov/Phobos.git >/dev/null 2>&1
    git config core.sparseCheckout true >/dev/null 2>&1

    echo "server" > .git/info/sparse-checkout
    echo "client" >> .git/info/sparse-checkout
    echo "wg-obfuscator" >> .git/info/sparse-checkout

    git pull origin main >/dev/null 2>&1 || error_exit "Не удалось загрузить репозиторий"
    rm -rf .git >/dev/null 2>&1

    find server -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    find client -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

    log_message "Репозиторий загружен"
}

prompt_username() {
    echo
    if [ -t 1 ]; then
        exec < /dev/tty
    fi

    while true; do
        read -p "Введите имя первого клиента: " username
        if [ -z "$username" ]; then
            echo "Имя не может быть пустым"
            continue
        fi
        if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Некорректное имя. Используйте только буквы, цифры, _ и -"
            continue
        fi
        break
    done

    export FIRST_CLIENT="$username"
    log_message "Имя клиента: $username"
}

prompt_obfuscation_level() {
    echo ""
    echo "=========================================="
    echo "    Выберите уровень маскировки трафика"
    echo "=========================================="
    echo ""
    echo "  1) Легкая"
    echo "  2) Достаточная"
    echo "  3) Средняя"
    echo "  4) Выше среднего"
    echo "  5) Кошмар!"
    echo ""

    while true; do
        read -p "Ваш выбор [1-5]: " choice
        case "$choice" in
            1|2|3|4|5)
                export OBF_LEVEL="$choice"
                break
                ;;
            *)
                echo "Некорректный ввод. Введите число от 1 до 5."
                ;;
        esac
    done
}

run_installer() {
    REPO_DIR="/opt/Phobos/repo"
    INSTALLER="$REPO_DIR/server/scripts/phobos-installer.sh"

    if [ ! -f "$INSTALLER" ]; then
        error_exit "Установщик не найден: $INSTALLER"
    fi

    chmod +x "$INSTALLER"
    log_message "Запуск установки Phobos..."
    "$INSTALLER" || error_exit "Ошибка установки"
    log_message "Установка завершена"
}

add_first_client() {
    CLIENT_SCRIPT="/opt/Phobos/repo/server/scripts/phobos-client.sh"

    if [ ! -f "$CLIENT_SCRIPT" ]; then
        error_exit "Скрипт управления клиентами не найден"
    fi

    local retries=0
    while ! ip link show wg0 >/dev/null 2>&1; do
        retries=$((retries + 1))
        [ "$retries" -ge 15 ] && error_exit "Интерфейс wg0 не поднялся"
        sleep 1
    done

    log_message "Создание клиента $FIRST_CLIENT..."
    "$CLIENT_SCRIPT" add "$FIRST_CLIENT" || error_exit "Ошибка создания клиента"
    log_message "Клиент $FIRST_CLIENT создан"
}

check_root
install_git
clone_repository
prompt_username
prompt_obfuscation_level
run_installer
add_first_client

echo ""
log_message "=========================================="
log_message "  Развертывание Phobos завершено!"
log_message "=========================================="
log_message "Клиент '$FIRST_CLIENT' создан."
log_message "Запустите 'phobos' для управления системой."
echo ""
