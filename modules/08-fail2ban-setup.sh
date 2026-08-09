#!/usr/bin/env bash
# ==============================================================================
# Модуль 08 — Fail2Ban
# Платформа: Debian 13 (trixie)
#
# Отличия от прежней версии:
#   - Ставится python3-systemd. Без него backend=systemd не работает, служба
#     падает с «Have not found any log file for sshd jail», и защиты нет вовсе,
#     хотя скрипт рапортовал об успехе.
#   - Убраны инлайн-комментарии вида «bantime = 3600 ; 1 час»: парсер fail2ban
#     их не поддерживает и падает на разборе конфига.
#   - Детект сканирования портов больше не вешает собственную цепочку iptables
#     (её затирал любой `ufw reload`, а LOG без лимита заливал диск логами).
#     Вместо этого используются штатные записи UFW BLOCK из журнала ядра.
#   - Результат проверяется через fail2ban-client, а не «служба запустилась».
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "08-fail2ban-setup"
require_root
require_debian_13
require_systemd

JAIL_LOCAL="/etc/fail2ban/jail.local"
PORTSCAN_FILTER="/etc/fail2ban/filter.d/fastnode-portscan.conf"

BANTIME="${F2B_BANTIME:-3600}"
FINDTIME="${F2B_FINDTIME:-600}"
MAXRETRY="${F2B_MAXRETRY:-5}"
PS_BANTIME="${F2B_PORTSCAN_BANTIME:-86400}"
IGNOREIP="${F2B_IGNOREIP:-127.0.0.1/8 ::1}"

step "Настройка Fail2Ban"

# ── 1. Установка ──────────────────────────────────────────────────────────────
info "Устанавливаем fail2ban и python3-systemd..."
apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
apt_install fail2ban python3-systemd

pkg_installed fail2ban || die "fail2ban не установлен"
if ! pkg_installed python3-systemd; then
    warn "python3-systemd отсутствует — чтение журнала systemd будет недоступно"
fi

# ── 2. Чистим наследие прошлой версии ─────────────────────────────────────────
if unit_exists portscan-detect.service; then
    info "Удаляем старую службу portscan-detect (цепочка iptables)"
    systemctl disable --now portscan-detect >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/portscan-detect.service
    systemctl daemon-reload
fi
rm -f /etc/fail2ban/filter.d/portscan.conf 2>/dev/null || true

# ── 3. Определяем источник логов ──────────────────────────────────────────────
# Debian 13 по умолчанию не ставит rsyslog: /var/log/auth.log может не быть,
# и единственный источник — журнал systemd. Но backend=systemd работает
# ТОЛЬКО при установленном python3-systemd, иначе служба падает целиком.
if pkg_installed python3-systemd; then
    JOURNAL_OK=1
else
    JOURNAL_OK=0
fi

if [[ -f /var/log/auth.log ]]; then
    SSH_BACKEND="auto"
    SSH_LOGPATH="/var/log/auth.log"
    info "Источник логов SSH: ${SSH_LOGPATH}"
elif [[ ${JOURNAL_OK} -eq 1 ]]; then
    SSH_BACKEND="systemd"
    SSH_LOGPATH=""
    info "Файл /var/log/auth.log отсутствует — используем журнал systemd"
else
    error "Нет ни /var/log/auth.log, ни python3-systemd."
    info  "Установите один из источников логов:"
    info  "    apt-get install python3-systemd     (чтение журнала systemd)"
    info  "    apt-get install rsyslog             (классический /var/log/auth.log)"
    die   "Без источника логов jail sshd не заработает — настройка прервана."
fi

# Backend по умолчанию для остальных джейлов
if [[ ${JOURNAL_OK} -eq 1 ]]; then
    DEFAULT_BACKEND="systemd"
else
    DEFAULT_BACKEND="auto"
fi

# Джейл сканирования портов читает сообщения ядра (UFW BLOCK).
# Нужен либо журнал systemd, либо kern.log от rsyslog.
PORTSCAN_OK=0
PORTSCAN_BACKEND=""
PORTSCAN_LOGPATH=""
if [[ "${F2B_ENABLE_PORTSCAN:-yes}" == "yes" ]]; then
    if [[ ${JOURNAL_OK} -eq 1 ]]; then
        PORTSCAN_OK=1
        PORTSCAN_BACKEND="systemd"
    elif [[ -f /var/log/kern.log ]]; then
        PORTSCAN_OK=1
        PORTSCAN_BACKEND="auto"
        PORTSCAN_LOGPATH="/var/log/kern.log"
    else
        warn "Джейл сканирования портов отключён: нет ни журнала systemd, ни /var/log/kern.log"
    fi
fi

# ── 4. Действие бана ──────────────────────────────────────────────────────────
if ufw_is_active; then
    BANACTION="ufw"
    BANACTION_ALL="ufw"
    info "Баны будут применяться через UFW"
else
    BANACTION="nftables-multiport"
    BANACTION_ALL="nftables-allports"
    warn "UFW неактивен — баны через nftables. Рекомендуется сначала выполнить модуль 07."
fi

# ── 5. Собственный IP администратора в исключения ─────────────────────────────
if [[ "${F2B_IGNORE_CURRENT_SSH:-yes}" == "yes" && -n "${SSH_CONNECTION:-}" ]]; then
    CLIENT_IP="$(awk '{print $1}' <<< "${SSH_CONNECTION}")"
    if [[ -n "${CLIENT_IP}" ]] && ! grep -qF "${CLIENT_IP}" <<< "${IGNOREIP}"; then
        IGNOREIP="${IGNOREIP} ${CLIENT_IP}"
        info "Ваш текущий IP ${CLIENT_IP} добавлен в исключения (защита от самобана)"
    fi
