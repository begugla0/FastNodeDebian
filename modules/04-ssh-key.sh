#!/usr/bin/env bash
# ==============================================================================
# Модуль 04 — Установка SSH публичного ключа
# Платформа: Debian 13 (trixie)
#
# Отличия от прежней версии:
#   - Ключ проверяется настоящим ssh-keygen, а не grep по префиксу.
#   - Исправлен подсчёт ключей: конструкция $(grep -c . f || echo 0) выдавала
#     строку "0\n0" и ломала проверку «ключей нет».
#   - Права и владелец выставляются до записи, файл пишется атомарно.
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "04-ssh-key"
require_root
require_debian_13

# Подсчёт непустых строк без ловушки с кодом возврата grep
# grep -c возвращает 1 при нуле совпадений. Конструкция «grep -c ... || echo 0»
# в этом случае печатает НОЛЬ ДВАЖДЫ ("0\n0") и ломает любое сравнение —
# ровно на этом спотыкалась прежняя версия модуля.
count_keys() {
    local f="$1" n
    [[ -f "${f}" ]] || { printf '0'; return 0; }
    n="$(grep -cvE '^[[:space:]]*(#|$)' "${f}" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

# Настоящая проверка ключа средствами OpenSSH
valid_key() {
    local key="$1" tmp rc=0
    [[ -n "${key//[[:space:]]/}" ]] || return 1
    tmp="$(mktemp)"
    printf '%s\n' "${key}" > "${tmp}"
    ssh-keygen -l -f "${tmp}" >/dev/null 2>&1 || rc=1
    rm -f "${tmp}"
    return "${rc}"
}

# Тело ключа без комментария — по нему определяем дубликаты
key_body() { awk '{print $1" "$2}' <<< "$1"; }

step "Установка SSH ключа"

# ── Пользователь ──────────────────────────────────────────────────────────────
SSH_USER="${SSH_KEY_USER:-}"
if [[ -z "${SSH_USER}" ]]; then
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]] || ! interactive; then
        SSH_USER="root"
    else
        SSH_USER="$(ask "Для какого пользователя установить ключ" "root")"
    fi
fi

id "${SSH_USER}" >/dev/null 2>&1 || die "Пользователь '${SSH_USER}' не существует"

HOME_DIR="$(getent passwd "${SSH_USER}" | cut -d: -f6)"
[[ -n "${HOME_DIR}" ]] || die "Не удалось определить домашний каталог пользователя ${SSH_USER}"
USER_GROUP="$(id -gn "${SSH_USER}")"

SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

info "Пользователь: ${SSH_USER} (${HOME_DIR})"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown "${SSH_USER}:${USER_GROUP}" "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
chown "${SSH_USER}:${USER_GROUP}" "${AUTH_KEYS}"

BEFORE="$(count_keys "${AUTH_KEYS}")"
info "Сейчас в authorized_keys: ${BEFORE} ключ(ей)"

# ── Сбор ключей ───────────────────────────────────────────────────────────────
declare -a INCOMING=()

if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    info "Берём ключ(и) из конфигурации"
    while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] && INCOMING+=("${line}")
    done < <(printf '%b\n' "${SSH_PUBLIC_KEY}")
elif interactive; then
    printf '\n%s ─────────────────────────────────────────────────%s\n' "${C_CYAN}" "${C_NC}"
    printf '  Вставьте публичный ключ (ssh-ed25519 / ssh-rsa / ecdsa).\n'
    printf '  Можно несколько строк. Пустая строка — завершить ввод.\n'
    printf '%s ─────────────────────────────────────────────────%s\n\n' "${C_CYAN}" "${C_NC}"
    while true; do
        printf '  Ключ: ' > /dev/tty
        line=""
        read -r line < /dev/tty || break
        [[ -z "${line//[[:space:]]/}" ]] && break
        INCOMING+=("${line}")
    done
else
    warn "Неинтерактивный режим и пустой SSH_PUBLIC_KEY — добавлять нечего"
fi

# ── Запись ────────────────────────────────────────────────────────────────────
ADDED=0
for key in "${INCOMING[@]:-}"; do
    [[ -n "${key//[[:space:]]/}" ]] || continue
    if ! valid_key "${key}"; then
        warn "Не похоже на публичный SSH-ключ, пропускаем: ${key:0:40}..."
        continue
    fi
    body="$(key_body "${key}")"
    if grep -qF -- "${body}" "${AUTH_KEYS}" 2>/dev/null; then
        info "Ключ уже добавлен: $(ssh-keygen -l -f <(printf '%s\n' "${key}") 2>/dev/null | awk '{print $2}')"
        continue
    fi
    printf '%s\n' "${key}" >> "${AUTH_KEYS}"
    ADDED=$((ADDED + 1))
    success "Добавлен: $(ssh-keygen -l -f <(printf '%s\n' "${key}") 2>/dev/null | awk '{print $2, $4}')"
done

chmod 600 "${AUTH_KEYS}"
chown "${SSH_USER}:${USER_GROUP}" "${AUTH_KEYS}"

TOTAL="$(count_keys "${AUTH_KEYS}")"

if [[ "${TOTAL}" -eq 0 ]]; then
    error "В ${AUTH_KEYS} нет ни одного ключа."
    warn  "Не запускайте модуль 05 с SSH_PASSWORD_AUTH=no — потеряете доступ к серверу."
    exit 1
fi

if [[ ${ADDED} -eq 0 ]]; then
    info "Новых ключей не добавлено, уже установлено: ${TOTAL}"
else
    success "Добавлено ключей: ${ADDED}. Всего у ${SSH_USER}: ${TOTAL}"
fi

info "Проверьте вход в НОВОМ окне до перехода к модулю 05."
