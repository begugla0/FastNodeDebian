#!/bin/bash
# ==============================================================================
# Module 06: Настройка SWAP
# Поддержка: Debian 9 / 10 / 11 / 12 / 13
#
# Интерактивный выбор размера: 1GB / 2GB / 3GB / 4GB
# ==============================================================================

if ! declare -f info > /dev/null 2>&1; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
    info()    { echo -e "${CYAN} ℹ ${*}${NC}"; }
    warn()    { echo -e "${YELLOW} ⚠ ${*}${NC}"; }
    success() { echo -e "${GREEN} ✓ ${*}${NC}"; }
    error()   { echo -e "${RED} ✗ ${*}${NC}"; exit 1; }
fi

if [[ -z "${SWAP_FILE:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

module_swap_setup() {
    info "Проверка и настройка SWAP..."

    local swap_file="${SWAP_FILE:-/swapfile}"
    local swappiness="${SWAP_SWAPPINESS:-10}"
    local swap_size="${SWAP_SIZE:-2G}"

    # Текущий статус swap
    local swap_exists
    swap_exists=$(swapon --show --noheadings 2>/dev/null | wc -l)
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    info "Текущий SWAP: ${current_swap_mb} MB (активных разделов: ${swap_exists})"

    # Если swap уже достаточный — спрашиваем хотят ли переделать
    if [[ ${swap_exists} -gt 0 ]] && [[ ${current_swap_mb} -gt 512 ]]; then
        warn "SWAP уже настроен: ${current_swap_mb} MB"
        printf " Пересоздать SWAP? (yes/no) [no]: "
        local recreate
        read -r recreate </dev/tty
        if [[ "${recreate}" != "yes" ]]; then
            info "Оставляем существующий SWAP"
            return 0
        fi
    fi

    # === Интерактивный выбор размера ===
    echo ""
    echo -e "${CYAN}  Выберите размер SWAP:${NC}"
    echo -e "  ${CYAN}1${NC}) 1 GB  — минимум для серверов с 1 GB RAM"
    echo -e "  ${CYAN}2${NC}) 2 GB  — рекомендуется для 1–2 GB RAM  [по умолчанию]"
    echo -e "  ${CYAN}3${NC}) 3 GB  — оптимально для 2–4 GB RAM"
    echo -e "  ${CYAN}4${NC}) 4 GB  — для 4–8 GB RAM при пиковых нагрузках"
    echo ""

    local choice
    printf "  Введите 1/2/3/4 [2]: "
    read -r choice </dev/tty

    case "${choice}" in
        1) swap_size="1G" ;;
        2|"") swap_size="2G" ;;
        3) swap_size="3G" ;;
        4) swap_size="4G" ;;
        *)
            warn "Неверный выбор '${choice}', используем 2G"
            swap_size="2G"
            ;;
    esac

    info "Выбран размер SWAP: ${swap_size}"

    # Проверяем тип ФС (btrfs требует особого обращения)
    local fs_type
    fs_type=$(stat -f -c %T "$(dirname "${swap_file}")" 2>/dev/null || echo "ext4")

    # Удаляем старый swap если есть
    if [[ -f "${swap_file}" ]]; then
        info "Отключаем старый swap..."
        swapoff "${swap_file}" 2>/dev/null || true
        rm -f "${swap_file}"
    fi

    # Создаём swap файл
    info "Создаём swap файл ${swap_size}..."

    if [[ "${fs_type}" == "btrfs" ]]; then
        # На btrfs нужно отключить COW для swap файла
        info "Обнаружена btrfs — использую специальный метод создания..."
        touch "${swap_file}"
        chattr +C "${swap_file}" 2>/dev/null || warn "chattr +C не сработал (ОК для старых btrfs)"
        fallocate -l "${swap_size}" "${swap_file}" 2>/dev/null || \
            dd if=/dev/zero of="${swap_file}" bs=1M count="$(echo "${swap_size}" | sed 's/G/*1024/' | bc)" status=none
    else
        # ext4, xfs и другие — fallocate быстрее
        if ! fallocate -l "${swap_size}" "${swap_file}" 2>/dev/null; then
            info "fallocate не поддерживается, используем dd..."
            dd if=/dev/zero of="${swap_file}" bs=1M count="$(echo "${swap_size}" | sed 's/G/*1024/' | bc)" status=progress
        fi
    fi

    # Устанавливаем права
    chmod 600 "${swap_file}"

    # Форматируем и включаем
    mkswap "${swap_file}"
    swapon "${swap_file}"

    # Добавляем в /etc/fstab (перманентно)
    if grep -q "${swap_file}" /etc/fstab 2>/dev/null; then
        # Обновляем существующую запись
        sed -i "\|${swap_file}|d" /etc/fstab
    fi
    echo "${swap_file} none swap sw 0 0" >> /etc/fstab
    info "SWAP добавлен в /etc/fstab"

    # Настраиваем swappiness через sysctl
    info "Настройка swappiness=${swappiness}..."
    sysctl -w vm.swappiness="${swappiness}" > /dev/null

    # Записываем постоянно
    local sysctl_file="/etc/sysctl.d/99-swap.conf"
    cat > "${sysctl_file}" <<EOF
# FastNodeDebian: SWAP tuning
vm.swappiness = ${swappiness}
vm.vfs_cache_pressure = 50
EOF
    sysctl -p "${sysctl_file}" > /dev/null

    # Проверка
    local new_swap_mb
    new_swap_mb=$(free -m | awk '/Swap:/ {print $2}')
    success "SWAP настроен: ${new_swap_mb} MB | swappiness=${swappiness}"
}

module_swap_setup
