#!/usr/bin/env bash
# ==============================================================================
# FastNodeDebian — main.sh
#
# Рабочая платформа модулей настройки: Debian 13 (trixie).
# Debian 9/10/11/12 обслуживаются единственным модулем 00 — обновлением до 13.
#
# Использование:
#   bash main.sh                    интерактивное меню
#   bash main.sh --all              все модули настройки без меню
#   bash main.sh --module 05        один модуль по номеру (0–10)
#   bash main.sh --upgrade          поэтапное обновление до Debian 13
#   bash main.sh --all --yes        без единого вопроса
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FASTNODE_ROOT="${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODULES_DIR="${SCRIPT_DIR}/modules"
LOG_FILE="${SCRIPT_DIR}/logs/session_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "${SCRIPT_DIR}/logs"
export LOG_FILE

load_settings
trap_setup "main"

# ── Аргументы ─────────────────────────────────────────────────────────────────
ACTION="menu"
ONE_MODULE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all|-a)            ACTION="all" ;;
        --upgrade|-u)        ACTION="upgrade" ;;
        --module|-m)         shift; ONE_MODULE="${1:-}"; ACTION="one" ;;
        --module=*)          ONE_MODULE="${1#*=}"; ACTION="one" ;;
        --yes|-y)            export FASTNODE_YES=1 ;;
        --non-interactive|-n) export FASTNODE_NONINTERACTIVE=1 ;;
        --status)            ACTION="status" ;;
        --help|-h)           sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                   warn "Неизвестный аргумент: $1" ;;
    esac
    shift
done

# Совместимость со старым способом запуска: INTERACTIVE_MODE=false bash main.sh
if [[ "${INTERACTIVE_MODE:-true}" == "false" ]]; then
    export FASTNODE_NONINTERACTIVE=1
    [[ "${ACTION}" == "menu" ]] && ACTION="all"
fi

# ── Каталог модулей ───────────────────────────────────────────────────────────
declare -A MODULE_FILE=(
    [0]="00-system-update.sh"
    [1]="01-packet-update.sh"
    [2]="02-locale-setup.sh"
    [3]="03-time-sync.sh"
    [4]="04-ssh-key.sh"
    [5]="05-ssh-hardening.sh"
    [6]="06-swap-setup.sh"
    [7]="07-ufw-setup.sh"
    [8]="08-fail2ban-setup.sh"
    [9]="09-xanmod-v3.sh"
    [10]="10-node-tuning.sh"
)
SETUP_ORDER=(1 2 3 4 5 6 7 8 10)

run_module() {
    local key="$1" file rc=0
    file="${MODULE_FILE[${key}]:-}"
    [[ -n "${file}" ]] || { warn "Нет модуля с номером ${key}"; return 1; }
    local path="${MODULES_DIR}/${file}"
    [[ -f "${path}" ]] || { warn "Файл модуля не найден: ${path}"; return 1; }

    printf '\n%s%s%s\n' "${C_BLUE}" "$(printf '━%.0s' {1..62})" "${C_NC}"
    printf '%s Модуль %s%s%s\n' "${C_BLUE}" "${C_BOLD}" "${file}" "${C_NC}"
    printf '%s%s%s\n' "${C_BLUE}" "$(printf '━%.0s' {1..62})" "${C_NC}"

    bash "${path}" || rc=$?

    case "${rc}" in
        0)  success "Модуль ${file} выполнен" ;;
        90) warn "Модуль ${file} пропущен: требуется Debian 13" ;;
        *)  error "Модуль ${file} завершился с кодом ${rc}" ;;
    esac
    return "${rc}"
}

run_all() {
    local failed=() k rc
    info "Запуск модулей настройки: ${SETUP_ORDER[*]}"
    for k in "${SETUP_ORDER[@]}"; do
        rc=0
        run_module "${k}" || rc=$?
        [[ ${rc} -ne 0 ]] && failed+=("${MODULE_FILE[${k}]}")
    done

    echo
    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Завершились с ошибкой: ${failed[*]}"
        info "Подробности: ${LOG_FILE}"
    else
        success "Все модули настройки выполнены"
    fi

    # Модуль 09 требует перезагрузки, поэтому только по явному согласию
    # и только когда есть кому ответить.
    echo
    if confirm "Установить ядро XanMod (модуль 09, требует перезагрузки)?" no; then
        run_module 9 || true
    else
        info "XanMod пропущен. Позже:  bash main.sh --module 9"
    fi
}

