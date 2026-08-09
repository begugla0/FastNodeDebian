#!/usr/bin/env bash
# ==============================================================================
# Модуль 05 — Hardening SSH
# Платформа: Debian 13 (trixie), OpenSSH 9/10
#
# Главное исправление: в прошлой версии значение SSH_PASSWORD_AUTH="no" из
# конфига безусловно выставляло has_key=true, из-за чего пароль отключался
# даже при полном отсутствии ключей — гарантированная потеря доступа.
# Теперь наличие ключа проверяется реально, а без него режим key-only просто
# недоступен (кроме явного SSH_FORCE_NO_PASSWORD=1).
#
# Дополнительно:
#   - Основной sshd_config больше не «режется» sed'ом вслепую: эффективная
#     конфигурация проверяется через sshd -T, правка делается только при нужде.
#   - Порт открывается в UFW ДО рестарта, если файрвол уже активен.
#   - Проверяется, что sshd реально слушает новый порт.
#   - Подтверждение с таймаутом: нет ответа — автоматический откат.
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "05-ssh-hardening"
require_root
require_debian_13

SSHD_MAIN="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/99-zz-fastnode-hardening.conf"

PORT="${SSH_PORT:-2225}"
PERMIT_ROOT="${SSH_PERMIT_ROOT:-prohibit-password}"
PASSWORD_POLICY="${SSH_PASSWORD_AUTH:-auto}"
TCP_FWD="${SSH_ALLOW_TCP_FORWARDING:-no}"
MAX_TRIES="${SSH_MAX_AUTH_TRIES:-3}"
CONFIRM_TIMEOUT="${SSH_CONFIRM_TIMEOUT:-180}"

BACKUP=""
SOCKET_WAS_ENABLED=0
SOCKET_WAS_ACTIVE=0
SSH_UNIT="ssh.service"

[[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
    || die "Некорректный SSH_PORT: ${PORT}"

# ── Вспомогательное ───────────────────────────────────────────────────────────

# Пересечение желаемого списка алгоритмов с теми, что реально поддерживает
# установленный OpenSSH. Хардкод списка ломал sshd -t при смене версии.
filter_supported() {
    local kind="$1" wanted="$2" supported out=""
    supported="$(ssh -Q "${kind}" 2>/dev/null || true)"
    [[ -n "${supported}" ]] || { printf '%s' "${wanted}"; return 0; }
    local a
    IFS=',' read -ra arr <<< "${wanted}"
    for a in "${arr[@]}"; do
        grep -qxF -- "${a}" <<< "${supported}" && out+="${a},"
    done
    printf '%s' "${out%,}"
}

# Есть ли в системе хоть один установленный публичный ключ
find_authorized_keys() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -f "${f}" ]] || continue
        if grep -qvE '^[[:space:]]*(#|$)' "${f}" 2>/dev/null; then
            printf '%s\n' "${f}"
        fi
    done
}

rollback() {
    warn "Выполняется откат конфигурации SSH..."
    rm -f "${DROPIN}"
    [[ -n "${BACKUP}" && -f "${BACKUP}" ]] && cp -a "${BACKUP}" "${SSHD_MAIN}"
    if [[ ${SOCKET_WAS_ENABLED} -eq 1 ]]; then
        systemctl unmask ssh.socket >/dev/null 2>&1 || true
        systemctl enable ssh.socket >/dev/null 2>&1 || true
        [[ ${SOCKET_WAS_ACTIVE} -eq 1 ]] && systemctl start ssh.socket >/dev/null 2>&1 || true
    fi
    systemctl restart "${SSH_UNIT}" >/dev/null 2>&1 || true
    warn "Конфигурация SSH восстановлена из ${BACKUP:-резервной копии}"
}

step "Hardening SSH"

# ── 1. Определяем политику пароля ────────────────────────────────────────────
mapfile -t KEYFILES < <(find_authorized_keys)
HAS_KEY=0
[[ ${#KEYFILES[@]} -gt 0 ]] && HAS_KEY=1

if [[ ${HAS_KEY} -eq 1 ]]; then
    info "Найдены публичные ключи: ${KEYFILES[*]}"
else
    warn "Публичных ключей в системе не найдено"
fi

KEY_ONLY=0
case "${PASSWORD_POLICY,,}" in
    yes)
        info "Политика: вход по паролю остаётся разрешён (SSH_PASSWORD_AUTH=yes)"
        ;;
    auto)
        if [[ ${HAS_KEY} -eq 1 ]]; then
            KEY_ONLY=1
            info "Политика auto: ключ найден → вход по паролю будет отключён"
        else
            warn "Политика auto: ключей нет → пароль ОСТАЁТСЯ включённым (защита от локаута)"
            info "Добавьте ключ модулем 04 и запустите этот модуль повторно."
        fi
        ;;
    no)
        if [[ ${HAS_KEY} -eq 1 ]]; then
            KEY_ONLY=1
        elif [[ "${SSH_FORCE_NO_PASSWORD:-0}" == "1" ]]; then
            KEY_ONLY=1
            warn "SSH_FORCE_NO_PASSWORD=1 при отсутствии ключей — вы можете потерять доступ!"
            confirm "Точно продолжить и отключить пароль без единого ключа?" no \
                || die "Отменено пользователем."
        else
            error "SSH_PASSWORD_AUTH=no, но в системе нет ни одного authorized_keys."
            info  "Это привело бы к полной потере доступа. Сначала выполните модуль 04."
            info  "Осознанный обход: SSH_FORCE_NO_PASSWORD=1"
            exit 1
        fi
        ;;
    *)
        die "Недопустимое значение SSH_PASSWORD_AUTH='${PASSWORD_POLICY}' (auto|no|yes)"
        ;;
