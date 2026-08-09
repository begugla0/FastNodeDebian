#!/usr/bin/env bash
# ==============================================================================
# Модуль 10 — Тюнинг узла под прокси/VPN-нагрузку
# Платформа: Debian 13 (trixie)
#
# Этот модуль — ЕДИНСТВЕННЫЙ владелец сетевых параметров ядра
# (/etc/sysctl.d/99-fastnode-net.conf) и лимитов дескрипторов.
# Модуль 06 отвечает только за vm.*, модуль 09 — только за установку ядра.
# Разделение принципиально: два файла sysctl с пересекающимися ключами дают
# непредсказуемый результат, потому что применяется последний по алфавиту.
#
# Работает и без XanMod: тюнинг полезен на любом ядре.
# В контейнерах (LXC/OpenVZ) недоступные параметры пропускаются без ошибки.
#
#   bash modules/10-node-tuning.sh
# ==============================================================================

set -Eeuo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_DIR}/../lib/common.sh"
load_settings
trap_setup "10-node-tuning"
require_root
require_debian_13

SYSCTL_NET="/etc/sysctl.d/99-fastnode-net.conf"
LIMITS_FILE="/etc/security/limits.d/99-fastnode-limits.conf"
MODLOAD_DIR="/etc/modules-load.d"
NIC_UNIT="/etc/systemd/system/fastnode-nic-tune.service"
DNSMASQ_CONF="/etc/dnsmasq.d/fastnode.conf"

ROLE="${NODE_ROLE:-vpn}"
PROFILE="${TUNE_PROFILE:-auto}"
[[ "${PROFILE}" == "auto" ]] && { [[ "${ROLE}" == "vpn" ]] && PROFILE="proxy" || PROFILE="plain"; }

RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
CPUS="$(nproc)"

# Каталоги могут отсутствовать в минимальной установке
for d in /etc/sysctl.d /etc/modules-load.d /etc/modprobe.d /etc/security/limits.d; do
    mkdir -p "${d}"
done

step "Тюнинг узла"
info "Профиль: ${PROFILE} | роль: ${ROLE} | ${CPUS} vCPU, ${RAM_MB} MB RAM"
is_container && warn "Контейнер $(virt_type): часть параметров ядра задать нельзя, они будут пропущены"

# ── 1. Congestion control ─────────────────────────────────────────────────────
modprobe tcp_bbr 2>/dev/null || true
AVAIL_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo cubic)"
if grep -qw bbr <<< "${AVAIL_CC}"; then
    CC="bbr"
    ok_cc="доступен"
else
    CC="cubic"
    warn "BBR недоступен в текущем ядре — оставляем cubic."
    info "Получить BBR: bash main.sh --module 9 (ядро XanMod)"
    ok_cc="недоступен"
fi
info "Congestion control: ${CC} (bbr ${ok_cc})"

# ── 2. qdisc ──────────────────────────────────────────────────────────────────
QDISC="${TUNE_QDISC:-${DEFAULT_QDISC:-fq}}"
if [[ "${QDISC}" != "fq" ]]; then
    if ! modprobe "sch_${QDISC}" 2>/dev/null && [[ ! -d "/sys/module/sch_${QDISC}" ]]; then
        warn "Планировщик ${QDISC} недоступен — используем fq"
        QDISC="fq"
    fi
fi
info "Планировщик очереди: ${QDISC}"

# ── 3. conntrack ──────────────────────────────────────────────────────────────
# Нужен для UDP port-hopping и NAT. Модуль грузим заранее, иначе
# net.netfilter.* просто не применятся.
CT_MAX=0
if [[ "${TUNE_CONNTRACK:-auto}" == "auto" ]] && ! is_container; then
    modprobe nf_conntrack 2>/dev/null || true
    if [[ -d /proc/sys/net/netfilter ]]; then
        # Одна запись conntrack — примерно 350 байт. 256 записей на МБ RAM
        # означали бы ~9% памяти под таблицу на VPS с 1 ГБ, поэтому берём 128.
        CT_MAX=$(( RAM_MB * 128 ))
        (( CT_MAX > 1048576 )) && CT_MAX=1048576
        (( CT_MAX < 65536 ))   && CT_MAX=65536
        CT_BUCKETS=$(( CT_MAX / 4 ))
        CT_MEM_MB=$(( CT_MAX * 350 / 1048576 ))

        printf 'nf_conntrack\n' > "${MODLOAD_DIR}/fastnode-conntrack.conf"
        # hashsize задаётся параметром модуля, а не sysctl
        printf 'options nf_conntrack hashsize=%s\n' "${CT_BUCKETS}" \
            > /etc/modprobe.d/fastnode-conntrack.conf
        if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
            printf '%s' "${CT_BUCKETS}" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
        fi
        info "conntrack: max=${CT_MAX}, hashsize=${CT_BUCKETS} (~${CT_MEM_MB} MB RAM)"
    else
        warn "netfilter недоступен — conntrack не настраивается"
    fi
