#!/usr/bin/env bash
# ==============================================================================
# FastNodeDebian — lib/common.sh
# Общая библиотека: логирование, диалоги, apt-обёртки, проверки ОС.
#
# Подключается КАЖДЫМ модулем самостоятельно (source), а не через export -f.
# Это принципиально: экспорт функций из main.sh приводил к тому, что
# наследованный error() не делал exit, и модули продолжали работу после
# фатальных ошибок.
# ==============================================================================

# Защита от повторного подключения
[[ -n "${_FASTNODE_COMMON_LOADED:-}" ]] && return 0
_FASTNODE_COMMON_LOADED=1

FASTNODE_VERSION="2.0.0"

# Корень проекта (каталог, содержащий lib/)
if [[ -z "${FASTNODE_ROOT:-}" ]]; then
    FASTNODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export FASTNODE_ROOT

# ── Цвета ─────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_GREY=$'\033[0;90m'
    C_BOLD=$'\033[1m';   C_NC=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
    C_CYAN=''; C_GREY=''; C_BOLD=''; C_NC=''
fi

# ── Логирование ───────────────────────────────────────────────────────────────
# LOG_FILE наследуется от main.sh; при standalone-запуске выбирается сам.
_init_log() {
    [[ -n "${LOG_FILE:-}" ]] && return 0
    local dir="${FASTNODE_ROOT}/logs"
    if mkdir -p "${dir}" 2>/dev/null && [[ -w "${dir}" ]]; then
        LOG_FILE="${dir}/fastnode-$(date +%Y%m%d).log"
    else
        LOG_FILE="/var/log/fastnode.log"
    fi
    export LOG_FILE
}
_init_log

log_raw() {
    local level="$1"; shift
    printf '[%s] [%-7s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" \
        >> "${LOG_FILE}" 2>/dev/null || true
}

info()    { log_raw INFO    "$*"; printf '%s ℹ%s %s\n'  "${C_CYAN}"   "${C_NC}" "$*"; }
warn()    { log_raw WARN    "$*"; printf '%s ⚠%s %s\n'  "${C_YELLOW}" "${C_NC}" "$*" >&2; }
error()   { log_raw ERROR   "$*"; printf '%s ✗%s %s\n'  "${C_RED}"    "${C_NC}" "$*" >&2; }
success() { log_raw SUCCESS "$*"; printf '%s ✓%s %s\n'  "${C_GREEN}"  "${C_NC}" "$*"; }
debug()   { [[ -n "${FASTNODE_DEBUG:-}" ]] || return 0; log_raw DEBUG "$*"; printf '%s   %s%s\n' "${C_GREY}" "$*" "${C_NC}"; }

step() {
    log_raw STEP "$*"
    printf '\n%s━━ %s%s\n' "${C_BLUE}${C_BOLD}" "$*" "${C_NC}"
}

# Единственный способ аварийно завершить модуль. Всегда делает exit.
die() {
    local code=1
    [[ "${1:-}" =~ ^[0-9]+$ ]] && { code="$1"; shift; }
    error "$*"
    exit "${code}"
}

# ── Обработка ошибок ──────────────────────────────────────────────────────────
_on_err() {
    local code=$1 line=$2 cmd=$3 name="${FASTNODE_MODULE_NAME:-script}"
    error "${name}: сбой на строке ${line} (код ${code}): ${cmd}"
    log_raw ERROR "traceback: ${BASH_SOURCE[*]:-?}"
}

trap_setup() {
    FASTNODE_MODULE_NAME="${1:-${0##*/}}"
    trap '_on_err "$?" "${LINENO}" "${BASH_COMMAND}"' ERR
}

# ── Базовые утилиты ───────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Требуются права root. Запустите: sudo bash $0"
}

systemd_present() { [[ -d /run/systemd/system ]] && have systemctl; }

require_systemd() {
    systemd_present || die "Требуется systemd. В контейнерах без systemd модуль неприменим."
}

# ── Определение ОС ────────────────────────────────────────────────────────────
os_field() {
    local key="$1"
    [[ -r /etc/os-release ]] || return 1
    ( . /etc/os-release 2>/dev/null; printf '%s' "${!key:-}" )
}

os_id()       { os_field ID; }
os_codename() { os_field VERSION_CODENAME; }

