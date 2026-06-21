#!/bin/bash
# ==============================================================================
# Module 01: Обновление пакетов системы
# Поддержка: Debian 9 / 10 / 11 / 12 / 13
# ==============================================================================

if ! declare -f info > /dev/null 2>&1; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
    info()    { echo -e "${CYAN} ℹ ${*}${NC}"; }
    warn()    { echo -e "${YELLOW} ⚠ ${*}${NC}"; }
    success() { echo -e "${GREEN} ✓ ${*}${NC}"; }
    error()   { echo -e "${RED} ✗ ${*}${NC}"; exit 1; }
fi

if [[ -z "${REQUIRED_PACKAGES[*]:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

module_packet_update() {
    info "Обновление системных пакетов..."

    if ! grep -qi "debian" /etc/os-release 2>/dev/null && [[ ! -r /etc/debian_version ]]; then
        warn "Скрипт оптимизирован для Debian, продолжаем..."
    fi

    local ver codename
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-?}")"
    codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-?}")"
    info "Версия Debian: ${ver} (${codename})"

    export DEBIAN_FRONTEND=noninteractive

    info "Обновление списков пакетов..."
    apt-get update -y || { warn "apt-get update завершился с ошибкой, продолжаем..."; }

    info "Обновление установленных пакетов..."
    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confdef"

    info "Full-upgrade (зависимости)..."
    apt-get full-upgrade -y \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confdef"

    if [[ ${#REQUIRED_PACKAGES[@]} -gt 0 ]]; then
        info "Установка базовых пакетов: ${REQUIRED_PACKAGES[*]}"
        apt-get install -y "${REQUIRED_PACKAGES[@]}" \
            -o Dpkg::Options::="--force-confold" \
            -o Dpkg::Options::="--force-confdef" \
            || warn "Часть пакетов не установилась (возможно, недоступны в этом релизе)"
    fi

    info "Очистка кэша..."
    apt-get autoremove -y
    apt-get autoclean -y

    success "Система обновлена (Debian ${ver})"
}

module_packet_update