fi

# ── 6. Фильтр сканирования портов ─────────────────────────────────────────────
info "Создаём фильтр ${PORTSCAN_FILTER}"
write_file "${PORTSCAN_FILTER}" 0644 <<'EOF'
# FastNodeDebian: срабатывает на пакеты, отброшенные UFW.
# Записи приходят от ядра, поэтому источник — журнал systemd (_TRANSPORT=kernel)
# либо /var/log/kern.log при установленном rsyslog.
[Definition]
failregex = ^.*\[UFW BLOCK\].*\sSRC=<HOST>\s
ignoreregex =
journalmatch = _TRANSPORT=kernel
EOF

# ── 7. jail.local ─────────────────────────────────────────────────────────────
# ВНИМАНИЕ: никаких комментариев в конце строк со значениями —
# парсер fail2ban воспринимает их как часть значения.
info "Создаём ${JAIL_LOCAL}"
[[ -f "${JAIL_LOCAL}" ]] && backup_file "${JAIL_LOCAL}" >/dev/null || true

# Порты для jail sshd. `paste` на пустом вводе возвращает пустую строку С кодом 0,
# поэтому конструкция «... | paste || echo 22» фолбэк не срабатывала и в конфиг
# попадала строка «port =» без значения.
SSHD_PORTS="$(sshd_effective_ports 2>/dev/null | paste -sd, - || true)"
if [[ -z "${SSHD_PORTS//[[:space:]]/}" ]]; then
    SSHD_PORTS="${SSH_PORT:-22}"
    warn "Не удалось прочитать порты из sshd — используем ${SSHD_PORTS}"
fi
info "Jail sshd будет следить за портами: ${SSHD_PORTS}"

{
cat <<EOF
# ==============================================================================
# FastNodeDebian — Fail2Ban
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# Комментарии допустимы только на отдельных строках.
# ==============================================================================

[DEFAULT]
banaction = ${BANACTION}
banaction_allports = ${BANACTION_ALL}
ignoreip = ${IGNOREIP}
bantime = ${BANTIME}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}
backend = ${DEFAULT_BACKEND}

[sshd]
enabled = true
port = ${SSHD_PORTS}
filter = sshd
mode = normal
backend = ${SSH_BACKEND}
EOF

[[ -n "${SSH_LOGPATH}" ]] && printf 'logpath = %s\n' "${SSH_LOGPATH}" || true

cat <<EOF
maxretry = ${MAXRETRY}
findtime = ${FINDTIME}
bantime = ${BANTIME}
EOF

if [[ ${PORTSCAN_OK} -eq 1 ]]; then
cat <<EOF

# Сканирование портов: реагируем на записи UFW BLOCK
[fastnode-portscan]
enabled = true
filter = fastnode-portscan
backend = ${PORTSCAN_BACKEND}
banaction = %(banaction_allports)s
maxretry = ${F2B_PORTSCAN_MAXRETRY:-15}
findtime = ${F2B_PORTSCAN_FINDTIME:-60}
bantime = ${PS_BANTIME}
EOF
[[ -n "${PORTSCAN_LOGPATH}" ]] && printf 'logpath = %s\n' "${PORTSCAN_LOGPATH}" || true
fi
true
} | write_file "${JAIL_LOCAL}" 0644

# ── 8. Проверка конфигурации до перезапуска ───────────────────────────────────
info "Проверка конфигурации fail2ban..."
if ! fail2ban-client --test >/dev/null 2>&1; then
    error "fail2ban-client --test выявил ошибки:"
    fail2ban-client --test 2>&1 | tail -20 | sed 's/^/   /'
    die "Конфигурация fail2ban некорректна, служба не перезапускалась."
fi
success "Конфигурация корректна"

# ── 9. Запуск ─────────────────────────────────────────────────────────────────
info "Запускаем fail2ban..."
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

for _ in 1 2 3 4 5 6; do
    svc_active fail2ban && break
    sleep 1
done

svc_active fail2ban || {
    error "fail2ban не запустился:"
    journalctl -u fail2ban -n 25 --no-pager 2>/dev/null | sed 's/^/   /'
    die "Разберите ошибки и запустите модуль повторно."
}

# ── 10. Реальная проверка джейлов, а не только статуса службы ────────────────
sleep 2
JAILS="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d ' \t')"
if [[ -z "${JAILS}" ]]; then
    warn "Служба работает, но ни один jail не поднялся — защиты нет!"
    journalctl -u fail2ban -n 20 --no-pager 2>/dev/null | sed 's/^/   /'
    exit 1
fi

info "Активные jail'ы: ${JAILS//,/, }"
if grep -q 'sshd' <<< "${JAILS}"; then
    fail2ban-client status sshd 2>/dev/null | sed 's/^/   /'
else
    warn "Jail sshd не активен — проверьте источник логов SSH"
fi

success "Fail2Ban настроен | bantime=${BANTIME}s | maxretry=${MAXRETRY} | banaction=${BANACTION}"
info "Конфиг: ${JAIL_LOCAL}"
info "Снять бан:  fail2ban-client set sshd unbanip <IP>"
