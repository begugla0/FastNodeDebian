#!/usr/bin/env bash
# ==============================================================================
# Модуль 00 — Поэтапное обновление Debian до 13 (trixie)
#   9 stretch → 10 buster → 11 bullseye → 12 bookworm → 13 trixie
#
# Единственный модуль, работающий на Debian 9–12. Все остальные модули
# требуют уже обновлённую до 13 систему.
#
# Режимы:
#   bash 00-system-update.sh                  один шаг + предложение перезагрузки
#   bash 00-system-update.sh --auto           вся цепочка до 13 с авто-перезагрузками
#   bash 00-system-update.sh --auto --yes     то же без подтверждений
#   bash 00-system-update.sh --status         состояние и маршрут
#   bash 00-system-update.sh --restore-repos  вернуть отключённые сторонние репы
#   bash 00-system-update.sh --abort          отменить авто-режим и снять systemd-юнит
#   bash 00-system-update.sh --resume         внутренний вызов из systemd
#
# ⚠ Апгрейд дистрибутива необратим. Снапшот перед запуском обязателен.
# ==============================================================================

set -Eeuo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "00-system-update"

# ── Константы ─────────────────────────────────────────────────────────────────
declare -A CODENAME=( [9]=stretch [10]=buster [11]=bullseye [12]=bookworm [13]=trixie )
MIN_SUPPORTED=9
MAX_SUPPORTED=13

STATE_DIR="/var/lib/fastnode-upgrade"
STATE_FILE="${STATE_DIR}/state.env"
REPO_LIST="${STATE_DIR}/disabled-repos.list"
SELF_INSTALL="/usr/local/sbin/fastnode-system-update"
LIB_INSTALL="/usr/local/lib/fastnode/common.sh"
CONF_INSTALL="/usr/local/lib/fastnode/settings.conf"
SERVICE_NAME="fastnode-upgrade.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
UPGRADE_LOG="/var/log/fastnode-upgrade.log"
ARCHIVE_CONF="/etc/apt/apt.conf.d/99fastnode-archive"

# Разрешаем apt менять Suite/Codename/Version при смене релиза.
# Без этого apt-get update возвращает ненулевой код на каждом шаге апгрейда,
# и вся цепочка вставала — главная причина неработоспособности прошлой версии.
RELEASEINFO_OPTS=(
    -o Acquire::AllowReleaseInfoChange::Suite=true
    -o Acquire::AllowReleaseInfoChange::Version=true
    -o Acquire::AllowReleaseInfoChange::Codename=true
    -o Acquire::AllowReleaseInfoChange::Origin=true
    -o Acquire::AllowReleaseInfoChange::Label=true
    -o Acquire::AllowReleaseInfoChange::Defaultpin=true
)

TARGET="${UPGRADE_TARGET:-13}"
ASSUME_YES=0
MODE="manual"

ulog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${UPGRADE_LOG}" 2>/dev/null || true; }

# ── Разбор аргументов ─────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)          MODE="auto" ;;
            --resume)        MODE="resume" ;;
            --status)        MODE="status" ;;
            --restore-repos) MODE="restore" ;;
            --abort)         MODE="abort" ;;
            --yes|-y)        ASSUME_YES=1; FASTNODE_YES=1 ;;
            --target)        shift; TARGET="${1:-13}" ;;
            --target=*)      TARGET="${1#*=}" ;;
            --help|-h)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *)               warn "Неизвестный аргумент: $1" ;;
        esac
        shift
    done
    export FASTNODE_YES="${FASTNODE_YES:-0}"
    if [[ -z "${CODENAME[${TARGET}]:-}" ]]; then
        die "Недопустимая целевая версия: ${TARGET} (поддерживается ${MIN_SUPPORTED}–${MAX_SUPPORTED})"
    fi
    if [[ "${TARGET}" -ne 13 ]]; then
        warn "Целевая версия ${TARGET} отличается от 13; модули настройки требуют именно Debian 13."
    fi
}

