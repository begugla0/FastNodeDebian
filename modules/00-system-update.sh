#!/bin/bash
# ==============================================================================
# Module 00: Поэтапное обновление дистрибутива Debian
#   9 (stretch) → 10 (buster) → 11 (bullseye) → 12 (bookworm) → 13 (trixie)
#
# Особенности:
#   - Обновляет ровно на ОДНУ мажорную версию за запуск, затем перезагрузка.
#   - Корректно переключает sources.list:
#       * stretch/buster      → archive.debian.org (EOL, Check-Valid-Until off)
#       * bullseye            → live-зеркало, авто-фолбэк на archive
#       * bookworm/trixie     → live-зеркало (deb.debian.org / security.debian.org)
#   - Формат security-suite: <=10 → "<codename>/updates", >=11 → "<codename>-security"
#   - Компонент non-free-firmware добавляется начиная с Debian 12.
#
# Режимы:
#   bash 00-system-update.sh                 # один шаг + запрос перезагрузки (ручной)
#   bash 00-system-update.sh --auto          # ВЕСЬ путь до 13 автоматически (с ребутами)
#   bash 00-system-update.sh --auto --target 12   # авто до выбранной версии
#   bash 00-system-update.sh --status        # показать текущее состояние
#   bash 00-system-update.sh --resume        # внутренний вызов из systemd после ребута
#   Флаги: --yes/-y (без подтверждений), --target N (целевая версия, по умолчанию 13)
#
# ⚠ Перед запуском сделайте резервную копию / снапшот! Операция необратима.
# ==============================================================================

set -uo pipefail

# ── Цвета: определяем ВСЕГДА ────────────────────────────────────────────────
# Важно при set -u: если info()/warn() унаследованы из main.sh, блок ниже
# пропускается, а эти функции обращаются к $CYAN/$GREEN/$BOLD. Поэтому цвета
# должны быть определены безусловно, иначе — "unbound variable".
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Fallback-функции (для standalone-запуска) ───────────────────────────────
if ! declare -f info > /dev/null 2>&1; then
    info()    { echo -e "${CYAN} ℹ ${*}${NC}"; }
    warn()    { echo -e "${YELLOW} ⚠ ${*}${NC}"; }
    success() { echo -e "${GREEN} ✓ ${*}${NC}"; }
    error()   { echo -e "${RED} ✗ ${*}${NC}"; }
fi

# ── Константы ────────────────────────────────────────────────────────────────
declare -A CODENAME=( [9]=stretch [10]=buster [11]=bullseye [12]=bookworm [13]=trixie )
DEFAULT_TARGET=13

STATE_DIR="/var/lib/fastnode-upgrade"
STATE_FILE="${STATE_DIR}/state.env"
SELF_INSTALL="/usr/local/sbin/fastnode-system-update.sh"
SERVICE_NAME="fastnode-upgrade.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
UPGRADE_LOG="/var/log/fastnode-upgrade.log"
ARCHIVE_CONF="/etc/apt/apt.conf.d/99fastnode-archive"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

# ── Логирование шага в файл ──────────────────────────────────────────────────
_ulog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${UPGRADE_LOG}" 2>/dev/null || true; }

# ── Определение текущей мажорной версии ──────────────────────────────────────
current_major() {
    local v=""
    if [[ -r /etc/os-release ]]; then
        v="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
    fi
    if [[ -z "${v}" && -r /etc/debian_version ]]; then
        local dv; dv="$(cut -d'.' -f1 /etc/debian_version 2>/dev/null)"
        if [[ "${dv}" =~ ^[0-9]+$ ]]; then
            v="${dv}"
        else
            # /etc/debian_version может содержать codename (напр. "trixie/sid")
            local cn; cn="$(echo "${dv}" | cut -d'/' -f1)"
            local k
            for k in "${!CODENAME[@]}"; do
                [[ "${CODENAME[$k]}" == "${cn}" ]] && v="${k}"
            done
        fi
    fi
    echo "${v%%.*}"
}

# ── Проверки окружения ───────────────────────────────────────────────────────
preflight() {
    if [[ ${EUID} -ne 0 ]]; then
        error "Запустите от root: sudo bash 00-system-update.sh"
        exit 1
    fi
    if ! grep -qi 'debian' /etc/os-release 2>/dev/null && [[ ! -r /etc/debian_version ]]; then
        error "Это не Debian. Скрипт предназначен только для Debian 9–13."
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd не обнаружен — авто-режим (--auto) будет недоступен."
    fi
    # Предупреждение по свободному месту на /
    local free_mb
    free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${free_mb}" && "${free_mb}" -lt 2048 ]]; then
        warn "Мало свободного места на / : ${free_mb} MB (рекомендуется ≥ 2048 MB)."
    fi
}

