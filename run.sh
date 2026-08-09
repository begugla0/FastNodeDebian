#!/usr/bin/env bash
# ==============================================================================
# FastNodeDebian — run.sh
#
#   curl -fsSL https://raw.githubusercontent.com/begugla0/FastNodeDebian/main/run.sh | bash
#
# Аргументы передаются в main.sh:
#   curl -fsSL .../run.sh | bash -s -- --upgrade
#   curl -fsSL .../run.sh | bash -s -- --all --yes
# ==============================================================================

set -Eeuo pipefail

REPO_URL="${FASTNODE_REPO:-https://github.com/begugla0/FastNodeDebian.git}"
BRANCH="${FASTNODE_BRANCH:-main}"
INSTALL_DIR="${FASTNODE_DIR:-/opt/FastNodeDebian}"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; C=$'\033[0;36m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; C=''; N=''
fi

say()  { printf '%s ℹ%s %s\n' "${C}" "${N}" "$*"; }
ok()   { printf '%s ✓%s %s\n' "${G}" "${N}" "$*"; }
bad()  { printf '%s ✗%s %s\n' "${R}" "${N}" "$*" >&2; }
note() { printf '%s ⚠%s %s\n' "${Y}" "${N}" "$*" >&2; }

printf '\n%s  ⚡ FastNodeDebian — установка%s\n\n' "${C}" "${N}"

[[ ${EUID} -eq 0 ]] || { bad "Запустите от root: curl ... | sudo bash"; exit 1; }

if ! grep -qi debian /etc/os-release 2>/dev/null && [[ ! -r /etc/debian_version ]]; then
    bad "Обнаружен не Debian. Скрипт предназначен только для Debian."
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    say "Устанавливаем git..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    say "Обновляем существующую копию в ${INSTALL_DIR}"
    # Логи и правленый конфиг переживают обновление — прошлая версия
    # сносила каталог целиком вместе с ними.
    git -C "${INSTALL_DIR}" fetch --depth 1 origin "${BRANCH}" >/dev/null 2>&1 || true
    if ! git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}" >/dev/null 2>&1; then
        note "Обновление через git не удалось — переклонируем"
        BACKUP="${INSTALL_DIR}.bak.$(date +%s)"
        mv "${INSTALL_DIR}" "${BACKUP}"
        note "Прежняя копия сохранена: ${BACKUP}"
        git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
    fi
else
    if [[ -e "${INSTALL_DIR}" ]]; then
        BACKUP="${INSTALL_DIR}.bak.$(date +%s)"
        note "Каталог занят, переносим в ${BACKUP}"
        mv "${INSTALL_DIR}" "${BACKUP}"
    fi
    say "Клонируем репозиторий..."
    git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/modules/*.sh 2>/dev/null || true
mkdir -p "${INSTALL_DIR}/logs"

ok "Установлено в ${INSTALL_DIR}"
printf '\n'

cd "${INSTALL_DIR}"
export FASTNODE_ROOT="${INSTALL_DIR}"
exec bash "${INSTALL_DIR}/main.sh" "$@"