# ── Предполётные проверки ─────────────────────────────────────────────────────
preflight() {
    require_root
    is_debian || die "Это не Debian."
    touch "${UPGRADE_LOG}" 2>/dev/null || true

    local root_mb boot_mb
    root_mb="$(free_mb /)"
    if [[ -n "${root_mb}" && "${root_mb}" -lt 3072 ]]; then
        warn "На / свободно ${root_mb} MB. Для апгрейда релиза рекомендуется ≥ 3072 MB."
        confirm "Продолжить несмотря на нехватку места?" no || exit 1
    fi
    if mountpoint -q /boot 2>/dev/null; then
        boot_mb="$(free_mb /boot)"
        if [[ -n "${boot_mb}" && "${boot_mb}" -lt 200 ]]; then
            warn "На /boot свободно ${boot_mb} MB — установка нового ядра может провалиться."
            info "Удалите старые ядра:  apt-get --purge autoremove"
        fi
    fi
}

# Приводим dpkg/apt в согласованное состояние перед любыми операциями
heal_dpkg() {
    local audit; audit="$(dpkg --audit 2>/dev/null || true)"
    [[ -n "${audit//[[:space:]]/}" ]] && warn "dpkg сообщает о незавершённых операциях — исправляем"
    dpkg --configure -a || warn "dpkg --configure -a завершился с ошибками"
    apt-get -f install -y "${APT_CONF_OPTS[@]}" || warn "apt-get -f install завершился с ошибками"
}

check_holds() {
    local holds
    holds="$(apt-mark showhold 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "${holds// /}" ]]; then
        warn "Пакеты на удержании (hold) могут заблокировать апгрейд: ${holds}"
        if confirm "Снять удержание с этих пакетов?" no; then
            # shellcheck disable=SC2086
            apt-mark unhold ${holds} >/dev/null 2>&1 || true
            success "Удержание снято"
        fi
    fi
}

# ── Сторонние репозитории ─────────────────────────────────────────────────────
disable_thirdparty() {
    local f count=0
    mkdir -p "${STATE_DIR}"
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -e "${f}" ]] || continue
        mv "${f}" "${f}.fastnode-disabled"
        printf '%s\n' "${f}" >> "${REPO_LIST}"
        warn "Отключён сторонний репозиторий: $(basename "${f}")"
        count=$((count + 1))
    done
    shopt -u nullglob
    [[ ${count} -gt 0 ]] && ulog "disabled ${count} third-party repos"
    return 0
}

restore_thirdparty() {
    [[ -f "${REPO_LIST}" ]] || { info "Список отключённых репозиториев пуст."; return 0; }
    local f n=0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        if [[ -e "${f}.fastnode-disabled" ]]; then
            mv "${f}.fastnode-disabled" "${f}"
            success "Восстановлен: $(basename "${f}")"
            n=$((n + 1))
        fi
    done < "${REPO_LIST}"
    rm -f "${REPO_LIST}"
    warn "Проверьте, что восстановленные репозитории поддерживают Debian ${TARGET}, затем: apt-get update"
    info "Восстановлено записей: ${n}"
}

# ── Формирование sources.list ─────────────────────────────────────────────────
# _write_sources <major> <codename> <live|archive> <with_updates:0|1>
_write_sources() {
    local major="$1" cn="$2" mode="$3" with_updates="$4"
    local components="main contrib non-free"
    [[ "${major}" -ge 12 ]] && components="main contrib non-free non-free-firmware"

    local base sec sec_suite
    if [[ "${mode}" == "archive" ]]; then
        base="http://archive.debian.org/debian"
        sec="http://archive.debian.org/debian-security"
        printf 'Acquire::Check-Valid-Until "false";\n' > "${ARCHIVE_CONF}"
    else
        base="http://deb.debian.org/debian"
        sec="http://security.debian.org/debian-security"
        rm -f "${ARCHIVE_CONF}" 2>/dev/null || true
    fi

    if [[ "${major}" -le 10 ]]; then
        sec_suite="${cn}/updates"
    else
        sec_suite="${cn}-security"
    fi

    {
        printf '# Сгенерировано FastNodeDebian (модуль 00) %s\n' "$(date)"
        printf '# Debian %s (%s), режим=%s\n\n' "${major}" "${cn}" "${mode}"
        printf 'deb %s %s %s\n' "${base}" "${cn}" "${components}"
        [[ "${with_updates}" == "1" ]] && printf 'deb %s %s-updates %s\n' "${base}" "${cn}" "${components}"
        printf 'deb %s %s %s\n' "${sec}" "${sec_suite}" "${components}"
    } > /etc/apt/sources.list
}

