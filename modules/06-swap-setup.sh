#!/usr/bin/env bash
# ==============================================================================
# Модуль 06 — SWAP-файл и параметры виртуальной памяти
# Платформа: Debian 13 (trixie)
#
# Отличия от прежней версии:
#   - В неинтерактивном режиме берётся SWAP_SIZE из конфига, а не зависает
#     на вопросе о размере.
#   - Проверяется свободное место ДО создания файла.
#   - fallocate проверяется на пригодность: при «swapfile has holes» —
#     автоматический откат на dd.
#   - Все vm.* параметры теперь живут ТОЛЬКО здесь (модуль 09 их больше не
#     пишет), поэтому конфликта swappiness между двумя файлами нет.
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "06-swap-setup"
require_root
require_debian_13

SWAPFILE="${SWAP_FILE:-/swapfile}"
SWAPPINESS="${SWAP_SWAPPINESS:-10}"
CACHE_PRESSURE="${SWAP_VFS_CACHE_PRESSURE:-50}"
SIZE="${SWAP_SIZE:-2G}"
SYSCTL_FILE="/etc/sysctl.d/99-fastnode-vm.conf"

step "Настройка SWAP"

CURRENT_MB="$(free -m | awk '/^Swap:/{print $2}')"
ACTIVE="$(swapon --show=NAME --noheadings 2>/dev/null | wc -l)"
info "Сейчас: ${CURRENT_MB} MB swap, активных устройств: ${ACTIVE}"

# ── Нужно ли что-то делать ────────────────────────────────────────────────────
if [[ "${ACTIVE}" -gt 0 && "${CURRENT_MB}" -gt 512 ]]; then
    warn "SWAP уже настроен (${CURRENT_MB} MB)"
    swapon --show 2>/dev/null | sed 's/^/   /'
    if ! confirm "Пересоздать swap-файл ${SWAPFILE}?" no; then
        info "Оставляем существующий SWAP, применяем только параметры vm.*"
        SIZE=""
    fi
fi

# ── Выбор размера ─────────────────────────────────────────────────────────────
if [[ -n "${SIZE}" ]] && interactive && [[ "${FASTNODE_YES:-0}" != "1" ]]; then
    RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
    printf '\n  RAM на сервере: %s MB\n\n' "${RAM_MB}"
    printf '  %s1%s) 1 GB   %s2%s) 2 GB   %s3%s) 3 GB   %s4%s) 4 GB   %s8%s) 8 GB\n\n' \
        "${C_CYAN}" "${C_NC}" "${C_CYAN}" "${C_NC}" "${C_CYAN}" "${C_NC}" \
        "${C_CYAN}" "${C_NC}" "${C_CYAN}" "${C_NC}"
    CHOICE="$(ask "Размер SWAP (1/2/3/4/8)" "${SIZE%[GgMm]}")"
    case "${CHOICE}" in
        1|2|3|4|8) SIZE="${CHOICE}G" ;;
        *[Gg]|*[Mm]) SIZE="${CHOICE^^}" ;;
        *) warn "Непонятный выбор '${CHOICE}', используем ${SWAP_SIZE:-2G}"; SIZE="${SWAP_SIZE:-2G}" ;;
    esac
fi

