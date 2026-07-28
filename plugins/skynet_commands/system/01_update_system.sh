#!/bin/bash
# TITLE: Обновить систему (full-upgrade + чистка)
# SKYNET_HIDDEN: false
#
# Плагин для Скайнета: обновляет пакеты и сразу подчищает за собой.
# Порядок тот же, что и в локальном «Обновить систему»
# (modules/local/local_care.sh -> _run_system_update):
#   apt update -> full-upgrade -> autoremove -> autoclean.
#
# full-upgrade, а не upgrade: обычный upgrade не ставит обновления, которым
# нужно доустановить или снести зависимость, и на нодах копятся пакеты
# в статусе "not upgraded" — в том числе security-обновления.
#

# --- Стандартные хелперы для плагинов Skynet ---
set -e # Прерывать выполнение при любой ошибке
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
info() { echo -e "${C_RESET}[i] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
err()  { echo -e "${C_RED}[✗] $*${C_RESET}"; exit 1; }
# --- Конец хелперов ---

# Плагин уезжает сразу на весь флот и работает без TTY: любой интерактивный
# вопрос dpkg (например, «твой конфиг или из пакета?») повесил бы обновление
# намертво до таймаута. Поэтому noninteractive и явное «оставить свой конфиг».
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# Итоговую строку apt («N upgraded, M newly installed...») разбираем ниже,
# поэтому принудительно английская локаль — на серверах она бывает любой.
export LC_ALL=C

# Убедимся, что скрипт выполняется от имени root
if [[ $EUID -ne 0 ]]; then
    err "Этот плагин должен выполняться от имени root."
fi

# Проверяем, что это Debian-based система
if ! command -v apt-get &>/dev/null; then
    warn "Это не Debian/Ubuntu, пропускаю."
    exit 0
fi

# Достаёт число из итоговой строки apt: _apt_count "$log" "upgraded" -> N
# '|| true' обязателен: при set -e пустой grep уронил бы весь плагин на
# ровном месте (например, когда обновлять просто нечего).
_apt_count() {
    local log="$1" what="$2" value
    value=$(printf '%s\n' "$log" \
        | grep -E '[0-9]+ upgraded' \
        | tail -n1 \
        | grep -Eo "[0-9]+ ${what}" \
        | grep -Eo '^[0-9]+' || true)
    printf '%s' "${value:-?}"
}

_disk_free_kb() {
    df -Pk / | awk 'NR==2 {print $4}'
}

free_before=$(_disk_free_kb)

info "Обновляю списки пакетов (apt update)..."
if ! apt-get update -qq; then
    err "apt update не прошёл: репозитории недоступны или релиз снят с поддержки (EOL)."
fi

info "Ставлю обновления (full-upgrade)..."
upgrade_log=$(apt-get full-upgrade "${APT_OPTS[@]}" 2>&1) || {
    printf '%s\n' "$upgrade_log" | tail -n 15
    err "Обновление пакетов сорвалось."
}
ok "Обновлено пакетов: $(_apt_count "$upgrade_log" "upgraded")"

# Чистка. Если она отвалится - это не повод считать обновление неудачным,
# поэтому здесь warn, а не err.
info "Сношу осиротевшие пакеты (autoremove)..."
if remove_log=$(apt-get autoremove "${APT_OPTS[@]}" 2>&1); then
    ok "Снесено лишних пакетов: $(_apt_count "$remove_log" "to remove")"
else
    warn "autoremove отработал с ошибкой, иду дальше."
fi

info "Чищу кэш скачанных пакетов (autoclean)..."
if ! apt-get autoclean -y >/dev/null 2>&1; then
    warn "autoclean отработал с ошибкой, иду дальше."
fi

free_after=$(_disk_free_kb)
freed_mb=$(( (free_after - free_before) / 1024 ))
if (( freed_mb > 0 )); then
    ok "Освобождено на диске: ${freed_mb} МБ"
else
    # Обновление само по себе занимает место - это норма, а не ошибка.
    info "Место на диске: ${freed_mb} МБ (обновления заняли больше, чем чистка освободила)"
fi

# Ядро и libc докатываются только после ребута - на флоте это надо видеть
# сразу в общем списке, иначе сервер останется на старом ядре.
if [[ -f /var/run/reboot-required ]]; then
    warn "ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА (обновилось ядро или системные библиотеки)."
fi

ok "Обновление и чистка завершены."
exit 0
