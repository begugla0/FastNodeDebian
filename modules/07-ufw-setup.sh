#!/usr/bin/env bash
# ==============================================================================
# Модуль 07 — UFW Firewall
# Платформа: Debian 13 (trixie)
#
# Отличия от прежней версии:
#   - Открываются ВСЕ порты, на которых реально слушает sshd, плюс порт
#     текущего SSH-подключения. Раньше открывался только SSH_PORT из конфига,
#     и запуск модуля до hardening'а обрывал живую сессию без возврата.
#   - Для SSH используется только `ufw limit`. Пара allow+limit из прошлой
#     версии полностью обнуляла rate-limit: allow стоял первым и выигрывал.
#   - Политика FORWARD зависит от NODE_ROLE: для VPN-узла жёсткий deny forward
#     ломал маршрутизацию, ради которой узел и существует.
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "07-ufw-setup"
require_root
require_debian_13

ROLE="${NODE_ROLE:-vpn}"
LOGGING="${UFW_LOGGING:-low}"

step "Настройка UFW"

if ! have ufw; then
    info "Устанавливаем ufw..."
    apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
    apt_install ufw
fi
have ufw || die "ufw не установлен"

# ── 1. Собираем ВСЕ SSH-порты, которые нельзя потерять ───────────────────────
declare -A SSH_PORTS=()

# из конфига
[[ -n "${SSH_PORT:-}" ]] && SSH_PORTS["${SSH_PORT}"]=1

# из живой конфигурации sshd
while read -r p; do
    [[ "${p}" =~ ^[0-9]+$ ]] && SSH_PORTS["${p}"]=1
done < <(sshd_effective_ports 2>/dev/null || true)

# порт текущего подключения — если мы сидим по SSH, он критичен
CUR_PORT="$(current_ssh_port || true)"
if [[ "${CUR_PORT:-}" =~ ^[0-9]+$ ]]; then
    SSH_PORTS["${CUR_PORT}"]=1
    info "Текущее SSH-подключение идёт через порт ${CUR_PORT} — он будет открыт"
fi