esac

# ── 2. Резервная копия и Include ──────────────────────────────────────────────
[[ -f "${SSHD_MAIN}" ]] || die "Не найден ${SSHD_MAIN} — установлен ли openssh-server?"
BACKUP="$(backup_file "${SSHD_MAIN}")"
info "Резервная копия: ${BACKUP}"

mkdir -p "${DROPIN_DIR}"
chmod 755 "${DROPIN_DIR}"

if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_MAIN}"; then
    info "Добавляем Include для drop-in каталога в начало ${SSHD_MAIN}"
    { printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat "${SSHD_MAIN}"; } > "${SSHD_MAIN}.new"
    mv -f "${SSHD_MAIN}.new" "${SSHD_MAIN}"
fi

# ── 3. ssh.socket (socket activation перехватывает порт 22) ──────────────────
if unit_exists ssh.socket; then
    svc_enabled ssh.socket && SOCKET_WAS_ENABLED=1
    svc_active  ssh.socket && SOCKET_WAS_ACTIVE=1
    if [[ ${SOCKET_WAS_ENABLED} -eq 1 || ${SOCKET_WAS_ACTIVE} -eq 1 ]]; then
        info "Отключаем ssh.socket — при socket activation порт задаётся юнитом, а не sshd_config"
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl mask ssh.socket >/dev/null 2>&1 || true
    fi
fi

unit_exists ssh.service || SSH_UNIT="sshd.service"
unit_exists "${SSH_UNIT}" || die "Не найден systemd-юнит SSH"

# ── 4. Drop-in конфиг ─────────────────────────────────────────────────────────
KEX="$(filter_supported kex 'sntrup761x25519-sha512@openssh.com,mlkem768x25519-sha256,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512')"
CIPHERS="$(filter_supported cipher 'chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr')"
MACS="$(filter_supported mac 'hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com')"

if [[ ${KEY_ONLY} -eq 1 ]]; then
    PASS_LINE="no"; KBD_LINE="no"; AUTH_METHODS="AuthenticationMethods publickey"
else
    PASS_LINE="yes"; KBD_LINE="yes"; AUTH_METHODS="# AuthenticationMethods не задан: разрешён вход по паролю"
fi

info "Создаём ${DROPIN}"
write_file "${DROPIN}" 0600 <<EOF
# ==============================================================================
# FastNodeDebian — SSH hardening
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# Файл имеет наивысший приоритет: в sshd выигрывает ПЕРВОЕ вхождение директивы,
# а Include стоит в начале /etc/ssh/sshd_config.
# ==============================================================================

Port ${PORT}
AddressFamily any

# ── Аутентификация ───────────────────────────────────────────────────────────
PermitRootLogin ${PERMIT_ROOT}
PubkeyAuthentication yes
PasswordAuthentication ${PASS_LINE}
# Без этой директивы PAM может пропустить вход по паролю в обход
# PasswordAuthentication no — классическая дыра в hardening-скриптах.
KbdInteractiveAuthentication ${KBD_LINE}
PermitEmptyPasswords no
${AUTH_METHODS}

# ── Лимиты ───────────────────────────────────────────────────────────────────
MaxAuthTries ${MAX_TRIES}
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# ── Ограничения возможностей ─────────────────────────────────────────────────
X11Forwarding no
AllowTcpForwarding ${TCP_FWD}
AllowAgentForwarding no
PermitTunnel no
PrintLastLog yes
UseDNS no

# ── Криптография (отфильтрована по ssh -Q для этой версии OpenSSH) ───────────
KexAlgorithms ${KEX}
Ciphers ${CIPHERS}
MACs ${MACS}
EOF

# ── 5. Валидация синтаксиса ───────────────────────────────────────────────────
info "Проверка синтаксиса (sshd -t)..."
if ! sshd -t 2>&1 | tee -a "${LOG_FILE}"; then
    rollback
    die "Конфигурация SSH невалидна, изменения откачены."
fi
success "Синтаксис корректен"

