#!/usr/bin/env bash
# ==============================================================================
# Модуль 02 — Настройка локали
# Платформа: Debian 13 (trixie)
#
# Отличия от прежней версии:
#   - НЕ выставляется LC_ALL в /etc/default/locale. LC_ALL перекрывает все
#     остальные категории и ломает разбор вывода утилит в скриптах.
#   - LANGUAGE записывается в правильном формате «ru_RU:ru», а не как локаль.
#   - Дополнительно генерируется en_US.UTF-8 (нужна многим сервисам).
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "02-locale-setup"
require_root
require_debian_13

LANG_WANT="${LOCALE_LANG:-ru_RU.UTF-8}"
CHARSET="${LOCALE_CHARSET:-UTF-8}"
LOCALE_GEN="/etc/locale.gen"

step "Настройка локали ${LANG_WANT}"

if ! pkg_installed locales; then
    info "Устанавливаем пакет locales..."
    apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
    apt_install locales
fi

# Список локалей к генерации: основная + дополнительные из конфига
declare -a WANT=("${LANG_WANT} ${CHARSET}")
if declare -p LOCALE_EXTRA >/dev/null 2>&1 && (( ${#LOCALE_EXTRA[@]} > 0 )); then
    WANT+=("${LOCALE_EXTRA[@]}")
fi

backup_file "${LOCALE_GEN}" >/dev/null
touch "${LOCALE_GEN}"

for entry in "${WANT[@]}"; do
    [[ -n "${entry}" ]] || continue
    if grep -qE "^[[:space:]]*${entry//./\\.}[[:space:]]*$" "${LOCALE_GEN}"; then
        debug "Уже активна: ${entry}"
    elif grep -qE "^[[:space:]]*#[[:space:]]*${entry//./\\.}[[:space:]]*$" "${LOCALE_GEN}"; then
        sed -i -E "s|^[[:space:]]*#[[:space:]]*(${entry//./\\.})[[:space:]]*$|\1|" "${LOCALE_GEN}"
        info "Раскомментирована: ${entry}"
    else
        printf '%s\n' "${entry}" >> "${LOCALE_GEN}"
        info "Добавлена: ${entry}"
    fi
done

info "Генерация локалей (может занять до минуты)..."
locale-gen

# Проверяем, что локаль действительно собралась
if ! out_matches_i "^${LANG_WANT//./\\.}$|^${LANG_WANT%%.*}\.utf8$" locale -a; then
    die "Локаль ${LANG_WANT} не сгенерирована. Проверьте её наличие в /usr/share/i18n/SUPPORTED"
fi

# LANGUAGE — это список языков через двоеточие, а не имя локали
LANGUAGE_VAL="${LANG_WANT%%.*}"
LANGUAGE_VAL="${LANGUAGE_VAL}:${LANGUAGE_VAL%%_*}"

backup_file /etc/default/locale >/dev/null
write_file /etc/default/locale 0644 <<EOF
# Сгенерировано FastNodeDebian (модуль 02)
LANG=${LANG_WANT}
LANGUAGE=${LANGUAGE_VAL}
EOF

# Снимаем LC_ALL, если его прописала предыдущая версия скрипта
sed -i '/^LC_ALL=/d' /etc/default/locale 2>/dev/null || true

if have localectl && systemd_present; then
    localectl set-locale "LANG=${LANG_WANT}" >/dev/null 2>&1 \
        || warn "localectl не смог применить локаль (не критично)"
fi

success "Локаль настроена: LANG=${LANG_WANT}, LANGUAGE=${LANGUAGE_VAL}"
info "В текущей сессии изменения не действуют — перелогиньтесь."