# ── Резервная копия источников APT ───────────────────────────────────────────
backup_apt() {
    local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
    [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "/etc/apt/sources.list.fastnode.${stamp}.bak"
    info "Бэкап sources.list → /etc/apt/sources.list.fastnode.${stamp}.bak"
}

# ── Временно отключаем сторонние репозитории (частая причина сбоя апгрейда) ──
disable_thirdparty() {
    local f changed=0
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -e "${f}" ]] || continue
        mv "${f}" "${f}.fastnode-disabled"
        warn "Отключён сторонний репозиторий: $(basename "${f}") (восстановите вручную после апгрейда)"
        changed=1
    done
    shopt -u nullglob
    [[ ${changed} -eq 1 ]] && _ulog "disabled third-party sources.list.d entries"
    return 0
}

# ── Запись /etc/apt/sources.list для конкретного релиза ──────────────────────
# Аргументы: <major> <codename> <mode: live|archive>
_write_sources() {
    local major="$1" cn="$2" mode="$3"
    local components="main contrib non-free"
    [[ "${major}" -ge 12 ]] && components="main contrib non-free non-free-firmware"

    local base sec sec_suite
    if [[ "${mode}" == "archive" ]]; then
        base="http://archive.debian.org/debian"
        sec="http://archive.debian.org/debian-security"
        # отключаем проверку срока действия Release для архива
        echo 'Acquire::Check-Valid-Until "false";' > "${ARCHIVE_CONF}"
    else
        base="http://deb.debian.org/debian"
        sec="http://security.debian.org/debian-security"
        rm -f "${ARCHIVE_CONF}" 2>/dev/null || true
    fi

    if [[ "${major}" -le 10 ]]; then
        sec_suite="${cn}/updates"          # stretch/buster: старый формат
    else
        sec_suite="${cn}-security"         # bullseye+: новый формат
    fi

    {
        echo "# Сгенерировано FastNodeDebian 00-system-update.sh ($(date))"
        echo "# Релиз: Debian ${major} (${cn}) | mode=${mode}"
        echo "deb ${base} ${cn} ${components}"
        echo "deb ${base} ${cn}-updates ${components}"
        echo "deb ${sec} ${sec_suite} ${components}"
    } > /etc/apt/sources.list
}

# ── Настроить источники с авто-фолбэком live→archive и проверкой apt update ──
# Аргументы: <major> <codename>
configure_sources() {
    local major="$1" cn="$2"
    local modes=()

    if [[ "${major}" -le 10 ]]; then
        modes=(archive)                    # stretch/buster всегда из архива
    elif [[ "${major}" -eq 11 ]]; then
        modes=(live archive)               # bullseye: live, иначе archive
    else
        modes=(live archive)               # bookworm/trixie: практически всегда live
    fi

    local m
    for m in "${modes[@]}"; do
        info "Источники для ${cn} (${m})..."
        _write_sources "${major}" "${cn}" "${m}"
        if apt-get update -o Acquire::Retries=3 >/dev/null 2>&1; then
            success "apt update OK (${cn}, ${m})"
            _ulog "sources configured: ${cn} ${m}"
            return 0
        fi
        warn "apt update не прошёл для ${cn} (${m})"
    done
    error "Не удалось настроить рабочие источники для ${cn}."
    return 1
}

# ── apt upgrade/full-upgrade с безопасными опциями ───────────────────────────
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

_do_upgrade() {
    apt-get upgrade "${APT_OPTS[@]}"      || warn "apt upgrade завершился с предупреждениями"
    apt-get full-upgrade "${APT_OPTS[@]}" || warn "apt full-upgrade завершился с предупреждениями"
    apt-get --purge autoremove -y         || true
    apt-get autoclean -y                  || true
}

# ── Полностью обновить ТЕКУЩИЙ релиз перед прыжком ──────────────────────────
update_current() {
    local cur="$1" cn="${CODENAME[$1]}"
    info "Приведение текущего релиза Debian ${cur} (${cn}) к актуальному состоянию..."
    configure_sources "${cur}" "${cn}" || return 1
    apt-get install -y debian-archive-keyring ca-certificates >/dev/null 2>&1 || true
    _do_upgrade
    success "Debian ${cur} обновлён в пределах релиза."
}