apt_update_release() {
    local rc=0
    apt-get update "${APT_CONF_OPTS[@]}" "${RELEASEINFO_OPTS[@]}" >>"${UPGRADE_LOG}" 2>&1 || rc=$?
    return "${rc}"
}

_apt_run() {
    local rc=0
    "$@" >>"${UPGRADE_LOG}" 2>&1 || rc=$?
    return "${rc}"
}

# configure_sources <major> <codename>
configure_sources() {
    local major="$1" cn="$2"
    local -a modes
    if [[ "${major}" -le 10 ]]; then
        modes=(archive)          # stretch/buster давно в архиве
    else
        modes=(live archive)
    fi

    local m u
    for m in "${modes[@]}"; do
        for u in 1 0; do
            info "Источники ${cn}: режим=${m}, -updates=${u}"
            _write_sources "${major}" "${cn}" "${m}" "${u}"
            if apt_update_release >/dev/null; then
                success "apt update успешен (${cn}, ${m})"
                ulog "sources ok: ${cn} ${m} updates=${u}"
                return 0
            fi
            warn "apt update не прошёл (${cn}, ${m}, updates=${u})"
        done
    done
    error "Не удалось подобрать рабочие источники для ${cn}. Подробности: ${UPGRADE_LOG}"
    return 1
}

# ── Апгрейд ───────────────────────────────────────────────────────────────────
do_full_upgrade() {
    local label="$1"
    info "${label}: apt-get upgrade... (вывод в ${UPGRADE_LOG})"
    if ! _apt_run apt-get upgrade -y "${APT_CONF_OPTS[@]}" "${RELEASEINFO_OPTS[@]}"; then
        warn "upgrade завершился с ошибками, пробуем восстановиться"
        heal_dpkg
    fi

    info "${label}: apt-get full-upgrade..."
    if ! _apt_run apt-get full-upgrade -y "${APT_CONF_OPTS[@]}" "${RELEASEINFO_OPTS[@]}"; then
        warn "full-upgrade завершился с ошибками — вторая попытка после восстановления"
        heal_dpkg
        if ! _apt_run apt-get full-upgrade -y "${APT_CONF_OPTS[@]}" "${RELEASEINFO_OPTS[@]}"; then
            error "full-upgrade не удался. Смотрите ${UPGRADE_LOG}"
            return 1
        fi
    fi

    apt-get --purge autoremove -y "${APT_CONF_OPTS[@]}" >/dev/null 2>&1 || true
    apt-get clean || true
    return 0
}

# Подтягиваем текущий релиз до актуального состояния перед прыжком
update_current() {
    local cur="$1" cn="${CODENAME[$1]}"
    step "Актуализация текущего релиза Debian ${cur} (${cn})"
    configure_sources "${cur}" "${cn}" || return 1
    apt_install debian-archive-keyring ca-certificates apt >/dev/null 2>&1 || true
    do_full_upgrade "Debian ${cur}" || return 1
    success "Debian ${cur} обновлён в пределах релиза"
}

# Один прыжок from → from+1
upgrade_one_hop() {
    local from="$1" to to_cn
    to=$(( from + 1 ))
    to_cn="${CODENAME[${to}]:-}"
    [[ -n "${to_cn}" ]] || { error "Нет данных для перехода на Debian ${to}"; return 1; }

    step "Апгрейд: Debian ${from} (${CODENAME[${from}]}) → ${to} (${to_cn})"
    ulog "=== HOP ${from} -> ${to} START ==="

    heal_dpkg
    check_holds
    update_current "${from}" || return 1

    backup_file /etc/apt/sources.list >/dev/null
    configure_sources "${to}" "${to_cn}" || return 1

    # Ключи нового релиза: ставим сразу после переключения источников,
    # иначе подпись Release может не пройти проверку на следующем шаге.
    apt_install debian-archive-keyring >/dev/null 2>&1 || true
    apt_update_release >/dev/null || warn "Повторный apt update прошёл с замечаниями"

    do_full_upgrade "Debian ${to}" || return 1

    local now; now="$(os_major)"
    ulog "=== HOP ${from} -> ${to} DONE (system reports ${now}) ==="
    success "Переход выполнен. Система сообщает: Debian ${now} (${to_cn})"
    info "Для активации нового ядра нужна перезагрузка."
    return 0
}

