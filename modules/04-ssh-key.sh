#!/bin/bash
# ==============================================================================
# Module 04: Установка SSH публичного ключа
# Поддержка: Debian 9 / 10 / 11 / 12 / 13
#
# Исправлено:
#   - Все read читают из /dev/tty (работает в curl | bash)
#   - Безопасное определение домашнего каталога
#   - Валидация формата ключа перед записью
# ==============================================================================

if ! declare -f info > /dev/null 2>&1; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
    info()    { echo -e "${CYAN} ℹ ${*}${NC}"; }
    warn()    { echo -e "${YELLOW} ⚠ ${*}${NC}"; }
    success() { echo -e "${GREEN} ✓ ${*}${NC}"; }
    error()   { echo -e "${RED} ✗ ${*}${NC}"; exit 1; }
fi

if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
    _BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -f "${_BASE_DIR}/config/settings.conf" ]] && source "${_BASE_DIR}/config/settings.conf"
fi

# Проверяет, является ли строка валидным SSH публичным ключом
_is_valid_ssh_key() {
    local key="$1"
    # Минимальная проверка — начинается с известного типа ключа
    echo "${key}" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) '
}

module_ssh_key() {
    info "Настройка SSH ключей..."

    local ssh_user=""

    # Спрашиваем имя пользователя через /dev/tty (работает при curl|bash)
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        # В неинтерактивном режиме используем root по умолчанию
        ssh_user="root"
        info "Неинтерактивный режим: добавляем ключ для пользователя root"
    else
        printf " ℹ Для какого пользователя установить SSH ключ? [root]: "
        read -r ssh_user </dev/tty
        ssh_user="${ssh_user:-root}"
    fi

    # Проверяем что пользователь существует
    if ! id "${ssh_user}" &>/dev/null; then
        warn "Пользователь '${ssh_user}' не существует"
        return 1
    fi

    # Определяем домашний каталог
    local home_dir
    home_dir=$(getent passwd "${ssh_user}" | cut -d: -f6)
    if [[ -z "${home_dir}" ]]; then
        warn "Не удалось определить домашний каталог пользователя ${ssh_user}"
        return 1
    fi

    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    info "Пользователь: ${ssh_user}"
    info "Домашний каталог: ${home_dir}"
    info "authorized_keys: ${auth_keys}"

    # Создаём .ssh директорию
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    chown "${ssh_user}:" "${ssh_dir}"

    # Инициализируем файл ключей (сохраняем существующие)
    touch "${auth_keys}"

    # === Добавление ключа ===
    local added=0

    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        # Режим из конфига: поддержка нескольких ключей через \n
        info "Добавляем SSH ключ(и) из конфигурации..."
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            if _is_valid_ssh_key "${line}"; then
                # Не дублируем если уже есть
                if ! grep -qF "${line}" "${auth_keys}" 2>/dev/null; then
                    echo "${line}" >> "${auth_keys}"
                    added=$((added + 1))
                    info "Ключ добавлен: ${line:0:40}..."
                else
                    warn "Ключ уже существует, пропускаем"
                fi
            else
                warn "Строка не является валидным SSH ключом, пропускаем: ${line:0:40}"
            fi
        done <<< "$(echo -e "${SSH_PUBLIC_KEY}")"

    else
        # Интерактивный режим: ввод через терминал
        echo ""
        echo -e "${CYAN} ────────────────────────────────────────────────────${NC}"
        echo -e " Вставьте SSH публичный ключ (одна или несколько строк)."
        echo -e " Пустая строка для завершения ввода."
        echo -e "${CYAN} ────────────────────────────────────────────────────${NC}"
        echo ""

        while true; do
            printf " Ключ: "
            local line
            read -r line </dev/tty
            [[ -z "${line}" ]] && break
            if _is_valid_ssh_key "${line}"; then
                if ! grep -qF "${line}" "${auth_keys}" 2>/dev/null; then
                    echo "${line}" >> "${auth_keys}"
                    added=$((added + 1))
                    success "Ключ принят: ${line:0:40}..."
                else
                    warn "Ключ уже существует, пропускаем"
                fi
            else
                warn "Неверный формат ключа. Ожидается: ssh-rsa/ssh-ed25519/ecdsa-sha2-*"
            fi
        done
    fi

    if [[ ${added} -eq 0 ]]; then
        # Проверяем, есть ли уже хоть один ключ
        local total
        total=$(grep -c '.' "${auth_keys}" 2>/dev/null || echo 0)
        if [[ "${total}" -eq 0 ]]; then
            warn "SSH ключи не добавлены! Файл authorized_keys пуст."
            return 1
        else
            info "Новых ключей не добавлено (уже ${total} существующих)"
        fi
    fi

    # Устанавливаем права
    chmod 600 "${auth_keys}"
    chown "${ssh_user}:" "${auth_keys}"

    # Итоговый отчёт
    local total_keys
    total_keys=$(grep -c . "${auth_keys}" 2>/dev/null || echo 0)
    success "SSH ключи настроены для пользователя '${ssh_user}' (итого: ${total_keys} ключ(ей))"
}

module_ssh_key