fi

printf 'tcp_bbr\n' > "${MODLOAD_DIR}/fastnode-bbr.conf"

# ── 4. rp_filter ──────────────────────────────────────────────────────────────
case "${TUNE_RP_FILTER:-loose}" in
    strict) RPF=1 ;;
    loose)  RPF=2 ;;
    off)    RPF=0 ;;
    *)      die "Недопустимое TUNE_RP_FILTER='${TUNE_RP_FILTER}' (strict|loose|off)" ;;
esac
[[ ${RPF} -eq 0 ]] && warn "rp_filter=0: защита от подмены исходного адреса отключена"

# ── 5. Лимиты дескрипторов ────────────────────────────────────────────────────
# Сам по себе лимит памяти не занимает — она расходуется только на реально
# открытые дескрипторы. Поэтому масштабировать потолок по объёму RAM смысла нет,
# а вред есть: на VPS с 1 ГБ прежняя формула давала fs.nr_open=65535, то есть
# ОПУСКАЛА штатный потолок ядра (1048576) вместо того, чтобы его поднять.
NOFILE="${TUNE_NOFILE:-1048576}"
[[ "${NOFILE}" =~ ^[0-9]+$ ]] || die "TUNE_NOFILE должно быть числом, получено '${NOFILE}'"

# Текущие значения ядра: понижать их нельзя ни при каких настройках
CUR_NR_OPEN="$(sysctl -n fs.nr_open 2>/dev/null || echo 1048576)"
CUR_FILE_MAX="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
[[ "${CUR_NR_OPEN}"  =~ ^[0-9]+$ ]] || CUR_NR_OPEN=1048576
[[ "${CUR_FILE_MAX}" =~ ^[0-9]+$ ]] || CUR_FILE_MAX=0

max_of() { local m="$1"; shift; local v; for v in "$@"; do (( v > m )) && m="${v}"; done; printf '%s' "${m}"; }

# fs.nr_open — жёсткий потолок для любого nofile. Обязан быть не меньше и
# самого лимита, и штатного значения ядра.
NR_OPEN="$(max_of "${NOFILE}" "${CUR_NR_OPEN}" 1048576)"
FILE_MAX="$(max_of $(( NOFILE * 2 )) "${CUR_FILE_MAX}")"

info "Лимит дескрипторов: nofile=${NOFILE}, fs.nr_open=${NR_OPEN}, fs.file-max=${FILE_MAX}"
(( NR_OPEN > CUR_NR_OPEN )) && info "Потолок хоста поднимается: ${CUR_NR_OPEN} → ${NR_OPEN}"
true

# ── 6. Буферы под профиль ─────────────────────────────────────────────────────
if [[ "${PROFILE}" == "proxy" ]]; then
    # Крупные буферы важны для QUIC/Hysteria2: quic-go опирается на
    # net.core.rmem_max / wmem_max напрямую.
    if   (( RAM_MB <= 1200 )); then MEMMAX=8388608;  DEFBUF=524288
    elif (( RAM_MB <= 4096 )); then MEMMAX=16777216; DEFBUF=1048576
    else                            MEMMAX=33554432; DEFBUF=1048576
    fi
    BACKLOG=32768; SOMAX=65535; SYNBACK=32768