# ── Один прыжок: from → from+1 ───────────────────────────────────────────────
upgrade_one_hop() {
    local from="$1"
    local to=$(( from + 1 ))
    local to_cn="${CODENAME[$to]}"

    if [[ -z "${to_cn}" ]]; then
        error "Нет данных для перехода на Debian ${to}."
        return 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}   Апгрейд: Debian ${from} (${CODENAME[$from]}) → ${to} (${to_cn})${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _ulog "=== HOP ${from} -> ${to} (${to_cn}) START ==="

    # 1) Подтянуть текущий релиз
    update_current "${from}" || return 1

    # 2) Переключить источники на следующий релиз
    backup_apt
    configure_sources "${to}" "${to_cn}" || return 1

    # 3) Минимальный upgrade, затем полный dist-upgrade
    info "Этап 1/2: apt-get upgrade на ${to_cn}..."
    apt-get upgrade "${APT_OPTS[@]}" || warn "upgrade с предупреждениями"

    info "Этап 2/2: apt-get full-upgrade (dist-upgrade) на ${to_cn}..."
    apt-get full-upgrade "${APT_OPTS[@]}" || warn "full-upgrade с предупреждениями"

    apt-get --purge autoremove -y || true
    apt-get clean || true

    local new_major; new_major="$(current_major)"
    _ulog "=== HOP ${from} -> ${to} DONE, now reports ${new_major} ==="
    success "Переход на Debian ${to} (${to_cn}) выполнен. Текущая версия по системе: ${new_major}"
    info "Требуется ПЕРЕЗАГРУЗКА для активации нового ядра."
    return 0
}

# ── Установка self + systemd-юнита для авто-продолжения после ребутов ───────
install_resume_service() {
    local target="$1"
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}" <<EOF
TARGET=${target}
AUTO=1
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    # Копируем сам скрипт в стабильный путь (переживает ребут)
    cp -f "${BASH_SOURCE[0]}" "${SELF_INSTALL}" 2>/dev/null || cp -f "$0" "${SELF_INSTALL}"
    chmod +x "${SELF_INSTALL}"

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=FastNodeDebian chained dist-upgrade (resume)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${STATE_FILE}

[Service]
Type=oneshot
ExecStart=${SELF_INSTALL} --resume
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    success "Авто-продолжение установлено (systemd: ${SERVICE_NAME})."
}

remove_resume_service() {
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "${STATE_FILE}"
    rm -f "${SELF_INSTALL}"
    success "Авто-продолжение отключено и очищено."
}

# ── Перезагрузка ─────────────────────────────────────────────────────────────
do_reboot() {
    info "Перезагрузка через 5 секунд... (Ctrl+C чтобы отменить)"
    sleep 5
    _ulog "rebooting"
    systemctl reboot 2>/dev/null || reboot
}

# ── Статус ───────────────────────────────────────────────────────────────────
show_status() {
    local cur; cur="$(current_major)"
    echo ""
    echo -e "  ${BOLD}FastNodeDebian — статус обновления${NC}"
    echo -e "  Текущая версия:  ${GREEN}Debian ${cur} (${CODENAME[$cur]:-?})${NC}"
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${STATE_FILE}"
        echo -e "  Авто-режим:      ${GREEN}включён${NC} (цель: Debian ${TARGET:-?}, старт: ${STARTED_AT:-?})"
        echo -e "  systemd-юнит:    ${SERVICE_NAME}"
    else
        echo -e "  Авто-режим:      выключен"
    fi
    echo -e "  Лог:             ${UPGRADE_LOG}"
    echo ""
}

# ── Целевая версия из аргументов / state ────────────────────────────────────
TARGET="${DEFAULT_TARGET}"
ASSUME_YES=0
MODE="manual"   # manual | auto | resume | status

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)    MODE="auto" ;;
            --resume)  MODE="resume" ;;
            --status)  MODE="status" ;;
            --yes|-y)  ASSUME_YES=1 ;;
            --target)  shift; TARGET="${1:-$DEFAULT_TARGET}" ;;
            --target=*) TARGET="${1#*=}" ;;
            --help|-h)
                grep -E '^#( |!)' "$0" | sed -E 's/^#!?//' | head -n 40
                exit 0 ;;
            *) warn "Неизвестный аргумент: $1" ;;
        esac
        shift
    done
    # валидация target
    if [[ -z "${CODENAME[$TARGET]:-}" ]]; then
        error "Недопустимая целевая версия: ${TARGET} (допустимо 9–13)"
        exit 1
    fi
}

confirm() {
    [[ ${ASSUME_YES} -eq 1 ]] && return 0
    local prompt="$1"
    printf "%b" "${YELLOW}${prompt} (yes/no): ${NC}"
    local a; read -r a </dev/tty 2>/dev/null || a="no"
    [[ "${a}" == "yes" ]]
}

