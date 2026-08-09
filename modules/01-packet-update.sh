#!/usr/bin/env bash
# ==============================================================================
# Модуль 01 — Обновление пакетов и установка базового набора
# Платформа: Debian 13 (trixie)
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "01-packet-update"
require_root
require_debian_13

step "Обновление системы"
info "Debian $(os_major) ($(os_codename)), ядро $(uname -r)"

# Приводим dpkg в согласованное состояние: иначе любая последующая установка
# упадёт с «dpkg was interrupted».
dpkg --configure -a >/dev/null 2>&1 || warn "dpkg --configure -a вернул ошибку"
apt-get -f install -y "${APT_CONF_OPTS[@]}" >/dev/null 2>&1 || true

info "Обновление списков пакетов..."
apt_update >/dev/null || die "apt-get update не выполнен — проверьте /etc/apt/sources.list и сеть"

info "Обновление установленных пакетов..."
apt-get upgrade -y "${APT_CONF_OPTS[@]}"

info "Full-upgrade (разрешение зависимостей)..."
apt-get full-upgrade -y "${APT_CONF_OPTS[@]}"

# Базовый набор. apt_install сам отсеивает пакеты, которых нет в релизе, —
# раньше один отсутствующий пакет срывал установку всего списка.
if declare -p REQUIRED_PACKAGES >/dev/null 2>&1 && (( ${#REQUIRED_PACKAGES[@]} > 0 )); then
    info "Установка базовых пакетов (${#REQUIRED_PACKAGES[@]} шт.)..."
    apt_install "${REQUIRED_PACKAGES[@]}"
fi

info "Очистка..."
apt-get --purge autoremove -y "${APT_CONF_OPTS[@]}" >/dev/null
apt-get autoclean -y >/dev/null

# Сообщаем, если требуется перезагрузка (обновилось ядро или libc)
if [[ -f /var/run/reboot-required ]]; then
    warn "Система сообщает: требуется перезагрузка (обновлено ядро или системные библиотеки)"
fi

success "Пакеты обновлены"
