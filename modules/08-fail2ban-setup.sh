#!/bin/bash
# ==============================================================================
# Module 08: Настройка Fail2Ban
# Поддержка: Debian 9 / 10 / 11 / 12 / 13
#
# Особенности:
#   - Backend systemd (journald, без logfiles)
#   - SSH порт из конфига
#   - Детект порт-сканирования через iptables + kern.log/syslog
#   - Автоопределение лог-файла ядра
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

module_fail2ban_setup() {
    info "Установка и настройка Fail2Ban..."

    local ssh_port="${SSH_PORT:-2225}"

    export DEBIAN_FRONTEND=noninteractive

    # Установка
    apt-get install -y fail2ban

    # === Фильтр для порт-сканирования ===
    info "Создаём фильтр порт-сканирования..."
    cat > /etc/fail2ban/filter.d/portscan.conf <<'EOF'
[Definition]
# Детект порт-сканирования через iptables LOG
failregex = PORTSCAN.*SRC=<HOST>
            PORTSCAN:.*SRC=<HOST>
ignoreregex =
EOF

    # === Systemd-сервис для iptables правил (выживает после reboot) ===
    info "Настройка детекта порт-сканирования (iptables)..."
    cat > /etc/systemd/system/portscan-detect.service <<'EOF'
[Unit]
Description=Portscan detection iptables rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
  iptables -N PORTSCAN 2>/dev/null || true; \
  iptables -F PORTSCAN 2>/dev/null || true; \
  iptables -A PORTSCAN -p tcp --tcp-flags ALL NONE -j LOG --log-prefix "PORTSCAN: " --log-level 4; \
  iptables -A PORTSCAN -p tcp --tcp-flags ALL ALL  -j LOG --log-prefix "PORTSCAN: " --log-level 4; \
  iptables -A PORTSCAN -p tcp --tcp-flags ALL FIN,URG,PSH -j LOG --log-prefix "PORTSCAN: " --log-level 4; \
  iptables -A PORTSCAN -p tcp --tcp-flags SYN,RST SYN,RST -j LOG --log-prefix "PORTSCAN: " --log-level 4; \
  iptables -A PORTSCAN -p tcp --tcp-flags SYN,FIN SYN,FIN -j LOG --log-prefix "PORTSCAN: " --log-level 4; \
  iptables -D INPUT -j PORTSCAN 2>/dev/null || true; \
  iptables -I INPUT -j PORTSCAN'
ExecStop=/bin/sh -c '\
  iptables -D INPUT -j PORTSCAN 2>/dev/null || true; \
  iptables -F PORTSCAN 2>/dev/null || true; \
  iptables -X PORTSCAN 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable portscan-detect 2>/dev/null
    systemctl start portscan-detect 2>/dev/null || \
        warn "portscan-detect не стартовал (iptables может быть недоступен в контейнере)"

    # === Определяем лог-файл ядра ===
    local portscan_log=""
    # Убеждаемся что rsyslog активен (нужен для kern.log)
    if command -v rsyslogd &>/dev/null; then
        systemctl is-active --quiet rsyslog 2>/dev/null || \
            systemctl enable --now rsyslog 2>/dev/null || true
    fi

    if [[ -f /var/log/kern.log ]]; then
        portscan_log="/var/log/kern.log"
    elif [[ -f /var/log/syslog ]]; then
        portscan_log="/var/log/syslog"
    fi

    # === Основной конфиг jail.local ===
    info "Создаём /etc/fail2ban/jail.local..."
    cat > /etc/fail2ban/jail.local <<EOF
# ======================================================
# FastNodeDebian: Fail2Ban Configuration
# Автогенерировано: $(date)
# ======================================================

[DEFAULT]
# Бан через UFW (если не установлен — iptables)
banaction = ufw
banaction_allports = ufw

# Игнорировать localhost и приватные сети
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

# Стандартные значения
bantime  = 3600      ; 1 час
findtime = 600       ; 10 минут
maxretry = 5

# ── SSH защита ───────────────────────────────────────
[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
# Ubuntu: journald без лог-файлов
backend  = systemd
maxretry = 5
findtime = 600
bantime  = 3600

EOF

    # Добавляем jail для порт-сканирования только если лог доступен
    if [[ -n "${portscan_log}" ]]; then
        cat >> /etc/fail2ban/jail.local <<EOF
# ── Детект порт-сканирования ─────────────────────────
[portscan]
enabled  = true
filter   = portscan
logpath  = ${portscan_log}
maxretry = 3
findtime = 300
bantime  = 86400     ; 24 часа
EOF
        info "Portscan jail активен (лог: ${portscan_log})"
    else
        warn "Лог ядра не найден — portscan jail отключён"
        info "Установите rsyslog для включения: apt-get install rsyslog"
    fi

    # === Проверяем что UFW установлен (для banaction) ===
    if ! command -v ufw &>/dev/null; then
        warn "UFW не установлен — меняем banaction на iptables"
        sed -i 's/banaction = ufw/banaction = iptables-multiport/' /etc/fail2ban/jail.local
        sed -i 's/banaction_allports = ufw/banaction_allports = iptables-allports/' /etc/fail2ban/jail.local
    fi

    # === Запуск Fail2Ban ===
    info "Запуск Fail2Ban..."
    systemctl enable fail2ban 2>/dev/null
    systemctl restart fail2ban 2>/dev/null

    sleep 3

    if systemctl is-active --quiet fail2ban; then
        success "Fail2Ban запущен"
        echo ""
        info "Активные jail'ы:"
        fail2ban-client status 2>/dev/null | grep "Jail list" || true
        echo ""
    else
        warn "Fail2Ban не запустился. Проверьте: journalctl -u fail2ban -n 30"
    fi

    success "Fail2Ban настроен | SSH порт: ${ssh_port} | bantime: 1ч"
    info "Конфиг: /etc/fail2ban/jail.local"
}

module_fail2ban_setup
