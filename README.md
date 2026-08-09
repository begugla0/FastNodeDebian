# ⚡ FastNodeDebian

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Debian](https://img.shields.io/badge/Debian-13%20trixie-A81D33?logo=debian&logoColor=white)](https://www.debian.org)
[![Bash](https://img.shields.io/badge/Bash-5.2-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

Модульная настройка и hardening сервера **Debian 13 (trixie)**.

Целевая платформа — только Debian 13. Debian 9/10/11/12 поддерживаются
единственным модулем `00`, который доводит систему до 13. Остальные модули на
старых релизах не запускаются и сообщают об этом (код выхода `90`).

---

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/begugla0/FastNodeDebian/main/run.sh | sudo bash
```

Или вручную:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/begugla0/FastNodeDebian.git
cd FastNodeDebian
sudo bash main.sh
```

### Уже на Debian 13

```bash
sudo bash main.sh                       # интерактивное меню
sudo bash main.sh --all                 # модули 1–8 подряд
sudo bash main.sh --all --yes           # без единого вопроса
sudo bash main.sh --module 5            # только SSH hardening
sudo bash main.sh --status              # состояние узла
```

### Debian 9–12

```bash
sudo bash main.sh --upgrade                          # один шаг, затем перезагрузка
sudo bash modules/00-system-update.sh --auto         # вся цепочка до 13 автоматически
sudo bash modules/00-system-update.sh --auto --yes   # то же без подтверждений
sudo bash modules/00-system-update.sh --status       # где мы сейчас и куда идём
```

> **Сделайте снапшот перед обновлением дистрибутива.** Операция необратима.

---

## Модули

| #      | Модуль                 | Что делает                                                        |
| ------ | ---------------------- | ----------------------------------------------------------------- |
| **00** | `00-system-update.sh`  | Поэтапное обновление 9→10→11→12→13 с перезагрузками                |
| **1**  | `01-packet-update.sh`  | Обновление пакетов, базовый набор утилит                           |
| **2**  | `02-locale-setup.sh`   | Локаль `ru_RU.UTF-8` (+ `en_US.UTF-8`)                             |
| **3**  | `03-time-sync.sh`      | Часовой пояс и `chrony`                                            |
| **4**  | `04-ssh-key.sh`        | Установка публичного SSH-ключа                                     |
| **5**  | `05-ssh-hardening.sh`  | Порт, key-only вход, современная криптография, авто-откат          |
| **6**  | `06-swap-setup.sh`     | SWAP-файл и параметры `vm.*`                                       |
| **7**  | `07-ufw-setup.sh`      | UFW: rate-limit SSH, политика форвардинга по роли узла             |
| **8**  | `08-fail2ban-setup.sh` | Fail2Ban: jail sshd + бан за сканирование портов                   |
| **9**  | `09-xanmod-v3.sh`      | Ядро XanMod + BBRv3 **[перезагрузка]**                             |
| **10** | `10-node-tuning.sh`    | Тюнинг ядра под прокси/VPN: буферы, conntrack, лимиты, NIC         |

Рекомендуемый порядок: `4 → 5 → 7 → 8 → 10`. Ключ должен появиться **до**
hardening, иначе модуль 5 намеренно оставит вход по паролю. `--all` выполняет
1–8 и 10; модуль 9 предлагается отдельно, так как требует перезагрузки.

### Владение параметрами ядра

Каждый ключ sysctl задаёт ровно один модуль — иначе применяется последний файл
по алфавиту, и результат непредсказуем:

| Файл | Владелец | Что задаёт |
| --- | --- | --- |
| `/etc/sysctl.d/99-fastnode-vm.conf`  | модуль 06 | `vm.*` |
| `/etc/sysctl.d/99-fastnode-net.conf` | модуль 10 | `net.*`, `fs.*` |

Модуль 9 ставит только ядро и ничего не пишет в sysctl.

---

## Конфигурация

Все параметры — в `config/settings.conf`. Свои значения кладите в
`config/settings.local.conf`: он не перезаписывается при обновлении репозитория
и игнорируется git.

Приоритет: **переменные окружения → `settings.local.conf` → `settings.conf`**.

```bash
SSH_PORT=2222 sudo -E bash main.sh --module 5    # разовое переопределение
```

### Ключевые параметры

```bash
NODE_ROLE="vpn"              # vpn — ip_forward=1 и UFW пропускает транзит
                             # plain — обычный сервер, форвардинг запрещён

SSH_PORT="2225"
SSH_PERMIT_ROOT="prohibit-password"
SSH_PASSWORD_AUTH="auto"     # auto — отключить пароль ТОЛЬКО при наличии ключа
                             # no   — отключить принудительно (нужен ключ)
                             # yes  — оставить вход по паролю
SSH_CONFIRM_TIMEOUT="180"    # секунд до авто-отката, если вход не подтверждён

SWAP_SIZE="2G"
TIMEZONE="Europe/Moscow"
LOCALE_LANG="ru_RU.UTF-8"
XANMOD_BRANCH="main"         # main | lts | edge | rt
```

---

## Открытые порты (модуль 07)

По умолчанию открывается **только SSH** — порт из конфига плюс все порты, на
которых реально слушает `sshd`, плюс порт текущего подключения.

Остальные порты модуль спрашивает интерактивно, по одному. **Два пустых
Enter подряд завершают ввод** (первый выводит подсказку). Принимаются форматы
`80`, `443/tcp`, `60000:61000/udp`; некорректный ввод, дубликаты и повтор
SSH-порта отсеиваются.

Чтобы обойтись без вопросов, задайте порты заранее:

```bash
ALLOWED_PORTS=("443/tcp" "443/udp" "60000:61000/udp")
UFW_ASK_PORTS="no"
```

---

## Тюнинг узла (модуль 10)

Рассчитан на Xray (VLESS/XHTTP/Reality), Hysteria2/QUIC и WARP. Значения
масштабируются от объёма RAM: буферы сокетов, очереди, бэклоги, conntrack,
лимиты дескрипторов, ring buffers сетевой карты.

```bash
TUNE_PROFILE="auto"        # auto | proxy | plain (auto = proxy при NODE_ROLE=vpn)
TUNE_RP_FILTER="loose"     # strict | loose | off
TUNE_PORT_RANGE="10000 65500"
TUNE_CONNTRACK="auto"
TUNE_NIC="yes"
TUNE_DNS_CACHE="no"        # локальный dnsmasq — включайте осознанно
TUNE_TRIM_SERVICES="no"    # отключить snapd / ModemManager / multipathd
```

Три решения, отличающиеся от типовых «тюнинг-скриптов», и причины:

- **`tcp_mem` и `udp_mem` не задаются.** Ядро вычисляет их от объёма памяти при
  загрузке. Ходовые константы (3 ГБ / 4 ГБ / 102 ГБ в страницах) на VPS с 1–2 ГБ
  снимают защиту от исчерпания памяти: вместо отбрасывания пакетов приходит OOM.
- **`rp_filter=2` (loose), а не `0`.** Асимметричная маршрутизация WARP требует
  ослабить проверку, но полное отключение снимает и защиту от подмены адреса.
  Loose решает задачу без этого. Полное отключение доступно через `off`.
- **`chattr +i /etc/resolv.conf` не применяется.** Immutable-флаг ломает
  восстановление DNS и сбивает с толку при диагностике. Вместо этого модуль
  проверяет, что кеш отвечает, **до** переключения резолвера, и откатывается
  автоматически, если DNS не поднялся.

**Потолки дескрипторов только поднимаются.** `TUNE_NOFILE` по умолчанию
`1048576`; модуль читает текущие `fs.nr_open` и `fs.file-max` и берёт максимум,
поэтому штатный потолок ядра никогда не опускается. Если хост отдаёт меньше,
чем запрошенный лимит, модуль поднимает `fs.nr_open` сразу через `sysctl -w` —
иначе systemd отвергнет `DefaultLimitNOFILE` и службы не поднимутся до
перезагрузки. Значение пишется в `/etc/sysctl.d/99-fastnode-net.conf`, а не
дописывается в `/etc/sysctl.conf`: при повторных запусках `>>` накапливает
дубликаты и создаёт второго владельца ключа.

Размер таблицы conntrack — 128 записей на МБ RAM (не 256): при 350 байтах на
запись более агрессивный вариант съедал бы около 9% памяти на VPS с 1 ГБ.

> Порты ваших сервисов, включая диапазон port-hopping для Hysteria2, должны
> находиться **вне** `TUNE_PORT_RANGE`, иначе ядро займёт их под исходящие
> соединения.

---

## Защита от потери доступа

Модуль 5 построен так, чтобы отрезать себя от сервера было трудно:

- при `SSH_PASSWORD_AUTH=auto` пароль отключается **только** если найден
  непустой `authorized_keys`; иначе он остаётся включённым;
- при `SSH_PASSWORD_AUTH=no` без ключей модуль **отказывается работать**
  (осознанный обход — `SSH_FORCE_NO_PASSWORD=1`);
- добавляется `KbdInteractiveAuthentication no` — без неё PAM пускает по паролю
  вопреки `PasswordAuthentication no`;
- порт открывается в UFW **до** перезапуска sshd;
- проверяется, что sshd действительно слушает новый порт (`ss`);
- если вход на новый порт не подтверждён за `SSH_CONFIRM_TIMEOUT` секунд —
  конфигурация откатывается автоматически;
- список алгоритмов фильтруется через `ssh -Q`, поэтому `sshd -t` не падает на
  другой версии OpenSSH.

Модуль 7 открывает **все** порты, на которых реально слушает sshd, плюс порт
текущего SSH-подключения — а не только `SSH_PORT` из конфига.

---

## Проверка после установки

```bash
fastnode-verify        # появляется после модуля 9
sudo bash main.sh --status
```

Отдельно:

```bash
sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin)'
sudo ufw status verbose
sudo fail2ban-client status sshd
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

---

## Откат

```bash
# SSH: резервные копии рядом с конфигом
ls /etc/ssh/sshd_config.fastnode.*.bak
sudo rm /etc/ssh/sshd_config.d/99-zz-fastnode-hardening.conf && sudo systemctl restart ssh

# UFW
sudo ufw --force reset && sudo ufw disable

# Обновление дистрибутива
sudo bash modules/00-system-update.sh --abort           # снять авто-режим
sudo bash modules/00-system-update.sh --restore-repos   # вернуть сторонние репозитории
```

---

## Структура

```
FastNodeDebian/
├── main.sh                      меню и CLI
├── run.sh                       one-liner установки
├── lib/
│   └── common.sh                логирование, диалоги, apt/ssh/systemd-хелперы
├── config/
│   ├── settings.conf            параметры по умолчанию
│   └── settings.local.conf      ваши переопределения (создайте сами)
├── modules/00…10
├── tests/
│   └── lint.sh                  статическая проверка репозитория
└── logs/
```

Каждый модуль подключает `lib/common.sh` самостоятельно через `source` и
работает под `set -Eeuo pipefail` с трассировкой ошибок. Модули не полагаются
на функции, экспортированные из `main.sh`, — это принципиально: при
наследовании через `export -f` функция `error()` переставала завершать
выполнение, и модуль продолжал работу после фатальной ошибки.

---

## Разработка

```bash
bash tests/lint.sh
```

Линтер ловит классы ошибок, которые уже ломали этот проект: невалидные
подстановки `${#ARR[@]:-N}`, конвейеры `cmd | grep -q` (ложное падение по
SIGPIPE под `pipefail`), последнюю строку модуля с ненулевым кодом возврата,
пропущенный `require_debian_13`. Запускайте после любой правки.

---

## Совместимость

- **XanMod** публикуется для `amd64`; suite репозитория — кодовое имя
  дистрибутива. Для trixie доступна основная ветка, пакетов уровня `v4` нет,
  поэтому определение psABI ограничено `v3`. Нужен выключенный Secure Boot; в
  контейнерах (LXC/OpenVZ/Docker) замена ядра невозможна.
- **Fail2Ban** на Debian 13 читает журнал systemd: `rsyslog` и
  `/var/log/auth.log` по умолчанию отсутствуют. Модуль ставит
  `python3-systemd`, без которого `backend = systemd` не работает и служба не
  стартует вовсе.
- Если UFW уже активен, модуль 7 в неинтерактивном режиме **ничего не меняет**
  и завершается успешно — чтобы не снести правила молча. Для перезаписи
  используйте `--yes`.

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