# ── systemd-автопродолжение ───────────────────────────────────────────────────
state_set() {
    mkdir -p "${STATE_DIR}"
    local k="$1" v="$2"
    touch "${STATE_FILE}"
    sed -i "/^${k}=/d" "${STATE_FILE}"
    printf '%s=%s\n' "${k}" "${v}" >> "${STATE_FILE}"
}

install_resume_service() {
    require_systemd
    mkdir -p "${STATE_DIR}" "$(dirname "${LIB_INSTALL}")"
    state_set TARGET "${TARGET}"
    state_set AUTO 1
    state_set FAILED 0
    state_set STARTED_AT "$(date '+%Y-%m-%dT%H:%M:%S')"

    # Копируем скрипт и библиотеку в стабильные пути: каталог репозитория
    # может оказаться недоступен после перезагрузки.
    install -m 0755 "${BASH_SOURCE[0]}" "${SELF_INSTALL}"
    install -m 0644 "${FASTNODE_ROOT}/lib/common.sh" "${LIB_INSTALL}"
    [[ -r "${FASTNODE_CONFIG:-}" ]] && install -m 0644 "${FASTNODE_CONFIG}" "${CONF_INSTALL}"
    # Внутри /usr/local/sbin относительный путь ../lib/common.sh указывает
    # ровно на /usr/local/lib/common.sh — кладём симлинк для совместимости.
    ln -sfn "${LIB_INSTALL}" /usr/local/lib/common.sh

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=FastNodeDebian staged dist-upgrade (resume after reboot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${STATE_FILE}

[Service]
Type=oneshot
RemainAfterExit=no
Environment=FASTNODE_CONFIG=${CONF_INSTALL}
Environment=FASTNODE_NONINTERACTIVE=1
ExecStart=${SELF_INSTALL} --resume --yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    success "Авто-продолжение установлено (${SERVICE_NAME}), лог: ${UPGRADE_LOG}"
}

remove_resume_service() {
    systemd_present || return 0
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}" "${SELF_INSTALL}" "${LIB_INSTALL}" "${CONF_INSTALL}" /usr/local/lib/common.sh
    rmdir /usr/local/lib/fastnode 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "${STATE_FILE}"
    success "Авто-режим отключён, временные файлы удалены"
}

# Останавливаем цепочку так, чтобы сервер не ушёл в цикл перезагрузок
pause_auto() {
    state_set FAILED 1
    systemd_present && systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    error "Цепочка остановлена. После ручного разбора продолжите:"
    info  "  ${SELF_INSTALL} --resume   (или заново: bash modules/00-system-update.sh --auto)"
    ulog "chain paused after failure"
}

do_reboot() {
    info "Перезагрузка через 5 секунд... (Ctrl+C — отмена)"
    sleep 5
    ulog "rebooting"
    systemctl reboot 2>/dev/null || reboot
}

# ── Статус ────────────────────────────────────────────────────────────────────
route_string() {
    local from="$1" to="$2" s out=""
    for (( s = from; s <= to; s++ )); do
        out+="${s}"
        [[ ${s} -lt ${to} ]] && out+="→"
    done
    printf '%s' "${out}"
}

show_status() {
    local cur; cur="$(os_major)"
    printf '\n  %sFastNodeDebian — статус обновления%s\n' "${C_BOLD}" "${C_NC}"
    printf '  Текущая версия:  %sDebian %s (%s)%s\n' "${C_GREEN}" "${cur}" "${CODENAME[${cur}]:-?}" "${C_NC}"
    printf '  Целевая версия:  Debian %s (%s)\n' "${TARGET}" "${CODENAME[${TARGET}]:-?}"
    if [[ "${cur}" -lt "${TARGET}" ]]; then
        printf '  Маршрут:         %s\n' "$(route_string "${cur}" "${TARGET}")"
    else
        printf '  Маршрут:         %sцель достигнута%s\n' "${C_GREEN}" "${C_NC}"
    fi
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${STATE_FILE}"
        if [[ "${FAILED:-0}" == "1" ]]; then
            printf '  Авто-режим:      %sприостановлен после ошибки%s\n' "${C_RED}" "${C_NC}"
        else
            printf '  Авто-режим:      %sактивен%s (старт: %s)\n' "${C_GREEN}" "${C_NC}" "${STARTED_AT:-?}"
        fi
    else
        printf '  Авто-режим:      выключен\n'
    fi
    if [[ -f "${REPO_LIST}" ]]; then
        printf '  Откл. репозиториев: %s (вернуть: --restore-repos)\n' "$(wc -l < "${REPO_LIST}")"
    fi
    printf '  Лог:             %s\n\n' "${UPGRADE_LOG}"
}

