#!/bin/bash
# ==============================================================================
# Module 05: SSH Hardening
# Поддержка: Debian 9 / 10 / 11 / 12 / 13
#
# Особенности Debian:
#   - Сервис называется 'ssh' (юнит ssh.service)
#   - Debian 13 (trixie): ssh.socket (socket activation) — отключаем, если есть
#   - Drop-in /etc/ssh/sshd_config.d/ работает только если в основном
#     sshd_config есть строка Include. На Debian 9/10 её НЕТ — добавляем сами.
#   - AuthenticationMethods publickey ставится ТОЛЬКО при наличии ключа,
#     иначе вход по паролю не будет заблокирован.
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

module_ssh_hardening() {
    info "Hardening SSH конфигурации..."

    local ssh_port="${SSH_PORT:-2225}"
    local permit_root="${SSH_PERMIT_ROOT:-yes}"
    local password_auth="${SSH_PASSWORD_AUTH:-no}"
    local hardening_conf="/etc/ssh/sshd_config.d/99-zz-hardening.conf"
    local main_conf="/etc/ssh/sshd_config"
    local backup="${main_conf}.backup.$(date +%Y%m%d_%H%M%S)"

    # Определяем, есть ли у root SSH ключ (умное решение по паролю)
    local has_key=false
    if [[ -s /root/.ssh/authorized_keys ]]; then
        has_key=true
        info "Найден SSH ключ root — вход по паролю будет отключён"
    fi
    [[ "${password_auth}" == "no" ]] && has_key=true  # Из конфига принудительно

    # Каталог drop-in
    mkdir -p /etc/ssh/sshd_config.d/

    # === Гарантируем, что основной sshd_config подхватывает drop-in ===
    # На Debian 11+ строка Include обычно есть. На Debian 9/10 — нет.
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${main_conf}" 2>/dev/null; then
        info "Добавляем 'Include /etc/ssh/sshd_config.d/*.conf' в начало ${main_conf}"
        cp "${main_conf}" "${backup}"
        # Include должен идти как можно раньше: значение берётся из первой встреченной директивы
        printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n%s' "$(cat "${main_conf}")" > "${main_conf}.tmp"
        mv "${main_conf}.tmp" "${main_conf}"
    fi

    # === Debian 13: отключаем socket activation (ssh.socket слушает :22) ===
    if systemctl list-units --type=socket --all 2>/dev/null | grep -q 'ssh.socket'; then
        info "Обнаружен ssh.socket (socket activation) — отключаем..."
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl mask ssh.socket 2>/dev/null || true
        success "ssh.socket отключён и замаскирован"
    fi

    # Резервная копия основного конфига (если ещё не делали)
    [[ -f "${backup}" ]] || cp "${main_conf}" "${backup}"
    info "Резервная копия: ${backup}"

    # === Drop-in конфиг ===
    local auth_methods_line=""
    if [[ "${has_key}" == "true" ]]; then
        auth_methods_line="AuthenticationMethods publickey"
    fi

    info "Создаём drop-in конфиг: ${hardening_conf}"
    cat > "${hardening_conf}" <<EOF
# ======================================================
# FastNodeDebian SSH Hardening
# Автогенерировано: $(date)
# ======================================================

# Нестандартный порт — защита от сканеров
Port ${ssh_port}

# Аутентификация
PermitRootLogin ${permit_root}
PasswordAuthentication $(${has_key} && echo "no" || echo "yes")
PermitEmptyPasswords no
PubkeyAuthentication yes
${auth_methods_line}

# Лимиты подключений
MaxAuthTries 3
MaxSessions 5

# Таймауты (клиент неактивен > 10 мин = отключение)
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30

# Безопасность
X11Forwarding no
AllowTcpForwarding no
PrintLastLog yes

# Современные алгоритмы (поддерживаются OpenSSH 7.4+, т.е. Debian 9+)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
EOF

    success "Drop-in конфиг создан"

    # === Убираем конфликтующие директивы из основного sshd_config ===
    info "Очищаем конфликтующие директивы из основного sshd_config..."
    for directive in Port PermitRootLogin PasswordAuthentication \
                     PermitEmptyPasswords PubkeyAuthentication \
                     MaxAuthTries ClientAliveInterval ClientAliveCountMax; do
        sed -i "s/^${directive}/#${directive}/" "${main_conf}" 2>/dev/null || true
    done

    # === Валидация ===
    info "Валидация конфигурации SSH..."
    if sshd -t 2>&1; then
        success "Конфигурация SSH валидна"
    else
        warn "Ошибка в конфигурации! Откатываем..."
        cp "${backup}" "${main_conf}"
        rm -f "${hardening_conf}"
        error "Откат выполнен. Проверьте конфиг вручную."
    fi

    # === Имя сервиса (Debian: ssh) ===
    local ssh_service="ssh"
    if ! systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
        ssh_service="sshd"
    fi

    info "Перезапуск SSH сервиса (${ssh_service})..."
    systemctl enable "${ssh_service}" 2>/dev/null || true
    systemctl restart "${ssh_service}"

    if systemctl is-active --quiet "${ssh_service}"; then
        success "SSH перезапущен на порту ${ssh_port}"
    else
        warn "SSH не запустился! Откатываем..."
        cp "${backup}" "${main_conf}"
        rm -f "${hardening_conf}"
        systemctl restart "${ssh_service}" || true
        error "Откат выполнен. Проверьте: journalctl -u ${ssh_service}"
    fi

    # === Подтверждение ===
    echo ""
    echo -e "${YELLOW}  ╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}  ║  ⚠ НЕ ЗАКРЫВАЙТЕ ТЕКУЩУЮ СЕССИЮ!                  ║${NC}"
    echo -e "${YELLOW}  ║  Откройте НОВОЕ подключение на порту ${ssh_port}        ║${NC}"
    echo -e "${YELLOW}  ║  Только потом закрывайте эту сессию.              ║${NC}"
    echo -e "${YELLOW}  ╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    printf " Вы успешно подключились к порту ${ssh_port}? (yes/no): "
    local confirm
    read -r confirm </dev/tty

    if [[ "${confirm}" != "yes" ]]; then
        warn "Откатываем конфигурацию SSH..."
        cp "${backup}" "${main_conf}"
        rm -f "${hardening_conf}"
        systemctl unmask ssh.socket 2>/dev/null || true
        systemctl enable --now ssh.socket 2>/dev/null || true
        systemctl restart "${ssh_service}" || true
        warn "Конфигурация SSH восстановлена (порт 22)"
        return 1
    fi

    success "SSH hardening завершён | Порт: ${ssh_port} | Root: ${permit_root} | Password: $(${has_key} && echo "no" || echo "yes")"
}

module_ssh_hardening
