#!/bin/bash
# ==============================================================================
# FastNodeDebian — run.sh
# One-liner: curl -fsSL https://raw.githubusercontent.com/begugla0/FastNodeDebian/main/run.sh | bash
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="https://github.com/begugla0/FastNodeDebian.git"
INSTALL_DIR="/opt/FastNodeDebian"

echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║   ⚡ FastNodeDebian — Быстрый запуск             ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка root
if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED} ✗ Запустите от root: sudo bash${NC}"
    exit 1
fi

# Проверка Debian
if ! grep -qi "debian" /etc/os-release 2>/dev/null && [[ ! -r /etc/debian_version ]]; then
    echo -e "${YELLOW} ⚠ Обнаружен не Debian — скрипт может работать некорректно${NC}"
fi

# Устанавливаем git если нет
if ! command -v git &>/dev/null; then
    echo -e "${CYAN} ℹ Установка git...${NC}"
    apt-get update -qq
    apt-get install -y -qq git
fi

# Удаляем старую копию если есть
if [[ -d "${INSTALL_DIR}" ]]; then
    echo -e "${YELLOW} ⚠ Обновляем существующую копию...${NC}"
    rm -rf "${INSTALL_DIR}"
fi

# Клонируем репозиторий
echo -e "${CYAN} ℹ Клонирование репозитория...${NC}"
git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"

cd "${INSTALL_DIR}"

# Экспортируем SCRIPT_DIR чтобы main.sh знал своё расположение
export SCRIPT_DIR="${INSTALL_DIR}"

echo -e "${GREEN} ✓ Репозиторий загружен: ${INSTALL_DIR}${NC}"
echo ""

# Запускаем main.sh
exec bash "${INSTALL_DIR}/main.sh" "$@"