if [[ -n "${SIZE}" ]]; then
    SIZE_MB="$(size_to_mb "${SIZE}")"
    [[ "${SIZE_MB}" =~ ^[0-9]+$ && "${SIZE_MB}" -ge 128 ]] \
        || die "Некорректный размер SWAP: '${SIZE}' (ожидается вида 2G или 512M)"
    info "Целевой размер: ${SIZE} (${SIZE_MB} MB)"

    # ── Свободное место ───────────────────────────────────────────────────────
    TARGET_DIR="$(dirname "${SWAPFILE}")"
    FREE="$(free_mb "${TARGET_DIR}")"
    OLD_MB=0
    [[ -f "${SWAPFILE}" ]] && OLD_MB="$(( $(stat -c %s "${SWAPFILE}") / 1024 / 1024 ))"
    AVAIL=$(( FREE + OLD_MB ))
    if [[ "${AVAIL}" -lt $(( SIZE_MB + 512 )) ]]; then
        die "Недостаточно места в ${TARGET_DIR}: доступно ${AVAIL} MB, нужно ~$(( SIZE_MB + 512 )) MB"
    fi

    # ── Снимаем старый swap-файл ──────────────────────────────────────────────
    if [[ -f "${SWAPFILE}" ]]; then
        info "Отключаем и удаляем прежний ${SWAPFILE}"
        swapoff "${SWAPFILE}" 2>/dev/null || true
        rm -f "${SWAPFILE}"
    fi

    # ── Создание ──────────────────────────────────────────────────────────────
    FSTYPE="$(stat -f -c %T "${TARGET_DIR}" 2>/dev/null || echo unknown)"
    info "Файловая система ${TARGET_DIR}: ${FSTYPE}"

    create_with_dd() {
        info "Создаём ${SIZE} через dd (может занять время)..."
        dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${SIZE_MB}" status=none
    }

    if [[ "${FSTYPE}" == "btrfs" ]]; then
        # На btrfs swap-файл обязан быть без CoW и без сжатия
        info "btrfs: отключаем CoW для swap-файла"
        truncate -s 0 "${SWAPFILE}"
        chattr +C "${SWAPFILE}" 2>/dev/null || warn "chattr +C не применился"
        create_with_dd
    else
        if ! fallocate -l "${SIZE_MB}M" "${SWAPFILE}" 2>/dev/null; then
            warn "fallocate недоступен на этой ФС"
            create_with_dd
        fi
    fi

    chmod 600 "${SWAPFILE}"
    chown root:root "${SWAPFILE}"

    # ── Форматирование и включение ────────────────────────────────────────────
    if ! mkswap "${SWAPFILE}" >/dev/null; then
        rm -f "${SWAPFILE}"
        die "mkswap не смог отформатировать ${SWAPFILE}"
    fi

    if ! swapon "${SWAPFILE}" 2>/dev/null; then
        # Классический случай: fallocate оставил «дыры» в файле
        warn "swapon отклонил файл (вероятно, разрежённый) — пересоздаём через dd"
        rm -f "${SWAPFILE}"
        create_with_dd
        chmod 600 "${SWAPFILE}"
        mkswap "${SWAPFILE}" >/dev/null
        swapon "${SWAPFILE}" || die "Не удалось включить swap на ${SWAPFILE}"
    fi
    success "SWAP-файл активен"

    # ── fstab ─────────────────────────────────────────────────────────────────
    backup_file /etc/fstab >/dev/null
    sed -i "\|^[[:space:]]*${SWAPFILE}[[:space:]]|d" /etc/fstab
    printf '%s none swap sw 0 0\n' "${SWAPFILE}" >> /etc/fstab
    info "Запись добавлена в /etc/fstab"

    # Проверяем, что fstab не сломан — иначе сервер не загрузится
    if have findmnt && ! findmnt --verify --verbose >/dev/null 2>&1; then
        warn "findmnt сообщает о замечаниях в /etc/fstab — проверьте вручную"
    fi
fi

# ── Параметры виртуальной памяти ──────────────────────────────────────────────
info "Применяем vm.swappiness=${SWAPPINESS}, vm.vfs_cache_pressure=${CACHE_PRESSURE}"
# Резерв свободной памяти. Под сетевой нагрузкой ядру нужен запас для
# атомарных аллокаций; без него на пиках возможны потери пакетов и OOM.
# Держим в пределах ~1-3% RAM: фиксированные 64 МБ на VPS с 1 ГБ — уже 6%.
RAM_MB_TOTAL="$(free -m | awk '/^Mem:/{print $2}')"
if   (( RAM_MB_TOTAL <= 1200 )); then MIN_FREE=32768
elif (( RAM_MB_TOTAL <= 4096 )); then MIN_FREE=65536
else                                  MIN_FREE=131072
fi

write_file "${SYSCTL_FILE}" 0644 <<EOF
# FastNodeDebian — параметры виртуальной памяти (модуль 06)
# Единственное место, где задаются vm.*; сетевые параметры — в модуле 10.
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = ${CACHE_PRESSURE}
vm.min_free_kbytes = ${MIN_FREE}
EOF

# Убираем файл прежней версии скрипта, чтобы не было двух источников правды
[[ -f /etc/sysctl.d/99-swap.conf ]] && rm -f /etc/sysctl.d/99-swap.conf && \
    info "Удалён устаревший /etc/sysctl.d/99-swap.conf"

sysctl_apply "${SYSCTL_FILE}"

NEW_MB="$(free -m | awk '/^Swap:/{print $2}')"
success "SWAP: ${NEW_MB} MB | swappiness=${SWAPPINESS} | vfs_cache_pressure=${CACHE_PRESSURE}"
swapon --show 2>/dev/null | sed 's/^/   /' || true
