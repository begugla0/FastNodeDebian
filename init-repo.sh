#!/bin/bash
# ==============================================================================
# init-repo.sh — подготовка локального git-репозитория FastNodeDebian к публикации
#
# Использование:
#   1) Создайте ПУСТОЙ репозиторий на GitHub: https://github.com/new
#      Имя: FastNodeDebian  (без README/LICENSE/.gitignore)
#   2) Запустите этот скрипт из каталога проекта:
#        bash init-repo.sh                       # по умолчанию begugla0
#        bash init-repo.sh <ваш-github-логин>    # если логин другой
#   3) Выполните показанные команды git push (потребуется ваш доступ к GitHub).
#
# Скрипт НЕ публикует за вас — он только готовит коммит и печатает команды,
# т.к. для пуша нужны ваши учётные данные GitHub.
# ==============================================================================

set -euo pipefail

USER_LOGIN="${1:-begugla0}"
REPO_NAME="FastNodeDebian"

if ! command -v git >/dev/null 2>&1; then
    echo "Устанавливаю git..."; sudo apt-get update -qq && sudo apt-get install -y -qq git
fi

# Удобные настройки прав
chmod +x run.sh main.sh modules/*.sh 2>/dev/null || true

if [[ ! -d .git ]]; then
    git init -q
    git branch -M main
fi

git add -A
git commit -q -m "FastNodeDebian: Debian 9-13 server automation + staged dist-upgrade" || echo "Нечего коммитить."

echo ""
echo "Готово. Теперь опубликуйте под своим именем:"
echo ""
echo "  git remote add origin https://github.com/${USER_LOGIN}/${REPO_NAME}.git"
echo "  git push -u origin main"
echo ""
echo "Если remote уже существует:"
echo "  git remote set-url origin https://github.com/${USER_LOGIN}/${REPO_NAME}.git"
echo "  git push -u origin main"
echo ""
echo "После публикации one-liner будет работать так:"
echo "  curl -fsSL https://raw.githubusercontent.com/${USER_LOGIN}/${REPO_NAME}/main/run.sh | bash"