else
    if   (( RAM_MB <= 1200 )); then MEMMAX=4194304;  DEFBUF=262144
    elif (( RAM_MB <= 4096 )); then MEMMAX=8388608;  DEFBUF=262144
    else                            MEMMAX=16777216; DEFBUF=524288
    fi
    BACKLOG=8192; SOMAX=8192; SYNBACK=8192
fi

FORWARD=0
[[ "${ROLE}" == "vpn" ]] && FORWARD=1

# ── 7. Файл sysctl ────────────────────────────────────────────────────────────
info "Записываем ${SYSCTL_NET}"

# Файлы прежних версий: убираем, чтобы у ключей был ровно один владелец
for old in /etc/sysctl.d/99-xanmod-node.conf /etc/sysctl.d/99-xray-tuning.conf; do
    [[ -f "${old}" ]] && { rm -f "${old}"; info "Удалён устаревший ${old}"; }
done

{
cat <<EOF
# ==============================================================================
# FastNodeDebian — сетевой стек (модуль 10)
# Профиль: ${PROFILE} | роль: ${ROLE} | RAM ${RAM_MB} MB | ${CPUS} vCPU
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
#
# Единственный файл, задающий net.* и fs.*.
# Параметры vm.* задаёт модуль 06 (99-fastnode-vm.conf).
# ==============================================================================

# ── Управление перегрузкой ───────────────────────────────────────────────────
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}

# ── Буферы сокетов ───────────────────────────────────────────────────────────
# net.ipv4.tcp_mem и udp_mem намеренно НЕ задаются: ядро вычисляет их от объёма
# памяти при загрузке. Фиксированные значения из типовых «тюнинг-скриптов»
# (3 ГБ/4 ГБ/102 ГБ в страницах) на VPS с 1-2 ГБ снимают защиту от исчерпания
# памяти и приводят к OOM вместо отбрасывания пакетов.
net.core.rmem_max = ${MEMMAX}
net.core.wmem_max = ${MEMMAX}
net.core.rmem_default = ${DEFBUF}
net.core.wmem_default = ${DEFBUF}
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 262144 ${MEMMAX}
net.ipv4.tcp_wmem = 4096 262144 ${MEMMAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ── Очереди и бэклоги ────────────────────────────────────────────────────────
net.core.somaxconn = ${SOMAX}
net.core.netdev_max_backlog = ${BACKLOG}
net.core.netdev_budget = 600
net.ipv4.tcp_max_syn_backlog = ${SYNBACK}
net.ipv4.tcp_max_tw_buckets = 262144

# ── Поведение TCP ────────────────────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_rfc1337 = 1

# ── Маршрутизация ────────────────────────────────────────────────────────────
net.ipv4.ip_forward = ${FORWARD}
net.ipv6.conf.all.forwarding = ${FORWARD}

# ── Защита стека ─────────────────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = ${RPF}
net.ipv4.conf.default.rp_filter = ${RPF}
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.kptr_restrict = 2

# ── Файловые дескрипторы ─────────────────────────────────────────────────────
# fs.nr_open — потолок для LimitNOFILE и ulimit -n. Если он ниже, чем
# DefaultLimitNOFILE, systemd не сможет запустить службу.
fs.nr_open = ${NR_OPEN}
fs.file-max = ${FILE_MAX}
fs.inotify.max_user_instances = 8192
EOF

if [[ -n "${TUNE_PORT_RANGE:-}" ]]; then
cat <<EOF

# ── Диапазон исходящих портов ────────────────────────────────────────────────
# Держите служебные порты (SSH, панель) ВНЕ этого диапазона.
net.ipv4.ip_local_port_range = ${TUNE_PORT_RANGE}
EOF
fi

if (( CT_MAX > 0 )); then
cat <<EOF

# ── conntrack ────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
EOF
fi
true
} | write_file "${SYSCTL_NET}" 0644

sysctl_apply "${SYSCTL_NET}"

# ── 8. Лимиты ─────────────────────────────────────────────────────────────────
write_file "${LIMITS_FILE}" 0644 <<EOF
# FastNodeDebian — лимиты дескрипторов (модуль 10)
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
* soft nproc unlimited
* hard nproc unlimited
EOF