# ── 6. Проверка ЭФФЕКТИВНОЙ конфигурации ──────────────────────────────────────
# Если в основном sshd_config директива стоит РАНЬШЕ Include, выигрывает она.
EFFECTIVE_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
if [[ "${EFFECTIVE_PORT}" != "${PORT}" ]]; then
    warn "Эффективный порт ${EFFECTIVE_PORT} ≠ ${PORT}: основной конфиг перекрывает drop-in"
    info "Комментируем конфликтующие директивы в ${SSHD_MAIN}"
    for d in Port PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication \
             PermitEmptyPasswords PubkeyAuthentication MaxAuthTries \
             ClientAliveInterval ClientAliveCountMax X11Forwarding AllowTcpForwarding; do
        sed -i -E "s|^[[:space:]]*(${d}[[:space:]])|#\1|I" "${SSHD_MAIN}"
    done
    sshd -t || { rollback; die "Правка основного конфига сломала синтаксис — откат выполнен."; }
    EFFECTIVE_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    [[ "${EFFECTIVE_PORT}" == "${PORT}" ]] \
        || { rollback; die "Не удалось применить порт ${PORT} (эффективный: ${EFFECTIVE_PORT})"; }
fi
success "Эффективная конфигурация: порт ${EFFECTIVE_PORT}"

# ── 7. Открываем порт в UFW ДО рестарта ───────────────────────────────────────
if ufw_is_active; then
    info "UFW активен — заранее открываем порт ${PORT}"
    ufw allow "${PORT}/tcp" comment 'SSH (FastNode)' >/dev/null 2>&1 || \
        warn "Не удалось добавить правило UFW — откройте порт вручную"
fi

# ── 8. Рестарт и проверка прослушивания ───────────────────────────────────────
info "Перезапуск ${SSH_UNIT}..."
systemctl enable "${SSH_UNIT}" >/dev/null 2>&1 || true
if ! systemctl restart "${SSH_UNIT}"; then
    rollback
    die "SSH не перезапустился. Диагностика: journalctl -u ${SSH_UNIT} -n 50"
fi

sleep 2
if ! svc_active "${SSH_UNIT}"; then
    rollback
    die "Служба ${SSH_UNIT} не активна после рестарта — откат выполнен."
fi

LISTENING=0
for _ in 1 2 3 4 5; do
    LISTEN_OUT="$(ss -H -tln 2>/dev/null || true)"
    if grep -qE "[:.]${PORT}[[:space:]]" <<< "${LISTEN_OUT}"; then
        LISTENING=1; break
    fi
    sleep 1
done
if [[ ${LISTENING} -ne 1 ]]; then
    rollback
    die "sshd не слушает порт ${PORT} — откат выполнен."
fi
success "sshd слушает порт ${PORT}"

# ── 9. Подтверждение живого доступа ───────────────────────────────────────────
printf '\n%s' "${C_YELLOW}"
cat <<BOX
  ╔═══════════════════════════════════════════════════════════╗
  ║  ⚠  НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ                              ║
  ║                                                           ║
  ║  Откройте НОВОЕ окно терминала и проверьте вход:          ║
BOX
printf '  ║    ssh -p %-6s %-33s ║\n' "${PORT}" "$(id -un)@$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<BOX
  ║                                                           ║
  ║  Если не ответить — конфигурация откатится автоматически. ║
  ╚═══════════════════════════════════════════════════════════╝
BOX
printf '%s\n' "${C_NC}"

if interactive && [[ "${FASTNODE_YES:-0}" != "1" ]]; then
    printf '%s ? Подключение по порту %s работает? (yes/no, %s сек до авто-отката): %s' \
        "${C_YELLOW}" "${PORT}" "${CONFIRM_TIMEOUT}" "${C_NC}" > /dev/tty
    ANSWER=""
    if ! read -r -t "${CONFIRM_TIMEOUT}" ANSWER < /dev/tty; then
        echo
        warn "Ответа нет ${CONFIRM_TIMEOUT} сек — считаем, что доступ потерян."
        rollback
        die "Откат выполнен, SSH вернулся к прежним настройкам."
    fi
    if [[ ! "${ANSWER,,}" =~ ^(y|yes|д|да)$ ]]; then
        rollback
        die "Откат выполнен по вашему запросу."
    fi
else
    warn "Неинтерактивный режим: подтверждение пропущено, откат не выполняется."
fi

printf '\n'
success "SSH hardening завершён"
info "Порт: ${PORT} | root: ${PERMIT_ROOT} | пароль: ${PASS_LINE} | TCP-forwarding: ${TCP_FWD}"
info "Резервная копия основного конфига: ${BACKUP}"
[[ ${KEY_ONLY} -eq 0 ]] && warn "Вход по паролю ВКЛЮЧЁН. Добавьте ключ (модуль 04) и повторите модуль 05."
exit 0
