#!/bin/bash
# ==============================================================================
# Module 03: Синхронизация времени (chrony)
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

if [[ -z "${TIMEZONE:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

module_time_sync() {
    info "Настройка синхронизации времени..."

    local tz="${TIMEZONE:-Europe/Moscow}"

    export DEBIAN_FRONTEND=noninteractive

    # Устанавливаем chrony (точнее и надёжнее, чем systemd-timesyncd)
    info "Установка chrony..."
    apt-get install -y chrony

    # Отключаем системный timesyncd (конфликтует с chrony)
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        info "Отключаем systemd-timesyncd..."
        systemctl disable --now systemd-timesyncd 2>/dev/null || true
    fi

    # Устанавливаем часовой пояс
    info "Установка часового пояса: ${tz}..."
    timedatectl set-timezone "${tz}"

    # Включаем и запускаем chrony
    systemctl enable chrony
    systemctl restart chrony

    # Форсируем немедленную синхронизацию
    sleep 2
    info "Принудительная синхронизация..."
    chronyc -a makestep 2>/dev/null || \
        chronyc makestep 2>/dev/null || \
        warn "Принудительная синхронизация не удалась (chrony ещё запускается)"

    # Проверка
    info "Текущее время: $(date)"
    info "Часовой пояс: $(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep 'Time zone' | awk '{print $3}')"

    if systemctl is-active --quiet chrony; then
        success "chrony запущен и синхронизирован"
    else
        warn "chrony не запустился — проверьте: journalctl -u chrony"
    fi

    success "Синхронизация времени настроена"
}

module_time_sync