# ── Меню ──────────────────────────────────────────────────────────────────────
show_menu() {
    local major="$1"
    clear 2>/dev/null || true
    banner "⚡ FastNodeDebian v${FASTNODE_VERSION}"
    printf '  Система: %sDebian %s (%s)%s   Ядро: %s\n\n' \
        "${C_GREEN}" "${major}" "$(os_codename)" "${C_NC}" "$(uname -r)"

    if [[ "${major}" -lt 13 ]]; then
        printf '  %sМодули настройки требуют Debian 13. Доступно только обновление.%s\n\n' \
            "${C_YELLOW}" "${C_NC}"
        printf '   %s u%s) Поэтапное обновление до Debian 13  %s[перезагрузки]%s\n' \
            "${C_CYAN}" "${C_NC}" "${C_YELLOW}" "${C_NC}"
        printf '   %s s%s) Статус обновления\n' "${C_CYAN}" "${C_NC}"
    else
        printf '   %s 1%s) Обновление пакетов системы\n'            "${C_CYAN}" "${C_NC}"
        printf '   %s 2%s) Локаль (%s)\n'                           "${C_CYAN}" "${C_NC}" "${LOCALE_LANG:-ru_RU.UTF-8}"
        printf '   %s 3%s) Время и часовой пояс (%s)\n'             "${C_CYAN}" "${C_NC}" "${TIMEZONE:-Europe/Moscow}"
        printf '   %s 4%s) SSH ключ\n'                              "${C_CYAN}" "${C_NC}"
        printf '   %s 5%s) SSH hardening (порт %s)\n'               "${C_CYAN}" "${C_NC}" "${SSH_PORT:-2225}"
        printf '   %s 6%s) SWAP\n'                                  "${C_CYAN}" "${C_NC}"
        printf '   %s 7%s) UFW firewall\n'                          "${C_CYAN}" "${C_NC}"
        printf '   %s 8%s) Fail2Ban\n'                              "${C_CYAN}" "${C_NC}"
        printf '   %s 9%s) Ядро XanMod + BBR  %s[перезагрузка]%s\n' "${C_CYAN}" "${C_NC}" "${C_YELLOW}" "${C_NC}"
        printf '   %s10%s) Тюнинг узла (BBR, буферы, conntrack, лимиты)\n' "${C_CYAN}" "${C_NC}"
        printf '\n'
        printf '   %s u%s) Обновление дистрибутива (уже на 13 — ничего не делает)\n' "${C_CYAN}" "${C_NC}"
        printf '   %s a%s) Выполнить модули 1–8 и 10 подряд\n'      "${C_GREEN}" "${C_NC}"
        printf '   %s v%s) Проверить состояние узла\n'              "${C_CYAN}" "${C_NC}"
    fi

    printf '   %s 0%s) Выход\n\n' "${C_RED}" "${C_NC}"
    printf '  %sКонфиг:%s %s\n'  "${C_GREY}" "${C_NC}" "${FASTNODE_CONFIG:-config/settings.conf}"
    printf '  %sЛог:%s    %s\n\n' "${C_GREY}" "${C_NC}" "${LOG_FILE}"
}

node_status() {
    if [[ -x /usr/local/bin/fastnode-verify ]]; then
        /usr/local/bin/fastnode-verify | sed 's/^/   /'
    else
        printf '   Ядро:      %s\n' "$(uname -r)"
        printf '   SSH порты: %s\n' "$(sshd_effective_ports 2>/dev/null | paste -sd, - || echo '?')"
        printf '   UFW:       %s\n' "$(ufw status 2>/dev/null | head -1 || echo 'не установлен')"
        printf '   Fail2Ban:  %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo 'не установлен')"
        printf '   SWAP:      %s MB\n' "$(free -m | awk '/^Swap:/{print $2}')"
    fi
}

# ── Точка входа ───────────────────────────────────────────────────────────────
require_root
is_debian || die "FastNodeDebian предназначен только для Debian."

MAJOR="$(os_major)"
[[ -n "${MAJOR}" ]] || die "Не удалось определить версию Debian."

log_raw INFO "FastNodeDebian ${FASTNODE_VERSION} | Debian ${MAJOR} | $(uname -r)"

case "${ACTION}" in
    status)  node_status; exit 0 ;;
    upgrade) run_module 0; exit $? ;;
    one)
        # Принимаем «5», «05» и полное имя файла модуля
        MOD_KEY=""
        if [[ "${ONE_MODULE}" =~ ^0*([0-9]|10)$ ]]; then
            MOD_KEY="${BASH_REMATCH[1]}"
        else
            for k in "${!MODULE_FILE[@]}"; do
                if [[ "${MODULE_FILE[${k}]}" == "${ONE_MODULE}" \
                   || "${MODULE_FILE[${k}]}" == "${ONE_MODULE}.sh" ]]; then
                    MOD_KEY="${k}"
                    break
                fi
            done
        fi
        [[ -n "${MOD_KEY}" ]] || die "Нет модуля '${ONE_MODULE}'. Допустимо 0–9 или имя файла из modules/"
        run_module "${MOD_KEY}"; exit $?
        ;;
    all)
        if [[ "${MAJOR}" -lt 13 ]]; then
            error "Обнаружен Debian ${MAJOR}. Модули настройки требуют Debian 13."
            info  "Сначала обновитесь:  bash main.sh --upgrade"
            exit 90
        fi
        run_all
        success "Готово. Лог: ${LOG_FILE}"
        exit 0
        ;;
esac

# ── Интерактивное меню ────────────────────────────────────────────────────────
if ! interactive; then
    die "Нет терминала для меню. Используйте --all, --module N или --upgrade."
fi

while true; do
    MAJOR="$(os_major)"
    show_menu "${MAJOR}"
    printf '  Выберите пункт: ' > /dev/tty
    CHOICE=""
    read -r CHOICE < /dev/tty || break

    case "${CHOICE}" in
        0)          info "Выход"; exit 0 ;;
        u|U|00)     run_module 0 || true ;;
        10)         run_module 10 || true ;;
        s|S)        bash "${MODULES_DIR}/00-system-update.sh" --status || true ;;
        v|V)        node_status ;;
        a|A|111)
            if [[ "${MAJOR}" -lt 13 ]]; then
                error "Требуется Debian 13. Пункт 10 — обновление."
            else
                run_all
            fi
            ;;
        [1-9])
            if [[ "${MAJOR}" -lt 13 ]]; then
                error "Модуль ${CHOICE} требует Debian 13. Сначала пункт 10."
            else
                run_module "${CHOICE}" || true
            fi
            ;;
        "")         continue ;;
        *)          error "Неверный выбор: ${CHOICE}" ;;
    esac

    printf '\n  Enter — вернуться в меню...' > /dev/tty
    read -r < /dev/tty || break
done