# Мажорная версия Debian. Возвращает пустую строку, если определить нельзя.
os_major() {
    local v cn
    v="$(os_field VERSION_ID 2>/dev/null || true)"
    if [[ -z "${v}" && -r /etc/debian_version ]]; then
        v="$(cut -d. -f1 /etc/debian_version 2>/dev/null || true)"
        if ! [[ "${v}" =~ ^[0-9]+$ ]]; then
            cn="$(cut -d/ -f1 /etc/debian_version 2>/dev/null || true)"
            case "${cn}" in
                stretch) v=9 ;; buster) v=10 ;; bullseye) v=11 ;;
                bookworm) v=12 ;; trixie) v=13 ;; forky) v=14 ;;
                *) v="" ;;
            esac
        fi
    fi
    printf '%s' "${v%%.*}"
}

# Строгая проверка: Ubuntu и производные тоже содержат /etc/debian_version,
# поэтому файл используется только когда ID в os-release отсутствует.
is_debian() {
    local id; id="$(os_id 2>/dev/null || true)"
    if [[ -n "${id}" ]]; then
        [[ "${id}" == "debian" ]]
    else
        [[ -r /etc/debian_version ]]
    fi
}

# Модули настройки работают ТОЛЬКО на Debian 13+.
# Debian 9–12 поддерживаются исключительно модулем 00 (обновление до 13).
require_debian_13() {
    local m; m="$(os_major)"
    is_debian || die "Это не Debian. FastNodeDebian работает только на Debian."
    [[ -n "${m}" ]] || die "Не удалось определить версию Debian."
    if [[ "${m}" -lt 13 ]]; then
        error "Обнаружен Debian ${m} ($(os_codename)). Модули настройки требуют Debian 13 (trixie)."
        info  "Сначала обновите систему:  bash modules/00-system-update.sh --auto"
        exit 90
    fi
    if [[ "${m}" -gt 13 ]]; then
        warn "Debian ${m} новее протестированной 13 — продолжаем, возможны отличия."
    fi
}

# ── Интерактивность ───────────────────────────────────────────────────────────
# FASTNODE_YES=1        — отвечать «да» на всё
# FASTNODE_NONINTERACTIVE=1 — не задавать вопросов (берутся значения по умолчанию)
has_tty() { [[ -r /dev/tty && -c /dev/tty ]]; }

interactive() {
    [[ "${FASTNODE_NONINTERACTIVE:-0}" == "1" ]] && return 1
    has_tty
}

# confirm "вопрос" [yes|no]   — второй аргумент это ответ по умолчанию
confirm() {
    local prompt="$1" default="${2:-no}" ans=""
    if [[ "${FASTNODE_YES:-0}" == "1" ]]; then
        log_raw INFO "confirm(auto-yes): ${prompt}"
        return 0
    fi
    if ! interactive; then
        log_raw INFO "confirm(non-interactive → ${default}): ${prompt}"
        [[ "${default}" == "yes" ]]
        return $?
    fi
    printf '%s ? %s%s [%s]: ' "${C_YELLOW}" "${prompt}" "${C_NC}" "${default}" > /dev/tty
    read -r ans < /dev/tty || ans=""
    ans="${ans:-$default}"
    log_raw INFO "confirm: ${prompt} → ${ans}"
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]
}

# ask "вопрос" "значение-по-умолчанию"  → печатает ответ в stdout
ask() {
    local prompt="$1" default="${2:-}" ans=""
    if ! interactive; then printf '%s' "${default}"; return 0; fi
    if [[ -n "${default}" ]]; then
        printf '%s ? %s%s [%s]: ' "${C_CYAN}" "${prompt}" "${C_NC}" "${default}" > /dev/tty
    else
        printf '%s ? %s%s: ' "${C_CYAN}" "${prompt}" "${C_NC}" > /dev/tty
    fi
    read -r ans < /dev/tty || ans=""
    printf '%s' "${ans:-$default}"
}

# ── Работа с файлами ──────────────────────────────────────────────────────────
backup_file() {
    local f="$1" b
    [[ -e "${f}" ]] || return 0
    b="${f}.fastnode.$(date +%Y%m%d_%H%M%S).bak"
    cp -a "${f}" "${b}"
    log_raw INFO "backup: ${f} → ${b}"
    printf '%s' "${b}"
}

