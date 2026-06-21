#!/bin/bash
# ==============================================================================
# Module 07: Настройка UFW Firewall
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

if [[ -z "${SSH_PORT:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

module_ufw_setup() {
    info "Настройка UFW firewall..."

    local ssh_port="${SSH_PORT:-2225}"
    local allowed_ports=("${ALLOWED_PORTS[@]:-80 443}")

    export DEBIAN_FRONTEND=noninteractive

    # Устанавливаем UFW если нет
    if ! command -v ufw &>/dev/null; then
        info "Установка ufw..."
        apt-get install -y ufw
    fi

    # Сбрасываем UFW до чистого состояния
    info "Сброс правил UFW..."
    ufw --force reset

    # Политики по умолчанию
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny forward

    # Разрешаем SSH (КРИТИЧНО — делаем первым!)
    info "Разрешаем SSH на порту ${ssh_port}..."
    ufw allow "${ssh_port}/tcp" comment 'SSH Access'

    # Разрешаем порты из конфига
    for port in "${allowed_ports[@]}"; do
        # Не дублируем SSH порт
        if [[ "${port}" != "${ssh_port}" ]]; then
            info "Разрешаем порт ${port}..."
            ufw allow "${port}" comment 'Custom'
        fi
    done

    # Защита от brute-force: ограничение подключений к SSH
    info "Включаем rate-limit для SSH..."
    ufw limit "${ssh_port}/tcp" comment 'SSH Rate Limit'

    # Включаем UFW (без интерактивного подтверждения)
    info "Включаем UFW..."
    echo "y" | ufw enable

    # Перезагружаем правила
    ufw reload

    # Итоговый статус
    echo ""
    ufw status verbose
    echo ""

    success "UFW настроен и включён"
    info "Открытые порты: SSH=${ssh_port}, ${allowed_ports[*]}"
}

module_ufw_setup