warning_box() {
    printf '%s' "${C_YELLOW}"
    cat <<'BOX'
  ╔════════════════════════════════════════════════════════════╗
  ║  ⚠  ОБНОВЛЕНИЕ ДИСТРИБУТИВА DEBIAN                         ║
  ║                                                            ║
  ║  • Операция необратима — сделайте снапшот заранее.         ║
  ║  • После каждого шага сервер перезагружается.              ║
  ║  • Сторонние репозитории будут временно отключены.         ║
  ║  • Не отключайте питание во время работы скрипта.          ║
  ╚════════════════════════════════════════════════════════════╝
BOX
    printf '%s\n' "${C_NC}"
}

# ── Основная логика ───────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    case "${MODE}" in
        status)  preflight; show_status; exit 0 ;;
        restore) require_root; restore_thirdparty; exit 0 ;;
        abort)   require_root; remove_resume_service; exit 0 ;;
    esac

    preflight

    local cur; cur="$(os_major)"
    [[ -n "${cur}" && -n "${CODENAME[${cur}]:-}" ]] \
        || die "Не удалось определить поддерживаемую версию Debian (получено: '${cur}')"

    # ── resume: вызов из systemd после перезагрузки ───────────────────────────
    if [[ "${MODE}" == "resume" ]]; then
        [[ -f "${STATE_FILE}" ]] && { source "${STATE_FILE}"; TARGET="${TARGET:-13}"; }
        info "[resume] Debian ${cur} (${CODENAME[${cur}]}) → цель Debian ${TARGET}"
        if [[ "${cur}" -ge "${TARGET}" ]]; then
            success "Цель достигнута: Debian ${cur}."
            remove_resume_service
            if [[ -f "${REPO_LIST}" ]]; then
                warn "Остались отключённые сторонние репозитории."
                info "Вернуть их:  bash modules/00-system-update.sh --restore-repos"
            fi
            ulog "chain finished at ${cur}"
            exit 0
        fi
        if upgrade_one_hop "${cur}"; then
            do_reboot
        else
            pause_auto
            exit 1
        fi
        exit 0
    fi

    # ── Уже на цели ───────────────────────────────────────────────────────────
    if [[ "${cur}" -ge "${TARGET}" ]]; then
        success "Система уже на Debian ${cur} — обновление не требуется."
        [[ -f "${STATE_FILE}" ]] && remove_resume_service
        exit 0
    fi

    warning_box
    info "Текущая версия: Debian ${cur} (${CODENAME[${cur}]})"
    info "Целевая версия: Debian ${TARGET} (${CODENAME[${TARGET}]})"
    info "Маршрут:        $(route_string "${cur}" "${TARGET}")"
    echo

    # ── auto ──────────────────────────────────────────────────────────────────
    if [[ "${MODE}" == "auto" ]]; then
        require_systemd
        confirm "Запустить автоматическое обновление Debian ${cur} → ${TARGET} с перезагрузками?" no \
            || { info "Отменено."; exit 0; }
        disable_thirdparty
        install_resume_service
        if upgrade_one_hop "${cur}"; then
            do_reboot
        else
            pause_auto
            exit 1
        fi
        exit 0
    fi

    # ── manual: ровно один шаг ────────────────────────────────────────────────
    local next=$(( cur + 1 ))
    confirm "Выполнить ОДИН шаг: Debian ${cur} → ${next} (${CODENAME[${next}]})?" no \
        || { info "Отменено."; exit 0; }

    disable_thirdparty
    if ! upgrade_one_hop "${cur}"; then
        error "Шаг не выполнен. Разберите ошибки в ${UPGRADE_LOG} и запустите снова."
        exit 1
    fi

    echo
    if [[ ${next} -ge ${TARGET} ]]; then
        success "Финальный шаг. После перезагрузки система будет на Debian ${next}."
        info "Затем можно запускать модули настройки:  bash main.sh"
    else
        info "После перезагрузки запустите скрипт снова: Debian ${next} → $(( next + 1 ))."
    fi
    echo
    if confirm "Перезагрузить сейчас?" yes; then
        do_reboot
    else
        warn "Не забудьте перезагрузиться вручную: reboot"
    fi
}

main "$@"
