#!/bin/bash
# ==============================================================================
# Module 02: Настройка локали (ru_RU.UTF-8)
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

if [[ -z "${LOCALE_LANG:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

module_locale_setup() {
    info "Настройка локали..."

    local lang="${LOCALE_LANG:-ru_RU.UTF-8}"
    local charset="${LOCALE_CHARSET:-UTF-8}"

    export DEBIAN_FRONTEND=noninteractive

    # Устанавливаем locales если нет
    if ! dpkg -l locales &>/dev/null; then
        info "Установка пакета locales..."
        apt-get install -y locales
    fi

    # Активируем нужную локаль в locale.gen
    info "Активация локали ${lang}..."
    if grep -q "^# ${lang} ${charset}" /etc/locale.gen 2>/dev/null; then
        sed -i "s/^# ${lang} ${charset}/${lang} ${charset}/" /etc/locale.gen
    elif ! grep -q "^${lang} ${charset}" /etc/locale.gen 2>/dev/null; then
        echo "${lang} ${charset}" >> /etc/locale.gen
    fi

    # Генерируем локаль
    info "Генерация локали..."
    locale-gen

    # Записываем /etc/default/locale
    info "Применение настроек локали..."
    cat > /etc/default/locale <<EOF
LANG=${lang}
LANGUAGE=${lang}
LC_ALL=${lang}
EOF

    # Для текущей сессии
    export LANG="${lang}"
    export LANGUAGE="${lang}"
    export LC_ALL="${lang}"

    # update-locale для системы (Ubuntu)
    update-locale LANG="${lang}" LANGUAGE="${lang}" LC_ALL="${lang}" 2>/dev/null || true

    success "Локаль настроена: ${lang}"
}

module_locale_setup
