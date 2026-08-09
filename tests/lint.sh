#!/usr/bin/env bash
# ==============================================================================
# tests/lint.sh — статическая проверка репозитория FastNodeDebian
#
#   bash tests/lint.sh
#
# Ловит ровно те классы ошибок, которые уже приводили к поломкам в этом проекте.
# Запускать после любой правки скриптов. Внешних зависимостей нет; если в системе
# есть shellcheck, дополнительно запускается и он.
# ==============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; N=''
fi

PASS=0; FAIL=0; WARN=0
ok()   { printf '  %s✓%s %s\n' "${G}" "${N}" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✗%s %s\n' "${R}" "${N}" "$*"; FAIL=$((FAIL+1)); }
note() { printf '  %s!%s %s\n' "${Y}" "${N}" "$*"; WARN=$((WARN+1)); }
sect() { printf '\n%s── %s%s\n' "${B}" "$*" "${N}"; }

mapfile -t SCRIPTS < <(find . -name '*.sh' -not -path './.git/*' | sort)

# Поиск по коду: без файла самого линтера и без строк-комментариев,
# иначе линтер находит собственные шаблоны и пояснения в комментариях.
scan() {
    grep -rn "$1" --include='*.sh' . 2>/dev/null \
        | grep -v '^\./tests/lint\.sh:' \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
SCRIPTS+=("./config/settings.conf")

# ── 1. Синтаксис ──────────────────────────────────────────────────────────────
sect "Синтаксис"
for f in "${SCRIPTS[@]}"; do
    if bash -n "${f}" 2>/dev/null; then
        ok "${f}"
    else
        bad "${f}"
        bash -n "${f}" 2>&1 | sed 's/^/      /'
    fi
done

# ── 2. Невалидная подстановка длины массива ───────────────────────────────────
# ${#ARR[@]:-0} — это «bad substitution», падает ВСЕГДА, даже на заполненном
# массиве. Правильно: declare -p ARR >/dev/null 2>&1 && (( ${#ARR[@]} > 0 ))
sect 'Подстановки вида ${#ARR[@]:-N}'
HITS="$(scan '\${#[A-Za-z_][A-Za-z0-9_]*\[@\]:-')"
if [[ -n "${HITS}" ]]; then
    bad "найдены невалидные подстановки:"
    sed 's/^/      /' <<< "${HITS}"
else
    ok "не найдено"
fi

# ── 3. SIGPIPE под pipefail ───────────────────────────────────────────────────
# «cmd | grep -q ...» ложно возвращает ошибку: grep выходит по первому
# совпадению, cmd получает SIGPIPE (141), pipefail отдаёт код наружу.
# Использовать out_matches / out_matches_i из lib/common.sh.
sect 'Конвейеры «cmd | grep -q» (SIGPIPE + pipefail)'
HITS="$(scan '| *grep -q')"
if [[ -n "${HITS}" ]]; then
    bad "конвейер может ложно упасть по SIGPIPE:"
    sed 's/^/      /' <<< "${HITS}"
else
    ok "не найдено"
fi

# ── 4. Незащищённые конвейеры с head ──────────────────────────────────────────
sect 'Конвейеры с head без «|| true»'
HITS="$(scan '| *head ' | grep -v '|| true' | grep -v '|| echo' || true)"
if [[ -n "${HITS}" ]]; then
    note "проверьте, не сработает ли set -e по SIGPIPE:"
    sed 's/^/      /' <<< "${HITS}"
else
    ok "не найдено"
fi

# ── 5. Последняя команда модуля возвращает ненулевой код ──────────────────────
# «[[ cond ]] && cmd» последней строкой делает exit 1, если условие ложно, —
# модуль отчитается об ошибке, ничего при этом не сломав.
sect 'Последняя значимая строка модулей'
for f in modules/*.sh main.sh; do
    LAST="$(grep -vE '^[[:space:]]*(#|$)' "${f}" | tail -1)"
    if [[ "${LAST}" =~ ^\[\[.*\]\][[:space:]]*\&\& ]] && [[ "${LAST}" != *"|| true"* ]]; then
        bad "${f}: последняя строка вернёт 1 при ложном условии: ${LAST}"
    else
        ok "${f}"
    fi
done

# ── 6. Модули обязаны подключать библиотеку сами ──────────────────────────────
# Наследование функций через export -f ломало die()/error(): они переставали
# завершать выполнение, и модуль продолжал работу после фатальной ошибки.
sect "Подключение lib/common.sh и строгий режим"
for f in modules/*.sh; do
    PROBLEMS=()
    grep -q 'source .*lib/common\.sh' "${f}" || PROBLEMS+=("нет source lib/common.sh")
    grep -q 'set -Eeuo pipefail'       "${f}" || PROBLEMS+=("нет set -Eeuo pipefail")
    grep -q 'trap_setup'               "${f}" || PROBLEMS+=("нет trap_setup")
    grep -q 'require_root'             "${f}" || PROBLEMS+=("нет require_root")
    if [[ ${#PROBLEMS[@]} -eq 0 ]]; then
        ok "${f}"
    else
        bad "${f}: ${PROBLEMS[*]}"
    fi
done

# ── 6b. Вызовы несуществующих функций ─────────────────────────────────────────
# Библиотека определяет info/warn/error/success/die/step/debug. Вызов «ok "…"»
# или другой отсутствующей функции проходит bash -n и падает уже в проде
# с кодом 127 — ровно посреди работы модуля.
sect "Вызовы функций, которых нет в lib/common.sh"
LIBFN="$(grep -oE '^[a-z_]+\(\)' lib/common.sh | tr -d '()' | sort -u)"
BUILTIN="if then else elif fi for do done case esac while until return exit local declare printf echo read source true false set trap shift export unset"
MISSING=0
for f in modules/*.sh main.sh; do
    SELF="$(grep -oE '^[a-z_]+\(\)' "${f}" | tr -d '()' | sort -u)"
    for fn in $(grep -oE '^[[:space:]]{0,8}[a-z_]{2,}[[:space:]]+"' "${f}" \
                | sed -E 's/^[[:space:]]*//; s/[[:space:]]+"$//' | sort -u); do
        grep -qw -- "${fn}" <<< "${LIBFN}"   && continue
        grep -qw -- "${fn}" <<< "${BUILTIN}" && continue
        grep -qw -- "${fn}" <<< "${SELF}"    && continue
        command -v "${fn}" >/dev/null 2>&1   && continue
        bad "${f}: вызывается несуществующая функция «${fn}»"
        MISSING=1
    done
done
[[ ${MISSING} -eq 0 ]] && ok "все вызовы разрешаются"

# ── 7. Гейт версии ────────────────────────────────────────────────────────────
sect "Гейт Debian 13 в модулях настройки"
for f in modules/0[1-9]-*.sh modules/1[0-9]-*.sh; do
    if grep -q 'require_debian_13' "${f}"; then
        ok "$(basename "${f}")"
    else
        bad "$(basename "${f}"): отсутствует require_debian_13"
    fi
done
if grep -q 'require_debian_13' modules/00-*.sh; then
    bad "модуль 00 не должен требовать Debian 13 — он и обновляет до неё"
else
    ok "модуль 00 работает на Debian 9–12"
fi

# ── 8. Опасные конструкции ────────────────────────────────────────────────────
sect "Опасные конструкции"
HITS="$(scan 'rm -rf /\($\|[^a-zA-Z]\)')"
[[ -n "${HITS}" ]] && { bad "подозрительный rm -rf:"; sed 's/^/      /' <<< "${HITS}"; } || ok "нет rm -rf по корню"

HITS="$(scan 'PasswordAuthentication no' | grep -v 'PASS_LINE' || true)"
[[ -n "${HITS}" ]] && note "жёстко зашитый PasswordAuthentication no — проверьте защиту от локаута:" \
    && sed 's/^/      /' <<< "${HITS}" || ok "PasswordAuthentication задаётся динамически"

# ── 9. shellcheck, если установлен ────────────────────────────────────────────
sect "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    SC=0
    for f in "${SCRIPTS[@]}"; do
        shellcheck -S warning -e SC1090,SC1091 "${f}" || SC=1
    done
    [[ ${SC} -eq 0 ]] && ok "замечаний уровня warning нет" || note "shellcheck выдал замечания (см. выше)"
else
    note "shellcheck не установлен — пропускаем (apt-get install shellcheck)"
fi

printf '\n%sИтог:%s пройдено %s, провалено %s, предупреждений %s\n\n' \
    "${B}" "${N}" "${PASS}" "${FAIL}" "${WARN}"
[[ ${FAIL} -eq 0 ]]
