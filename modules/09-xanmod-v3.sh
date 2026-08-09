#!/usr/bin/env bash
# ==============================================================================
# Модуль 09 — Ядро XanMod (BBRv3) и тюнинг сетевого стека
# Платформа: Debian 13 (trixie), архитектура amd64
#
# Репозиторий XanMod использует в качестве suite кодовое имя дистрибутива;
# для trixie доступна основная ветка (linux-xanmod-x64vN), пакетов уровня
# v4 не существует — поэтому определение уровня ограничено v3.
#
# Отличия от прежней версии:
#   - Уровень x86-64 psABI определяется по полному набору флагов, а не по
#     одному avx2: CPU без bmi2/fma получал v3 и не загружался.
#   - Проверяется свободное место в /boot — самая частая причина провала
#     установки ядра на VPS.
#   - Модуль не пишет sysctl и лимиты вообще: этим занимается модуль 10,
#     единственный владелец сетевых параметров. Раньше 06 и 09 задавали
#     разный swappiness в двух файлах.
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "09-xanmod"
require_root
require_debian_13

BRANCH="${XANMOD_BRANCH:-main}"
ROLE="${NODE_ROLE:-vpn}"
KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"

banner "XanMod Kernel + BBRv3"

# ── 1. Пригодность окружения ──────────────────────────────────────────────────
ARCH="$(dpkg --print-architecture)"
[[ "${ARCH}" == "amd64" ]] || die "XanMod публикуется только для amd64, обнаружено: ${ARCH}"

if have systemd-detect-virt; then
    VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    info "Виртуализация: ${VIRT}"
    case "${VIRT}" in
        lxc|lxc-libvirt|openvz|docker|podman|systemd-nspawn|wsl)
            die "Контейнер ${VIRT} использует ядро хоста — заменить его невозможно." ;;
    esac
fi

BOOT_FREE="$(free_mb /boot)"
if [[ -n "${BOOT_FREE}" && "${BOOT_FREE}" -lt 400 ]]; then
    error "На /boot свободно ${BOOT_FREE} MB, ядру нужно ~400 MB."
    info  "Освободите место:  apt-get --purge autoremove   и удалите старые linux-image-*"
    die   "Установка прервана до устранения нехватки места."
fi

if have mokutil && out_matches_i 'enabled' mokutil --sb-state; then
    warn "Secure Boot ВКЛЮЧЁН — неподписанное ядро XanMod не загрузится."
    confirm "Всё равно продолжить?" no || exit 0
fi

info "Текущее ядро: $(uname -r)"

# ── 2. Уровень x86-64 psABI ───────────────────────────────────────────────────
# Логика соответствует официальному check_x86-64_psabi.sh: уровень определяется
# полным набором флагов, а не одним признаком.
CPU_FLAGS=" $(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo) "

has_flags() {
    local f
    for f in "$@"; do
        [[ "${CPU_FLAGS}" == *" ${f} "* ]] || return 1
    done
    return 0
}

CPU_LEVEL=1
has_flags cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 && CPU_LEVEL=2
if [[ ${CPU_LEVEL} -eq 2 ]] && has_flags avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; then
    CPU_LEVEL=3
fi

CPU_MODEL="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs)"
info "CPU: ${CPU_MODEL} ($(nproc) ядер)"
success "Уровень набора инструкций: x86-64-v${CPU_LEVEL}"

if [[ ${CPU_LEVEL} -lt 2 && "${BRANCH}" != "lts" ]]; then
    warn "Основная ветка XanMod собирается только для v2 и выше."
    info "Для этого CPU доступна только LTS-ветка (linux-xanmod-lts-x64v1)."
    BRANCH="lts"
fi

# ── 3. Репозиторий ────────────────────────────────────────────────────────────
step "Подключение репозитория XanMod"
apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
apt_install ca-certificates curl gnupg

mkdir -p /etc/apt/keyrings
rm -f "${KEYRING}" /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || true

info "Импорт ключа подписи..."
curl -fsSL https://dl.xanmod.org/archive.key \
    | gpg --dearmor -o "${KEYRING}" \
    || die "Не удалось получить ключ https://dl.xanmod.org/archive.key"
chmod 0644 "${KEYRING}"

CODENAME="$(os_codename)"
printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "${KEYRING}" "${CODENAME}" > "${REPO_FILE}"
info "Источник: deb.xanmod.org ${CODENAME} main"

if ! apt_update >/dev/null; then
    rm -f "${REPO_FILE}"
    die "Репозиторий XanMod не отвечает для '${CODENAME}'. Источник удалён."
fi

