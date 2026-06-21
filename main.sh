#!/bin/bash
# ==============================================================================
# FastNodeDebian — main.sh
# Debian 9 / 10 / 11 / 12 / 13 Server Automation
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# SCRIPT_DIR: при curl|bash устанавливается из run.sh, иначе вычисляем сами
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

MODULES_DIR="${SCRIPT_DIR}/modules"
CONFIG_DIR="${SCRIPT_DIR}/config"
LOGS_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOGS_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"

# ── Проверка конфига ────────────────────────────────────────────────────────

if [[ ! -f "${CONFIG_DIR}/settings.conf" ]]; then
    echo -e "${RED}[ERROR] Конфиг не найден: ${CONFIG_DIR}/settings.conf${NC}"
    exit 1
fi
source "${CONFIG_DIR}/settings.conf"

# ── Логирование ─────────────────────────────────────────────────────────────

mkdir -p "${LOGS_DIR}"

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >> "${LOG_FILE}"; }
info()    { _log "INFO"    "$@"; echo -e "${CYAN} ℹ${NC} $*"; }
warn()    { _log "WARN"    "$@"; echo -e "${YELLOW} ⚠${NC} $*"; }
error()   { _log "ERROR"   "$@"; echo -e "${RED} ✗${NC} $*"; }
success() { _log "SUCCESS" "$@"; echo -e "${GREEN} ✓${NC} $*"; }

export -f info warn error success _log

# ── Проверки запуска ─────────────────────────────────────────────────────────

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error "Запустите скрипт от root: sudo bash main.sh"
        exit 1
    fi
}

check_debian() {
    if ! grep -qi "debian" /etc/os-release 2>/dev/null && [[ ! -r /etc/debian_version ]]; then
        error "Этот скрипт предназначен для Debian 9–13"
        exit 1
    fi

    local ver major codename
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
    codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
    major="${ver%%.*}"

    if [[ -z "${major}" ]]; then
        warn "Не удалось точно определить версию Debian — продолжаем"
    elif [[ "${major}" -lt 9 ]]; then
        warn "Debian ${ver} (${codename}) — слишком старая, поддерживаются 9–13"
    elif [[ "${major}" -gt 13 ]]; then
        info "Debian ${ver} (${codename}) — новее протестированных, обычно работает ✓"
    else
        info "Debian ${ver} (${codename}) — поддерживается ✓"
    fi
}

# ── Запуск модуля ────────────────────────────────────────────────────────────

run_module() {
    local module="$1"
    local path="${MODULES_DIR}/${module}"

    if [[ ! -f "${path}" ]]; then
        warn "Модуль не найден: ${path}"
        return 1
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE} Модуль: ${BOLD}${module}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    export LOG_FILE SCRIPT_DIR CONFIG_DIR MODULES_DIR

    if bash "${path}"; then
        success "Модуль ${module} — выполнен"
    else
        warn "Модуль ${module} завершился с ошибкой (код: $?)"
    fi
}

run_all() {
    info "Запуск всех модулей настройки (1-8)..."
    # 00-system-update (ребут!) и 09-xanmod (ребут!) запускаются ТОЛЬКО вручную
    for mod in $(ls -1 "${MODULES_DIR}"/*.sh 2>/dev/null | sort); do
        local name
        name="$(basename "${mod}")"
        if [[ "${name}" == "00-system-update.sh" || "${name}" == "09-xanmod-v3.sh" ]]; then
            continue
        fi
        run_module "${name}"
    done

    echo ""
    printf "${YELLOW} Запустить 09-xanmod-v3.sh (установка ядра, требует перезагрузку)? (y/n): ${NC}"
    local run_xanmod
    read -r run_xanmod </dev/tty
    if [[ "${run_xanmod}" =~ ^[Yy]$ ]]; then
        run_module "09-xanmod-v3.sh"
    else
        info "Пропускаем XanMod. Запустите позже: bash modules/09-xanmod-v3.sh"
    fi
}

# ── Главное меню ─────────────────────────────────────────────────────────────

show_menu() {
    clear
    echo ""
    echo -e "${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║   ⚡ FastNodeDebian v1.0 — Debian 9 → 13         ║${NC}"
    echo -e "${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}10${NC}) Поэтапное обновление Debian (9→10→11→12→13) ${YELLOW}[reboot]${NC}"
    echo ""
    echo -e "  ${CYAN} 1${NC}) Обновление пакетов системы"
    echo -e "  ${CYAN} 2${NC}) Настройка локали (${LOCALE_LANG})"
    echo -e "  ${CYAN} 3${NC}) Синхронизация времени (${TIMEZONE})"
    echo -e "  ${CYAN} 4${NC}) Установка SSH ключа"
    echo -e "  ${CYAN} 5${NC}) SSH Hardening (порт ${SSH_PORT})"
    echo -e "  ${CYAN} 6${NC}) Настройка SWAP (выбор: 1/2/3/4 GB)"
    echo -e "  ${CYAN} 7${NC}) Настройка UFW Firewall"
    echo -e "  ${CYAN} 8${NC}) Настройка Fail2Ban"
    echo -e "  ${CYAN} 9${NC}) XanMod ядро + BBRv3 ${YELLOW}[требует reboot, Debian 12/13]${NC}"
    echo ""
    echo -e "  ${GREEN}111${NC}) Выполнить ВСЕ модули настройки (1-8 + опционально 9)"
    echo -e "  ${RED}  0${NC}) Выход"
    echo ""
    echo -e "  ${BLUE}Конфиг:${NC} ${CONFIG_DIR}/settings.conf"
    echo -e "  ${BLUE}Лог:${NC}    ${LOG_FILE}"
    echo ""
}

# ── Точка входа ─────────────────────────────────────────────────────────────

main() {
    check_root
    check_debian

    info "FastNodeDebian v1.0.0 | Ядро: $(uname -r) | Дата: $(date '+%Y-%m-%d %H:%M')"

    # Автоматический режим (INTERACTIVE_MODE=false bash main.sh)
    if [[ "${INTERACTIVE_MODE:-true}" == "false" ]]; then
        run_all
        success "Настройка завершена! Лог: ${LOG_FILE}"
        return 0
    fi

    # Интерактивный режим
    while true; do
        show_menu
        printf "  Выберите модуль: "
        local choice
        read -r choice </dev/tty

        case "${choice}" in
            10|00) run_module "00-system-update.sh" ;;
            1)   run_module "01-packet-update.sh" ;;
            2)   run_module "02-locale-setup.sh" ;;
            3)   run_module "03-time-sync.sh" ;;
            4)   run_module "04-ssh-key.sh" ;;
            5)   run_module "05-ssh-hardening.sh" ;;
            6)   run_module "06-swap-setup.sh" ;;
            7)   run_module "07-ufw-setup.sh" ;;
            8)   run_module "08-fail2ban-setup.sh" ;;
            9)   run_module "09-xanmod-v3.sh" ;;
            111) run_all ;;
            0)   info "Выход"; echo ""; exit 0 ;;
            *)   echo -e "  ${RED}Неверный выбор: ${choice}${NC}" ;;
        esac

        echo ""
        printf "  Нажмите Enter для возврата в меню..."
        read -r </dev/tty
    done
}

main "$@"