# страховка: если ничего не нашли, оставляем 22
[[ ${#SSH_PORTS[@]} -eq 0 ]] && SSH_PORTS[22]=1

info "SSH-порты к открытию: ${!SSH_PORTS[*]}"

# ── 2. Предупреждение перед сбросом ───────────────────────────────────────────
if ufw_is_active; then
    warn "UFW уже активен. Текущие правила будут удалены и заменены."
    ufw status numbered 2>/dev/null | sed 's/^/   /' | head -30 || true
    confirm "Сбросить и пересоздать правила UFW?" no || { info "Отменено."; exit 0; }
fi

# Резервные копии правил на случай ручного восстановления
for f in /etc/ufw/user.rules /etc/ufw/user6.rules /etc/default/ufw; do
    [[ -f "${f}" ]] && backup_file "${f}" >/dev/null || true
done

# ── 3. Политики по умолчанию ──────────────────────────────────────────────────
info "Сброс правил..."
ufw --force reset >/dev/null

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null

if [[ "${ROLE}" == "vpn" ]]; then
    info "Роль ${ROLE}: транзитный трафик РАЗРЕШЁН (нужно для маршрутизации узла)"
    ufw default allow routed >/dev/null
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
else
    info "Роль ${ROLE}: транзитный трафик запрещён"
    ufw default deny routed >/dev/null
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
fi

# ── 4. SSH: только limit, без дублирующего allow ─────────────────────────────
for p in "${!SSH_PORTS[@]}"; do
    info "SSH ${p}/tcp — allow + rate-limit"
    # `ufw limit` сам создаёт разрешающее правило с ограничением
    # 6 подключений за 30 секунд с одного адреса
    ufw limit "${p}/tcp" comment 'SSH rate-limited (FastNode)' >/dev/null
done

# ── 5. Дополнительные порты ───────────────────────────────────────────────────
# Валидация: 80 | 443/tcp | 60000:61000/udp
valid_port_spec() {
    local spec="$1" range proto lo hi
    [[ "${spec}" =~ ^([0-9]+)(:([0-9]+))?(/(tcp|udp))?$ ]] || return 1
    lo="${BASH_REMATCH[1]}"
    hi="${BASH_REMATCH[3]:-${lo}}"
    (( lo >= 1 && lo <= 65535 && hi >= 1 && hi <= 65535 && hi >= lo )) || return 1
    return 0
}

declare -a EXTRA_PORTS=()

# Из конфига (используется в неинтерактивном режиме и как стартовый набор)
if declare -p ALLOWED_PORTS >/dev/null 2>&1 && (( ${#ALLOWED_PORTS[@]} > 0 )); then
    for entry in "${ALLOWED_PORTS[@]}"; do
        [[ -n "${entry//[[:space:]]/}" ]] || continue
        if valid_port_spec "${entry}"; then
            EXTRA_PORTS+=("${entry}")
        else
            warn "ALLOWED_PORTS: пропускаем некорректную запись '${entry}'"
        fi
    done
fi

# Интерактивный ввод: пустая строка дважды завершает
if [[ "${UFW_ASK_PORTS:-yes}" == "yes" ]] && interactive && [[ "${FASTNODE_YES:-0}" != "1" ]]; then
    printf '\n%s ─────────────────────────────────────────────────────────%s\n' "${C_CYAN}" "${C_NC}"
    printf '  Сейчас будет открыт только SSH: %s%s%s\n' "${C_GREEN}" "${!SSH_PORTS[*]}" "${C_NC}"
    printf '  Добавьте другие порты по одному, если нужны.\n'
    printf '  Формат: %s80%s, %s443/tcp%s, %s60000:61000/udp%s\n' \
        "${C_BOLD}" "${C_NC}" "${C_BOLD}" "${C_NC}" "${C_BOLD}" "${C_NC}"
    printf '  Пустая строка %sдважды%s — закончить ввод.\n' "${C_BOLD}" "${C_NC}"
    printf '%s ─────────────────────────────────────────────────────────%s\n\n' "${C_CYAN}" "${C_NC}"

    EMPTY=0
    while true; do
        printf '  Порт: ' > /dev/tty
        LINE=""
        read -r LINE < /dev/tty || break

        if [[ -z "${LINE//[[:space:]]/}" ]]; then
            EMPTY=$(( EMPTY + 1 ))
            if [[ ${EMPTY} -ge 2 ]]; then
                break
            fi
            printf '  %s(ещё раз Enter — завершить ввод)%s\n' "${C_GREY}" "${C_NC}"
            continue
        fi
        EMPTY=0

        LINE="${LINE//[[:space:]]/}"
        if ! valid_port_spec "${LINE}"; then
            warn "Не понял '${LINE}'. Ожидается 80, 443/tcp или 60000:61000/udp"
            continue
        fi

        BASE="${LINE%%/*}"; BASE="${BASE%%:*}"
        if [[ -n "${SSH_PORTS[${BASE}]:-}" ]]; then
            warn "Порт ${BASE} уже открыт как SSH — пропускаем"
            continue
        fi

        DUP=0
        for e in "${EXTRA_PORTS[@]:-}"; do [[ "${e}" == "${LINE}" ]] && DUP=1; done
        if [[ ${DUP} -eq 1 ]]; then
            warn "Порт ${LINE} уже в списке"
            continue
        fi

        EXTRA_PORTS+=("${LINE}")
        printf '  %s✓%s добавлен %s\n' "${C_GREEN}" "${C_NC}" "${LINE}"
    done
    printf '\n'
fi

if (( ${#EXTRA_PORTS[@]} > 0 )); then
    info "Дополнительные порты: ${EXTRA_PORTS[*]}"
    for entry in "${EXTRA_PORTS[@]}"; do
        base="${entry%%/*}"; base="${base%%:*}"
        if [[ -n "${SSH_PORTS[${base}]:-}" ]]; then
            debug "Пропускаем ${entry}: порт уже открыт как SSH"
            continue
        fi
        info "Открываем ${entry}"
        ufw allow "${entry}" comment 'FastNode' >/dev/null \
            || warn "Не удалось добавить правило для ${entry}"
    done
else
    info "Дополнительных портов нет — открыт только SSH"
fi

# ── 6. Логирование и включение ────────────────────────────────────────────────
ufw logging "${LOGGING}" >/dev/null 2>&1 || warn "Не удалось задать уровень логирования ${LOGGING}"

info "Включаем UFW..."
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true

# ── 7. Проверка результата ────────────────────────────────────────────────────
if ! ufw_is_active; then
    die "UFW не активировался. Проверьте: ufw status verbose"
fi

for p in "${!SSH_PORTS[@]}"; do
    out_matches "^${p}/tcp" ufw status \
        || warn "Правило для SSH-порта ${p} не отображается в статусе — проверьте вручную!"
done

echo
ufw status verbose 2>/dev/null | sed 's/^/   /'
echo

success "UFW активен"
info "SSH: ${!SSH_PORTS[*]} (rate-limit) | роль: ${ROLE}"
if [[ "${ROLE}" == "vpn" ]]; then
    info "NAT/masquerade для VPN настраивается отдельно в /etc/ufw/before.rules"
fi
exit 0