# ── 4. Подбор метапакета ──────────────────────────────────────────────────────
case "${BRANCH}" in
    main) PREFIX="linux-xanmod" ;;
    lts)  PREFIX="linux-xanmod-lts" ;;
    edge) PREFIX="linux-xanmod-edge" ;;
    rt)   PREFIX="linux-xanmod-rt" ;;
    *)    die "Недопустимый XANMOD_BRANCH='${BRANCH}' (main|lts|edge|rt)" ;;
esac

KERNEL_PKG=""
for pfx in "${PREFIX}" linux-xanmod linux-xanmod-lts; do
    for lvl in "${CPU_LEVEL}" 2 1; do
        [[ ${lvl} -gt ${CPU_LEVEL} ]] && continue
        cand="${pfx}-x64v${lvl}"
        if apt_available "${cand}"; then
            KERNEL_PKG="${cand}"
            break 2
        fi
    done
done

[[ -n "${KERNEL_PKG}" ]] || {
    error "Подходящий метапакет XanMod не найден. Доступно:"
    apt-cache search '^linux-xanmod' 2>/dev/null | head -20 | sed 's/^/   /' || true
    die "Установка прервана."
}

[[ "${KERNEL_PKG}" == "${PREFIX}-x64v${CPU_LEVEL}" ]] \
    || warn "Запрошенный ${PREFIX}-x64v${CPU_LEVEL} недоступен, ставим ${KERNEL_PKG}"

step "Установка ядра ${KERNEL_PKG}"
apt-get install -y "${APT_CONF_OPTS[@]}" "${KERNEL_PKG}" \
    || die "Установка ${KERNEL_PKG} не удалась (см. вывод apt выше)"

if [[ "${XANMOD_INSTALL_HEADERS:-yes}" == "yes" ]]; then
    info "Ставим инструменты сборки внешних модулей (dkms и пр.)..."
    apt-get install -y --no-install-recommends "${APT_CONF_OPTS[@]}" \
        dkms libelf-dev clang lld llvm >/dev/null 2>&1 \
        || warn "Пакеты для DKMS установить не удалось (не критично)"
fi

INSTALLED_IMG="$(dpkg-query -W -f='${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | tail -1 || true)"
success "Ядро установлено${INSTALLED_IMG:+: ${INSTALLED_IMG}}"

# ── 5. Тюнинг сетевого стека ──────────────────────────────────────────────────
# Сетевые параметры и лимиты вынесены в модуль 10: он единственный владелец
# /etc/sysctl.d/99-fastnode-net.conf. Раньше два модуля писали пересекающиеся
# ключи в разные файлы, и действовало то значение, чей файл шёл последним.
step "Тюнинг сетевого стека"
if [[ -x "${_DIR}/10-node-tuning.sh" || -f "${_DIR}/10-node-tuning.sh" ]]; then
    info "Запускаем модуль 10 (BBR, буферы, conntrack, лимиты)..."
    if bash "${_DIR}/10-node-tuning.sh"; then
        success "Тюнинг применён"
    else
        warn "Модуль 10 завершился с ошибкой — примените тюнинг вручную:"
        warn "  bash main.sh --module 10"
    fi
else
    warn "Модуль 10 не найден — BBR и лимиты не настроены."
    info "Запустите позже:  bash main.sh --module 10"
fi

# ── 7. Скрипт проверки после перезагрузки ─────────────────────────────────────
write_file /usr/local/bin/fastnode-verify 0755 <<'VERIFY'
#!/usr/bin/env bash
# Проверка состояния узла после перезагрузки
printf 'Ядро:            %s\n' "$(uname -r)"
printf 'XanMod:          %s\n' "$(grep -qi xanmod /proc/version && echo да || echo НЕТ)"
printf 'Congestion:      %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf 'Qdisc:           %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
printf 'Доступные CC:    %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
printf 'ip_forward:      %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
printf 'nofile:          %s\n' "$(ulimit -n)"
printf 'SSH порты:       %s\n' "$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | paste -sd, -)"
printf 'UFW:             %s\n' "$(ufw status 2>/dev/null | head -1 || true)"
printf 'Fail2Ban:        %s\n' "$(systemctl is-active fail2ban 2>/dev/null)"
printf 'SWAP:            %s MB\n' "$(free -m | awk '/^Swap:/{print $2}')"
VERIFY
info "Создана команда проверки: fastnode-verify"

# ── Итог ──────────────────────────────────────────────────────────────────────
echo
success "XanMod установлен"
printf '   Пакет:       %s\n' "${KERNEL_PKG}"
printf '   Уровень CPU: x86-64-v%s\n' "${CPU_LEVEL}"
echo
warn "Изменения вступят в силу ТОЛЬКО после перезагрузки."
info "После неё выполните:  fastnode-verify"
echo

if confirm "Перезагрузить сервер сейчас?" no; then
    info "Перезагрузка через 5 секунд..."
    sleep 5
    systemctl reboot 2>/dev/null || reboot
else
    warn "Не забудьте перезагрузиться: reboot"
fi