# Потолок должен действовать УЖЕ СЕЙЧАС, иначе systemd отвергнет
# DefaultLimitNOFILE и службы не поднимутся до перезагрузки.
LIVE_NR_OPEN="$(sysctl -n fs.nr_open 2>/dev/null || echo 0)"
if [[ "${LIVE_NR_OPEN}" =~ ^[0-9]+$ ]] && (( LIVE_NR_OPEN < NOFILE )); then
    warn "fs.nr_open=${LIVE_NR_OPEN} меньше запрошенного nofile=${NOFILE}"
    if sysctl -w "fs.nr_open=${NR_OPEN}" >/dev/null 2>&1; then
        success "Потолок поднят на лету: fs.nr_open=${NR_OPEN}"
    else
        warn "Не удалось поднять fs.nr_open (контейнер?) — снижаем nofile до ${LIVE_NR_OPEN}"
        NOFILE="${LIVE_NR_OPEN}"
    fi
fi

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
printf '[Manager]\nDefaultLimitNOFILE=%s\nDefaultLimitNPROC=infinity\n' "${NOFILE}" \
    > /etc/systemd/system.conf.d/99-fastnode-limits.conf
printf '[Manager]\nDefaultLimitNOFILE=%s\n' "${NOFILE}" \
    > /etc/systemd/user.conf.d/99-fastnode-limits.conf
# Убираем файл прежней версии, чтобы не было двух источников
rm -f /etc/security/limits.d/99-xanmod-limits.conf \
      /etc/systemd/system.conf.d/99-xanmod-limits.conf 2>/dev/null || true
systemd_present && systemctl daemon-reexec || true
success "Лимиты применены (действуют для служб после перезапуска)"

# ── 9. Сетевая карта ──────────────────────────────────────────────────────────
if [[ "${TUNE_NIC:-yes}" == "yes" ]] && have ethtool && ! is_container; then
    NIC="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    if [[ -n "${NIC}" ]]; then
        RING="$(ethtool -g "${NIC}" 2>/dev/null || true)"
        RX_MAX="$(awk '/^RX:/{print $2; exit}' <<< "${RING}")"
        TX_MAX="$(awk '/^TX:/{print $2; exit}' <<< "${RING}")"
        if [[ "${RX_MAX:-}" =~ ^[0-9]+$ && "${TX_MAX:-}" =~ ^[0-9]+$ ]]; then
            info "Интерфейс ${NIC}: ring buffers → rx=${RX_MAX}, tx=${TX_MAX}"
            ethtool -G "${NIC}" rx "${RX_MAX}" tx "${TX_MAX}" 2>/dev/null \
                || warn "Драйвер ${NIC} не принял размер очередей"
            # Значения сбрасываются при перезагрузке — закрепляем юнитом
            write_file "${NIC_UNIT}" 0644 <<EOF
[Unit]
Description=FastNodeDebian NIC tuning (${NIC})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ethtool -G ${NIC} rx ${RX_MAX} tx ${TX_MAX}
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
EOF
            systemd_present && systemctl daemon-reload >/dev/null 2>&1 || true
            systemd_present && systemctl enable fastnode-nic-tune.service >/dev/null 2>&1 || true
            success "Настройки интерфейса закреплены (fastnode-nic-tune.service)"
        else
            info "Драйвер ${NIC} не сообщает пределы ring buffers — пропускаем"
        fi
    fi
fi