# Атомарная запись содержимого stdin в файл
write_file() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp "${dest}.XXXXXX")"
    cat > "${tmp}"
    chmod "${mode}" "${tmp}"
    mv -f "${tmp}" "${dest}"
}

# ── APT ───────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

APT_CONF_OPTS=(
    -o Dpkg::Options::=--force-confold
    -o Dpkg::Options::=--force-confdef
    -o Acquire::Retries=3
)

apt_update() {
    apt-get update "${APT_CONF_OPTS[@]}" "$@"
}

# Есть ли пакет-кандидат в текущих источниках
apt_available() {
    local cand
    cand="$(apt-cache policy -- "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [[ -n "${cand}" && "${cand}" != "(none)" ]]
}

# Установка списка пакетов с отсевом отсутствующих.
# Ключевое отличие от исходной версии: один недоступный пакет больше не
# срывает установку всего списка.
apt_install() {
    local -a want=("$@") ok=() miss=()
    local p
    for p in "${want[@]}"; do
        if apt_available "${p}"; then ok+=("${p}"); else miss+=("${p}"); fi
    done
    if [[ ${#miss[@]} -gt 0 ]]; then
        warn "Недоступны в этом релизе, пропускаем: ${miss[*]}"
    fi
    [[ ${#ok[@]} -eq 0 ]] && return 0
    apt-get install -y "${APT_CONF_OPTS[@]}" "${ok[@]}"
}

pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

# ── systemd-хелперы ───────────────────────────────────────────────────────────
unit_exists() {
    local units; units="$(systemctl list-unit-files --no-legend "$1" 2>/dev/null || true)"
    [[ -n "${units//[[:space:]]/}" ]] || systemctl cat "$1" >/dev/null 2>&1
}

svc_active()  { systemctl is-active  --quiet "$1" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

svc_enable_now() {
    systemctl enable "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
}

# ── sysctl ────────────────────────────────────────────────────────────────────
sysctl_apply() {
    local f="$1"
    if ! sysctl -p "${f}" >/dev/null 2>&1; then
        warn "Часть параметров из $(basename "${f}") не применилась на текущем ядре (нормально до перезагрузки)"
    fi
}

# ── Конфигурация ──────────────────────────────────────────────────────────────
# Порядок приоритета: окружение > settings.local.conf > settings.conf
# Без этого запуск вида «SSH_PORT=2222 bash modules/05-...» молча игнорировался:
# конфиг перезаписывал переданное значение.
load_settings() {
    local f="${FASTNODE_CONFIG:-${FASTNODE_ROOT}/config/settings.conf}"
    local local_f="${FASTNODE_ROOT}/config/settings.local.conf"

    if [[ ! -r "${f}" ]]; then
        warn "Конфиг не найден: ${f} — используются значения по умолчанию"
        return 0
    fi

    # Скалярные переменные, заданные в окружении, запоминаем до чтения файла
    local -A _env_override=()
    local n decl
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        [[ -n "${!n+x}" ]] || continue
        decl="$(declare -p "${n}" 2>/dev/null || true)"
        [[ "${decl}" == *"declare -a"* || "${decl}" == *"declare -A"* ]] && continue
        _env_override["${n}"]="${!n}"
    done < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "${f}")

    # shellcheck source=/dev/null
    source "${f}"
    # shellcheck source=/dev/null
    [[ -r "${local_f}" ]] && source "${local_f}" && info "Применён ${local_f}"

    for n in "${!_env_override[@]}"; do
        printf -v "${n}" '%s' "${_env_override[${n}]}"
    done

    FASTNODE_CONFIG="${f}"
    export FASTNODE_CONFIG
    return 0
}

# ── Разное ────────────────────────────────────────────────────────────────────
# Свободное место в МБ на разделе, содержащем путь
free_mb() {
    df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'
}

# Размер вида 2G / 512M → мегабайты
size_to_mb() {
    local s="${1^^}" n
    case "${s}" in
        *G) n="${s%G}"; printf '%s' "$(( ${n%%.*} * 1024 ))" ;;
        *M) printf '%s' "${s%M}" ;;
        *)  printf '%s' "${s}" ;;
    esac
}

# Порты, на которых сейчас реально слушает sshd (по данным sshd -T)
sshd_effective_ports() {
    if have sshd; then
        sshd -T 2>/dev/null | awk '/^port /{print $2}' && return 0
    fi
    ss -H -tln 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u
}

# Порт текущего SSH-подключения (если мы сидим по SSH)
current_ssh_port() {
    [[ -n "${SSH_CONNECTION:-}" ]] || return 0
    awk '{print $4}' <<< "${SSH_CONNECTION}"
}

banner() {
    printf '\n%s  ╔══════════════════════════════════════════════════════╗%s\n' "${C_CYAN}" "${C_NC}"
    printf '%s  ║%s  %-52s%s║%s\n' "${C_CYAN}" "${C_NC}" "$1" "${C_CYAN}" "${C_NC}"
    printf '%s  ╚══════════════════════════════════════════════════════╝%s\n\n' "${C_CYAN}" "${C_NC}"
}

# ── Дополнительные проверки окружения ─────────────────────────────────────────

# Подтверждение необратимых операций: принимается только слово «yes».
confirm_strict() {
    local prompt="$1" ans=""
    if [[ "${FASTNODE_YES:-0}" == "1" ]]; then
        log_raw INFO "confirm_strict(auto-yes): ${prompt}"
        return 0
    fi
    interactive || { log_raw INFO "confirm_strict(non-interactive → no): ${prompt}"; return 1; }
    printf '%s ! %s%s (введите «yes»): ' "${C_YELLOW}" "${prompt}" "${C_NC}" > /dev/tty
    read -r ans < /dev/tty || ans=""
    log_raw INFO "confirm_strict: ${prompt} → ${ans}"
    [[ "${ans}" == "yes" ]]
}

virt_type() {
    if have systemd-detect-virt; then
        systemd-detect-virt 2>/dev/null || printf 'none'
    else
        printf 'unknown'
    fi
}

# Контейнер — замена ядра и часть sysctl невозможны
is_container() {
    case "$(virt_type)" in
        lxc|lxc-libvirt|openvz|docker|podman|systemd-nspawn|wsl) return 0 ;;
        *) return 1 ;;
    esac
}

# Занят ли TCP-порт прямо сейчас
port_busy() {
    local p="$1"
    have ss || return 1
    local out; out="$(ss -H -ltn "sport = :${p}" 2>/dev/null || true)"
    [[ -n "${out//[[:space:]]/}" ]]
}

# Все порты, которые нельзя закрывать: слушающие sshd + порт текущей сессии
ssh_ports_in_use() {
    { sshd_effective_ports; current_ssh_port; } 2>/dev/null \
        | grep -E '^[0-9]+$' | sort -un
}

has_ipv6() { [[ -f /proc/net/if_inet6 ]]; }

ensure_dir() { mkdir -p "$1" && chmod "${2:-0755}" "$1"; }

# Свободное место в /boot — типовая причина провала установки ядра
require_boot_space() {
    local need_mb="${1:-300}" have_mb
    have_mb="$(free_mb /boot)"
    [[ -z "${have_mb}" ]] && return 0
    if [[ "${have_mb}" -lt "${need_mb}" ]]; then
        error "В /boot свободно ${have_mb} MB, нужно минимум ${need_mb} MB."
        info  "Освободите место: apt-get --purge autoremove; ls /boot"
        return 1
    fi
    debug "/boot свободно: ${have_mb} MB"
    return 0
}

# ── Безопасный поиск по выводу команды ────────────────────────────────────────
# Конструкция «cmd | grep -q ...» под `set -o pipefail` ЛОЖНО возвращает ошибку:
# grep завершается по первому совпадению, cmd получает SIGPIPE (код 141), и
# pipefail отдаёт этот код наружу. Из-за этого проверки вида
# «ufw status | grep -q active» сообщали, что UFW не активен, хотя он активен.
# Здесь вывод сначала целиком читается в переменную, конвейера нет.
out_matches() {          # out_matches <regex> <команда...>
    local re="$1"; shift
    local out; out="$("$@" 2>/dev/null || true)"
    [[ -n "${out}" ]] && grep -qE "${re}" <<< "${out}"
}

out_matches_i() {        # то же, но без учёта регистра
    local re="$1"; shift
    local out; out="$("$@" 2>/dev/null || true)"
    [[ -n "${out}" ]] && grep -qiE "${re}" <<< "${out}"
}

# Активен ли UFW прямо сейчас
ufw_is_active() {
    have ufw || return 1
    out_matches_i '^Status: active' ufw status
}
