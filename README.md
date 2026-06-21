# ⚡ FastNodeDebian

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Debian](https://img.shields.io/badge/Debian-9%20%7C%2010%20%7C%2011%20%7C%2012%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org)
[![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

> Модульный bash-скрипт для быстрой настройки, обновления и hardening сервера **Debian 9 / 10 / 11 / 12 / 13**.
>
> Порт проекта [FastNodeUbuntu](https://github.com/begugla0/FastNodeUbuntu) на Debian + новый модуль поэтапного обновления дистрибутива.

---

## 🚀 Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/begugla0/FastNodeDebian/main/run.sh | bash
```

Или через git:

```bash
apt update && apt install -y git
git clone https://github.com/begugla0/FastNodeDebian.git
cd FastNodeDebian
bash main.sh
```

---

## 📦 Модули

| #      | Модуль                  | Описание                                                                   |
| ------ | ----------------------- | -------------------------------------------------------------------------- |
| **00** | `00-system-update.sh`   | **Поэтапное обновление Debian 9→10→11→12→13** (с перезагрузками)            |
| **1**  | `01-packet-update.sh`   | Обновление пакетов в пределах текущего релиза                              |
| **2**  | `02-locale-setup.sh`    | Настройка локали `ru_RU.UTF-8`                                             |
| **3**  | `03-time-sync.sh`       | Часовой пояс `Europe/Moscow`, `chrony` вместо `systemd-timesyncd`          |
| **4**  | `04-ssh-key.sh`         | Интерактивное добавление SSH публичного ключа                              |
| **5**  | `05-ssh-hardening.sh`   | Hardening SSH: порт `2225`, drop-in конфиг, авто-отключение пароля по ключу |
| **6**  | `06-swap-setup.sh`      | SWAP (1/2/3/4 GB), `swappiness`, поддержка btrfs                           |
| **7**  | `07-ufw-setup.sh`       | UFW firewall + rate-limit для SSH                                          |
| **8**  | `08-fail2ban-setup.sh`  | Fail2Ban (SSH + детект порт-сканирования)                                  |
| **9**  | `09-xanmod-v3.sh`       | Ядро XanMod + BBRv3 *(только Debian 12/13)* **[reboot]**                   |

---

## 🔄 Модуль 00 — поэтапное обновление дистрибутива

Самая важная новинка. Обновляет Debian по цепочке `9 → 10 → 11 → 12 → 13`, **по одной мажорной версии за шаг, с перезагрузкой после каждого**.

Скрипт сам:

- определяет текущую версию и следующий шаг;
- корректно переписывает `/etc/apt/sources.list`:
  - `stretch` (9) и `buster` (10) — EOL → `archive.debian.org` (с отключением проверки срока действия `Release`);
  - `bullseye` (11) — живое зеркало, с авто-фолбэком на архив;
  - `bookworm` (12) / `trixie` (13) — `deb.debian.org` + `security.debian.org`;
  - формат security-suite: `≤10` → `<codename>/updates`, `≥11` → `<codename>-security`;
  - компонент `non-free-firmware` добавляется начиная с Debian 12;
- временно отключает сторонние репозитории (частая причина сбоев апгрейда);
- делает `apt full-upgrade` с безопасными `--force-confold/--force-confdef`;
- перезагружает сервер.

### Режимы запуска

```bash
# Ручной режим: один шаг (например 11→12), затем запрос на перезагрузку.
# После ребута запускаете снова — продолжится со следующего шага.
bash modules/00-system-update.sh

# Автоматический режим: весь путь до Debian 13 без участия человека.
# Между шагами сервер сам перезагружается, эстафету подхватывает systemd.
bash modules/00-system-update.sh --auto

# Авто-режим до конкретной версии (например, остановиться на 12):
bash modules/00-system-update.sh --auto --target 12

# Без подтверждений (для автоматизации):
bash modules/00-system-update.sh --auto --yes

# Показать текущее состояние / цель:
bash modules/00-system-update.sh --status
```

> ⚠️ **Перед запуском обязательно сделайте снапшот/бэкап** — апгрейд дистрибутива необратим.
> В авто-режиме устанавливается systemd-юнит `fastnode-upgrade.service`, который после
> достижения целевой версии автоматически отключается и удаляется. Лог: `/var/log/fastnode-upgrade.log`.

### Как работает авто-продолжение

```
запуск --auto ─▶ шаг 9→10 ─▶ reboot ─┐
                                      ▼
            systemd ─▶ --resume ─▶ шаг 10→11 ─▶ reboot ─┐
                                                        ▼
                        systemd ─▶ --resume ─▶ … ─▶ Debian 13 ─▶ очистка
```

---

## ⚙️ Конфигурация

Все параметры — в `config/settings.conf`:

```bash
UPGRADE_TARGET="13"       # до какой версии Debian обновляться (модуль 00)

SSH_PORT="2225"
SSH_PERMIT_ROOT="yes"
SSH_PUBLIC_KEY=""         # пусто — ключ запросится интерактивно

SWAP_SIZE="2G"
SWAP_SWAPPINESS="10"

TIMEZONE="Europe/Moscow"
LOCALE_LANG="ru_RU.UTF-8"
```

---

## 🤖 Автоматический режим (без меню)

Запуск всех модулей настройки (1–8) без меню:

```bash
INTERACTIVE_MODE=false bash main.sh
```

> Модули `00` (обновление дистрибутива) и `09` (XanMod) **не** запускаются в режиме «всё подряд»,
> так как требуют перезагрузки — их запускают отдельно.

---

## 🗂️ Структура проекта

```
FastNodeDebian/
├── main.sh                      # главное меню
├── run.sh                       # one-liner запуск
├── config/
│   └── settings.conf            # все параметры
├── modules/
│   ├── 00-system-update.sh      # поэтапный апгрейд 9→13  ← НОВОЕ
│   ├── 01-packet-update.sh
│   ├── 02-locale-setup.sh
│   ├── 03-time-sync.sh
│   ├── 04-ssh-key.sh
│   ├── 05-ssh-hardening.sh
│   ├── 06-swap-setup.sh
│   ├── 07-ufw-setup.sh
│   ├── 08-fail2ban-setup.sh
│   └── 09-xanmod-v3.sh
└── logs/                        # логи запусков
```

---

## 🛡️ Что делает hardening SSH

- Меняет порт с `22` на `2225`
- На Debian 9/10 добавляет `Include /etc/ssh/sshd_config.d/*.conf` (там его нет «из коробки»)
- На Debian 13 отключает `ssh.socket` (socket activation), мешающий смене порта
- Отключает вход по паролю при наличии SSH-ключа (и **не** блокирует пароль, если ключа нет)
- Использует drop-in `99-zz-hardening.conf`
- Проверяет конфиг через `sshd -t`, при ошибке откатывается
- Просит подтверждение перед закрытием сессии, откат при отказе

---

## ❗ Заметки по совместимости

- **XanMod (модуль 09)** официально поддерживает только **Debian 12 (bookworm, LTS-метапакеты)** и
  **Debian 13 (trixie, MAIN-метапакеты)**. На Debian ≤ 11 репозиторий XanMod не отдаёт `Release` —
  модуль сообщит об этом и предложит сначала обновиться через модуль 00. Требуется отключённый Secure Boot.
- Все модули требуют **root** и наличие **systemd** (для авто-режима модуля 00).

---

## 📝 Лицензия

MIT — см. [LICENSE](LICENSE).