# ── Основная логика ──────────────────────────────────────────────────────────
module_system_update() {
    preflight

    local cur; cur="$(current_major)"
    if [[ -z "${cur}" || -z "${CODENAME[$cur]:-}" ]]; then
        error "Не удалось определить версию Debian (получено: '${cur}')."
        exit 1
    fi

    # ── РЕЖИМ: статус ────────────────────────────────────────────────────────
    if [[ "${MODE}" == "status" ]]; then
        show_status
        return 0
    fi

    # ── РЕЖИМ: resume (из systemd после ребута) ─────────────────────────────
    if [[ "${MODE}" == "resume" ]]; then
        [[ -f "${STATE_FILE}" ]] && source "${STATE_FILE}"
        TARGET="${TARGET:-$DEFAULT_TARGET}"
        info "[resume] Текущая: Debian ${cur} (${CODENAME[$cur]}) | Цель: Debian ${TARGET}"
        if [[ "${cur}" -ge "${TARGET}" ]]; then
            success "Цель достигнута: Debian ${cur}. Завершаем авто-обновление."
            remove_resume_service
            _ulog "chain finished at ${cur}"
            return 0
        fi
        if upgrade_one_hop "${cur}"; then
            do_reboot
        else
            error "Шаг апгрейда завершился с ошибкой. Авто-цикл остановлен."
            warn  "Разберитесь вручную, затем: ${SELF_INSTALL} --resume  (или отключите: systemctl disable ${SERVICE_NAME})"
            _ulog "hop failed at ${cur}, auto paused"
            return 1
        fi
        return 0
    fi

    # Уже на цели?
    if [[ "${cur}" -ge "${TARGET}" ]]; then
        success "Система уже на Debian ${cur} — обновление до ${TARGET} не требуется."
        return 0
    fi

    # Предупреждение
    echo ""
    echo -e "${YELLOW}  ╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}  ║  ⚠  ПОЭТАПНОЕ ОБНОВЛЕНИЕ ДИСТРИБУТИВА DEBIAN               ║${NC}"
    echo -e "${YELLOW}  ║                                                            ║${NC}"
    echo -e "${YELLOW}  ║  • Операция НЕОБРАТИМА — сделайте снапшот/бэкап заранее!   ║${NC}"
    echo -e "${YELLOW}  ║  • После каждого шага будет ПЕРЕЗАГРУЗКА.                  ║${NC}"
    echo -e "${YELLOW}  ║  • Сторонние репозитории будут временно отключены.        ║${NC}"
    echo -e "${YELLOW}  ╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Текущая версия: Debian ${cur} (${CODENAME[$cur]})"
    info "Целевая версия: Debian ${TARGET} (${CODENAME[$TARGET]})"
    info "Маршрут: $(s=${cur}; out=""; while [[ ${s} -le ${TARGET} ]]; do out+="${s} "; s=$((s+1)); done; echo "${out}" | sed 's/ /→/g; s/→$//')"
    echo ""

    disable_thirdparty

    # ── РЕЖИМ: auto (весь путь с авто-ребутами) ─────────────────────────────
    if [[ "${MODE}" == "auto" ]]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            error "Авто-режим требует systemd. Используйте ручной режим (без --auto)."
            exit 1
        fi
        confirm "Запустить АВТОМАТИЧЕСКОЕ обновление Debian ${cur} → ${TARGET} с перезагрузками?" || { info "Отменено."; return 0; }
        install_resume_service "${TARGET}"
        if upgrade_one_hop "${cur}"; then
            do_reboot     # дальше эстафету подхватит systemd → --resume
        else
            error "Первый шаг не удался. Авто-сервис установлен, но приостановлен."
            return 1
        fi
        return 0
    fi

    # ── РЕЖИМ: manual (один шаг) ─────────────────────────────────────────────
    confirm "Выполнить ОДИН шаг: Debian ${cur} → $((cur+1)) (${CODENAME[$((cur+1))]})?" || { info "Отменено."; return 0; }
    if upgrade_one_hop "${cur}"; then
        echo ""
        local next=$(( cur + 1 ))
        if [[ ${next} -ge ${TARGET} ]]; then
            success "Это был финальный шаг. После перезагрузки система будет на Debian ${next}."
        else
            info "После перезагрузки ЗАПУСТИТЕ СКРИПТ СНОВА, чтобы продолжить: Debian ${next} → $((next+1))."
        fi
        echo ""
        if confirm "Перезагрузить сейчас?"; then
            do_reboot
        else
            warn "Не забудьте перезагрузиться вручную: sudo reboot"
        fi
    fi
}

parse_args "$@"
module_system_update
