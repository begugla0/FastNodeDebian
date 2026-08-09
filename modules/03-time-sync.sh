#!/usr/bin/env bash
# ==============================================================================
# Модуль 03 — Часовой пояс и синхронизация времени (chrony)
# Платформа: Debian 13 (trixie)
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "03-time-sync"
require_root
require_debian_13

TZ_WANT="${TIMEZONE:-Europe/Moscow}"

step "Синхронизация времени"

# ── Часовой пояс ──────────────────────────────────────────────────────────────
if [[ ! -f "/usr/share/zoneinfo/${TZ_WANT}" ]]; then
    die "Часовой пояс '${TZ_WANT}' не найден в /usr/share/zoneinfo"
fi

info "Устанавливаем часовой пояс: ${TZ_WANT}"
if systemd_present && have timedatectl && timedatectl set-timezone "${TZ_WANT}" 2>/dev/null; then
    debug "Часовой пояс задан через timedatectl"
else
    # Контейнеры и окружения без работающего systemd
    warn "timedatectl недоступен — задаём часовой пояс напрямую"
    ln -sf "/usr/share/zoneinfo/${TZ_WANT}" /etc/localtime
    printf '%s\n' "${TZ_WANT}" > /etc/timezone
    have dpkg-reconfigure && DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
fi

# ── chrony ────────────────────────────────────────────────────────────────────
if ! pkg_installed chrony; then
    info "Устанавливаем chrony..."
    apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
    apt_install chrony
fi

if ! systemd_present; then
    warn "systemd отсутствует — служба времени не будет запущена автоматически"
    success "Часовой пояс установлен: ${TZ_WANT}"
    exit 0
fi

# systemd-timesyncd конфликтует с chrony за порт 123
if unit_exists systemd-timesyncd.service; then
    if svc_active systemd-timesyncd || svc_enabled systemd-timesyncd; then
        info "Отключаем systemd-timesyncd (конфликтует с chrony)"
        systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    fi
fi

# В Debian служба называется chrony.service, но встречается алиас chronyd
CHRONY_UNIT="chrony.service"
unit_exists "${CHRONY_UNIT}" || CHRONY_UNIT="chronyd.service"
unit_exists "${CHRONY_UNIT}" || die "Не найден systemd-юнит chrony"

info "Запускаем ${CHRONY_UNIT}..."
svc_enable_now "${CHRONY_UNIT}"

# Даём демону подняться и форсируем шаговую коррекцию
sleep 2
if have chronyc; then
    chronyc -a makestep >/dev/null 2>&1 \
        || chronyc makestep >/dev/null 2>&1 \
        || warn "Немедленная синхронизация не выполнена (chrony ещё стартует)"
fi

if svc_active "${CHRONY_UNIT}"; then
    success "chrony работает"
    have chronyc && chronyc tracking 2>/dev/null | sed -n '1,4p' | sed 's/^/   /' || true
else
    warn "chrony не запустился. Диагностика: journalctl -u ${CHRONY_UNIT} -n 30"
fi

info "Текущее время: $(date '+%Y-%m-%d %H:%M:%S %Z')"
success "Синхронизация времени настроена (${TZ_WANT})"