# ── 10. Локальный кеширующий DNS ──────────────────────────────────────────────
# Принцип: системный резолвер НЕ переключается, пока кеш не доказал, что
# отвечает. Прежняя версия сначала переписывала /etc/resolv.conf и только потом
# проверяла результат — при неудаче узел оставался без DNS, а симлинк на
# systemd-resolved уничтожался безвозвратно.
DNS_FAILED=0
if [[ "${TUNE_DNS_CACHE:-no}" == "yes" ]]; then
    step "Локальный DNS-кеш (dnsmasq)"

    # ── Точный снимок исходного состояния ────────────────────────────────────
    RESOLV_WAS_LINK=0
    RESOLV_LINK_TARGET=""
    RESOLV_BACKUP=""
    if [[ -L /etc/resolv.conf ]]; then
        RESOLV_WAS_LINK=1
        RESOLV_LINK_TARGET="$(readlink /etc/resolv.conf || true)"
        info "/etc/resolv.conf — симлинк на ${RESOLV_LINK_TARGET}"
    elif [[ -f /etc/resolv.conf ]]; then
        RESOLV_BACKUP="$(backup_file /etc/resolv.conf)"
        info "Резервная копия резолвера: ${RESOLV_BACKUP}"
    fi

    restore_resolver() {
        rm -f /etc/resolv.conf
        if [[ ${RESOLV_WAS_LINK} -eq 1 && -n "${RESOLV_LINK_TARGET}" ]]; then
            ln -sfn "${RESOLV_LINK_TARGET}" /etc/resolv.conf
            info "Симлинк /etc/resolv.conf → ${RESOLV_LINK_TARGET} восстановлен"
        elif [[ -n "${RESOLV_BACKUP}" && -f "${RESOLV_BACKUP}" ]]; then
            cp -a "${RESOLV_BACKUP}" /etc/resolv.conf
            info "Файл /etc/resolv.conf восстановлен из ${RESOLV_BACKUP}"
        else
            # Исходного состояния не было — только тогда пишем что-то своё
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
            warn "Исходный резолвер неизвестен, записаны публичные серверы"
        fi
        if [[ "${RESOLVED_WAS:-0}" -eq 1 ]]; then
            systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
            info "systemd-resolved снова запущен"
        fi
    }

    # Опрос конкретного сервера, а не «как получится через nsswitch»
    # Возвращает: 0 — сервер ответил, 1 — не ответил, 2 — проверить нечем.
    # Вывод читается в переменную: конвейер «dig | grep -q» под pipefail
    # ложно падает по SIGPIPE, когда grep выходит по первому совпадению.
    probe_dns() {   # probe_dns <сервер>
        local srv="$1" name="deb.debian.org" out
        if have dig; then
            out="$(dig +short +time=2 +tries=2 "@${srv}" "${name}" A 2>/dev/null || true)"
            grep -qE '^[0-9]+\.' <<< "${out}"
        elif have nslookup; then
            out="$(nslookup -timeout=2 "${name}" "${srv}" 2>/dev/null || true)"
            grep -q 'Address' <<< "${out}"
        else
            return 2
        fi
    }

    apt_update >/dev/null || warn "apt-get update завершился с ошибкой"
    # dig нужен, чтобы опросить кеш напрямую, минуя /etc/resolv.conf
    apt_install bind9-dnsutils || warn "bind9-dnsutils не установлен — проверка будет менее точной"

    if ! apt_install dnsmasq; then
        error "dnsmasq не установился — DNS-кеш не настроен, система не тронута"
        DNS_FAILED=1
    else
        declare -a UPSTREAM=()
        if declare -p TUNE_DNS_UPSTREAM >/dev/null 2>&1 && (( ${#TUNE_DNS_UPSTREAM[@]} > 0 )); then
            UPSTREAM=("${TUNE_DNS_UPSTREAM[@]}")
        else
            UPSTREAM=(1.1.1.1 1.0.0.1 8.8.8.8)
        fi
        {
            printf '# FastNodeDebian — кеширующий резолвер (модуль 10)\n'
            printf 'listen-address=127.0.0.1\nbind-interfaces\nno-resolv\nno-hosts\n'
            printf 'cache-size=20000\nmin-cache-ttl=120\nneg-ttl=60\ndns-forward-max=2000\nall-servers\n'
            for u in "${UPSTREAM[@]}"; do printf 'server=%s\n' "${u}"; done
        } | write_file "${DNSMASQ_CONF}" 0644

        # dnsmasq слушает 127.0.0.1:53, systemd-resolved — 127.0.0.53:53.
        # Адреса разные, поэтому на этом этапе они сосуществуют и системный
        # резолвер продолжает работать как прежде.
        systemctl enable dnsmasq >/dev/null 2>&1 || true
        systemctl restart dnsmasq >/dev/null 2>&1 || true
        sleep 2

        # $? после «cmd && {...}» относится к списку, а не к cmd — берём код явно
        PROBE_RC=0
        for _ in 1 2 3; do
            probe_rc=0
            probe_dns 127.0.0.1 || probe_rc=$?
            (( probe_rc == 0 )) && { PROBE_RC=1; break; }
            (( probe_rc == 2 )) && { PROBE_RC=2; break; }
            sleep 2
        done

        if [[ ${PROBE_RC} -eq 1 ]]; then
            info "Кеш отвечает на 127.0.0.1 — переключаем системный резолвер"
            if unit_exists systemd-resolved.service && svc_active systemd-resolved; then
                systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
                RESOLVED_WAS=1
            else
                RESOLVED_WAS=0
            fi
            rm -f /etc/resolv.conf
            printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf
            chmod 644 /etc/resolv.conf

            # Контрольная проверка уже через системный резолвер
            if getent hosts deb.debian.org >/dev/null 2>&1; then
                success "DNS-кеш включён, резолвер переключён на 127.0.0.1"
                info "chattr +i намеренно не применяется: immutable мешает восстановлению DNS"
            else
                warn "После переключения резолвинг не работает — полный откат"
                restore_resolver
                systemctl disable --now dnsmasq >/dev/null 2>&1 || true
                rm -f "${DNSMASQ_CONF}"
                DNS_FAILED=1
            fi
        else
            if [[ ${PROBE_RC} -eq 2 ]]; then
                warn "Нет dig/nslookup — проверить кеш безопасно нельзя, не рискуем"
            else
                warn "Кеш не отвечает на 127.0.0.1 (проверьте доступность ${UPSTREAM[*]})"
            fi
            info "Системный резолвер НЕ изменялся — DNS продолжает работать как прежде"
            systemctl disable --now dnsmasq >/dev/null 2>&1 || true
            rm -f "${DNSMASQ_CONF}"
            DNS_FAILED=1
        fi
    fi
fi

# ── 11. zram ──────────────────────────────────────────────────────────────────
if [[ "${TUNE_ZRAM:-no}" == "yes" ]] && ! is_container; then
    apt_install zram-tools || true
    if [[ -f /etc/default/zramswap ]]; then
        sed -i 's/^#\?ALGO=.*/ALGO=zstd/; s/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
        systemctl restart zramswap >/dev/null 2>&1 || true
        success "zram-swap включён (zstd, 50% RAM)"
    fi
fi

# ── 12. Отключение лишних служб ───────────────────────────────────────────────
if [[ "${TUNE_TRIM_SERVICES:-no}" == "yes" ]] && systemd_present; then
    step "Отключение ненужных служб"
    for svc in multipathd ModemManager wpa_supplicant lxcfs; do
        if unit_exists "${svc}.service" && { svc_active "${svc}" || svc_enabled "${svc}"; }; then
            systemctl disable --now "${svc}" >/dev/null 2>&1 || true
            info "Отключено: ${svc}"
        fi
    done
    if pkg_installed snapd; then
        if confirm "Удалить snapd? На прокси-узле он не нужен и занимает память" no; then
            systemctl disable --now snapd.service snapd.socket >/dev/null 2>&1 || true
            apt-get purge -y "${APT_CONF_OPTS[@]}" snapd >/dev/null 2>&1 || true
            success "snapd удалён"
        fi
    fi
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
echo
success "Тюнинг применён"
printf '   Профиль:      %s (роль %s)\n' "${PROFILE}" "${ROLE}"
printf '   CC / qdisc:   %s / %s\n' "${CC}" "${QDISC}"
printf '   Буферы:       %s байт\n' "${MEMMAX}"
printf '   nofile:       %s\n' "${NOFILE}"
(( CT_MAX > 0 )) && printf '   conntrack:    %s\n' "${CT_MAX}"
printf '   ip_forward:   %s\n' "${FORWARD}"
echo
info "Проверка:  sysctl net.ipv4.tcp_congestion_control net.core.rmem_max"
info "Лимиты вступят в силу для служб после перезапуска или перезагрузки."

if (( DNS_FAILED )); then
    echo
    error "DNS-кеш включить не удалось — остальной тюнинг применён."
    info  "Резолвер остался в прежнем состоянии. Отключите TUNE_DNS_CACHE или"
    info  "проверьте доступность upstream-серверов, затем запустите модуль снова."
    exit 1
fi
exit 0
