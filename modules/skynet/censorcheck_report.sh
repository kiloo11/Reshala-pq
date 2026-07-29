#!/bin/bash
# ============================================================ #
# ==   SKYNET: ЕЖЕДНЕВНЫЙ ОТЧЁТ "БЛОКИРОВКА ТСПУ" В TELEGRAM == #
# ============================================================ #
#
# Ежедневно проверяет доступность IP каждого сервера флота из сетей
# российских операторов через реальные зонды RIPE Atlas (тот же метод
# измерения, что в публичном censorcheck.tlab.pw, но со своим API-ключом -
# см. _skynet_tspu_check_one() и tspu_probe.py). Проверка бьёт напрямую по
# IP из базы флота, без захода на сам сервер по SSH. Присылает сводный
# отчёт в Telegram. Работает и из TUI (настройка/ручной запуск), и
# headless из cron (см. reshala.sh -> censorcheck-report).
#
# @menu.manifest
# @item( skynet | t | ${C_RED}📡 Отчёт "Блокировка ТСПУ" в Telegram${C_RESET} | _skynet_censorcheck_menu | 50 | 2 | Ежедневная проверка блокировок ТСПУ по флоту через RIPE Atlas с отчётом в Telegram. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

_CENSORCHECK_CRON_FILE="/etc/cron.d/reshala-censorcheck"
_TSPU_PROBE_SCRIPT="${SCRIPT_DIR}/modules/skynet/tspu_probe.py"

# Время запуска и отметка в отчёте — московские (RESHALA_TZ и
# RESHALA_TZ_OFFSET_MIN из config/reshala.conf), а не по часовому поясу
# сервера: у VPS это почти всегда UTC, и отчёт приходил на 3 часа позже.

# Те же ASN российских операторов, что и в исходном censorcheck.sh -
# только для перевода номера ASN в человекочитаемое имя в отчёте.
declare -A _TSPU_ASN_NAMES=(
    [12389]="Ростелеком"
    [8402]="Билайн"
    [25513]="МГТС"
    [8359]="МТС"
    [3216]="Билайн"
    [20485]="ТТК"
    [25490]="РТК-Юг"
    [43727]="Мегафон"
    [12714]="Мегафон"
    [34757]="Sib Seti"
    [29124]="Iskratelecom"
    [12768]="Дом.ру"
)

# ============================================================ #
#                        TELEGRAM                              #
# ============================================================ #

# Экранирует спецсимволы HTML в тексте, который подставляется внутрь
# <b>/<blockquote> и т.п. (имена серверов из базы флота вводит сам
# пользователь и не должны ломать разметку сообщения).
_skynet_censorcheck_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Отправляет ОДИН кусок текста (<=4096 символов) в Telegram.
# Печатает HTTP-код ответа в stdout.
_skynet_censorcheck_tg_send_chunk() {
    local text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    curl -s -m 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" \
        -o /dev/null -w '%{http_code}'
}

# Отправляет произвольно длинный текст, разбивая его на несколько
# сообщений по границам строк, если он не влезает в лимит Telegram.
# Возвращает 0, если ВСЕ куски доставлены успешно.
_skynet_censorcheck_tg_send() {
    local full_text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        return 1
    fi

    local max_len=3500
    local chunk="" all_ok=0 http_code

    while IFS= read -r line; do
        if (( ${#chunk} + ${#line} + 1 > max_len )) && [[ -n "$chunk" ]]; then
            http_code=$(_skynet_censorcheck_tg_send_chunk "$chunk")
            [[ "$http_code" != "200" ]] && all_ok=1
            chunk=""
        fi
        chunk+="${line}"$'\n'
    done <<< "$full_text"

    if [[ -n "$chunk" ]]; then
        http_code=$(_skynet_censorcheck_tg_send_chunk "$chunk")
        [[ "$http_code" != "200" ]] && all_ok=1
    fi

    return "$all_ok"
}

_skynet_censorcheck_configure_telegram() {
    clear
    menu_header "📡 Настройка Telegram"
    echo ""
    printf_description "1. Напишите @BotFather в Telegram и создайте бота — получите TG_BOT_TOKEN."
    printf_description "2. Отправьте созданному боту любое сообщение (например /start)."
    printf_description "3. Откройте в браузере (замените <TOKEN> на свой):"
    printf_description "   https://api.telegram.org/bot<TOKEN>/getUpdates"
    printf_description "4. Найдите там \"chat\":{\"id\":ЧИСЛО — это ваш TG_CHAT_ID."
    echo ""
    printf_description "Хранится в ${C_CYAN}${RESHALA_ENV_FILE}${C_RESET} (права 600), не в общем конфиге."
    echo ""

    # Токен вводится скрыто (как sudo-пароли в этом проекте) и никогда не
    # показывается на экране как значение по умолчанию — даже если он уже
    # сохранён. Пустой ввод при повторной настройке оставляет прежний токен.
    local token
    if [[ -n "${TG_BOT_TOKEN:-}" ]]; then
        token=$(ask_password "TG_BOT_TOKEN (уже сохранён, Enter — оставить как есть): ") || return
        [[ -z "$token" ]] && token="$TG_BOT_TOKEN"
    else
        token=$(ask_password "TG_BOT_TOKEN: ") || return
        if [[ -z "$token" ]]; then
            printf_error "Токен не может быть пустым."
            wait_for_enter
            return
        fi
    fi

    local chat_id; chat_id=$(ask_non_empty "TG_CHAT_ID" "${TG_CHAT_ID:-}") || return

    # Храним в /etc/reshala/.env (см. common.sh), а не в config/reshala.conf:
    # это секрет, и он должен пережить переустановку/обновление Решалы.
    set_env_var "TG_BOT_TOKEN" "$token"
    set_env_var "TG_CHAT_ID" "$chat_id"
    TG_BOT_TOKEN="$token"
    TG_CHAT_ID="$chat_id"

    printf_info "Отправляю тестовое сообщение..."
    if _skynet_censorcheck_tg_send "✅ Решала: Telegram настроен. Сюда будут приходить отчёты «Блокировка ТСПУ»."; then
        printf_ok "Готово. Проверьте Telegram."
    else
        printf_error "Не удалось отправить тестовое сообщение. Проверьте токен и chat_id."
    fi
    wait_for_enter
}

_skynet_censorcheck_configure_ripe() {
    clear
    menu_header "🛰 Настройка RIPE Atlas (радар ТСПУ)"
    echo ""
    printf_description "Отчёт проверяет доступность IP серверов из сетей российских"
    printf_description "операторов через реальные зонды RIPE Atlas (тот же метод, что"
    printf_description "и в censorcheck.tlab.pw, но со СВОИМ ключом - автор скрипта"
    printf_description "прямо просит не использовать его ключ в сторонних проектах)."
    echo ""
    printf_description "Как получить свой ключ (бесплатно, пару минут):"
    printf_description "1. Зарегистрируйся на ${C_CYAN}https://atlas.ripe.net${C_RESET}"
    printf_description "2. Профиль -> ${C_CYAN}My API Keys${C_RESET} -> Create -> дай права"
    printf_description "   на создание измерений (Measurement creation)."
    printf_description "3. Скопируй ключ сюда."
    echo ""
    printf_description "Хранится в ${C_CYAN}${RESHALA_ENV_FILE}${C_RESET} (права 600), не в общем конфиге."
    echo ""

    local key
    if [[ -n "${RIPE_API_KEY:-}" ]]; then
        key=$(ask_password "RIPE_API_KEY (уже сохранён, Enter — оставить как есть): ") || return
        [[ -z "$key" ]] && key="$RIPE_API_KEY"
    else
        key=$(ask_password "RIPE_API_KEY: ") || return
        if [[ -z "$key" ]]; then
            printf_error "Ключ не может быть пустым."
            wait_for_enter
            return
        fi
    fi

    echo ""
    printf_description "SNI, под который маскируется проверка (например, домен из вашего"
    printf_description "Reality-конфига). По умолчанию как в исходном скрипте: max.ru"
    local sni; sni=$(ask_non_empty "SNI для пробы" "${TSPU_REALITY_SNI:-max.ru}") || return

    set_env_var "RIPE_API_KEY" "$key"
    RIPE_API_KEY="$key"
    set_config_var "TSPU_REALITY_SNI" "$sni"
    TSPU_REALITY_SNI="$sni"

    printf_ok "Сохранено."
    wait_for_enter
}

# ============================================================ #
#                РАДАР ТСПУ (RIPE ATLAS, БЕЗ SSH)               #
# ============================================================ #
#
# В отличие от полного censorcheck.tlab.pw (который гоняется ПО SSH НА
# каждом сервере флота и проверяет заодно ~30 внешних доменов), проверка
# ТСПУ бьёт зондами RIPE Atlas напрямую в IP сервера - для этого не нужно
# заходить на сам сервер, IP уже есть в базе флота. Поэтому эта часть
# выполняется локально с контрольного хоста, параллельно по всем серверам.

# Проверяет один IP: доступность порта 443 + опрос RIPE Atlas.
# Печатает ОДНУ строку вида:
#   AVAILABLE <детали>
#   BLOCKED <детали>
#   SKIP <причина>
_skynet_tspu_check_one() {
    local ip="$1" sni="$2" api_key="$3"

    # Без реально слушающего 443 RIPE Atlas всё равно покажет "заблокировано"
    # для всех зондов - но это не ТСПУ, а просто отсутствие VPN на сервере.
    # Такие случаи не считаем ни OK, ни BLOCKED - помечаем на ручную проверку.
    if ! timeout 4 bash -c "echo > /dev/tcp/${ip}/443" 2>/dev/null; then
        echo "SKIP порт 443 не отвечает (нет VPN/Reality на сервере или сервер недоступен)"
        return
    fi

    local py_out
    py_out=$(python3 "$_TSPU_PROBE_SCRIPT" "$api_key" "$ip" "$sni" 2>/dev/null)

    if [[ -z "$py_out" ]] || echo "$py_out" | grep -q "^ERROR"; then
        local reason; reason=$(echo "$py_out" | grep "^ERROR" | head -1)
        echo "SKIP RIPE Atlas не ответил (${reason:-нет ответа})"
        return
    fi

    local ok_line; ok_line=$(echo "$py_out" | grep "^OK " | head -1)
    if [[ -z "$ok_line" ]]; then
        echo "SKIP не удалось разобрать ответ RIPE Atlas"
        return
    fi

    local _tag total success blocked
    read -r _tag total success blocked <<< "$ok_line"
    local percent=0
    [[ "${total:-0}" -gt 0 ]] && percent=$(( success * 100 / total ))

    local blockers=""
    local blocked_asn_line; blocked_asn_line=$(echo "$py_out" | grep "^BLOCKED_ASN" | head -1)
    if [[ -n "$blocked_asn_line" ]]; then
        local parts="${blocked_asn_line#BLOCKED_ASN }"
        local part asn cnt name
        for part in $parts; do
            asn="${part%%:*}"; cnt="${part##*:}"
            name="${_TSPU_ASN_NAMES[$asn]:-AS$asn}"
            blockers+="${name}(${cnt}), "
        done
        blockers="${blockers%, }"
    fi

    if [[ "$percent" -eq 100 ]]; then
        echo "AVAILABLE зондов: ${total}, все достучались"
    else
        echo "BLOCKED доступно ${percent}% (${success}/${total})${blockers:+, блокируют: ${blockers}}"
    fi
}

# Запускает проверку ТСПУ на всех серверах флота ПАРАЛЛЕЛЬНО (без SSH,
# напрямую по IP из базы флота). Результаты - в файлах внутри временной
# директории, путь к которой печатает в stdout:
#   <tmp_dir>/N.name   - "Имя (IP)"
#   <tmp_dir>/N.result - "AVAILABLE ..." | "BLOCKED ..." | "SKIP ..."
#   <tmp_dir>/.count   - количество серверов N
_skynet_tspu_check_fleet_parallel() {
    local sni="$1" api_key="$2"
    local tmp_dir; tmp_dir=$(mktemp -d)

    local -a lines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && lines+=("$line")
    done < "$FLEET_DATABASE_FILE"

    local -a pids=()
    local i=0 name user ip port key_path sudo_pass
    for line in "${lines[@]}"; do
        IFS='|' read -r name user ip port key_path sudo_pass <<< "$line"
        [[ -z "$name" ]] && continue
        i=$((i + 1))
        echo "${name} (${ip})" > "${tmp_dir}/${i}.name"
        ( _skynet_tspu_check_one "$ip" "$sni" "$api_key" > "${tmp_dir}/${i}.result" ) &
        pids+=("$!")
    done

    if [[ ${#pids[@]} -gt 0 ]]; then
        wait "${pids[@]}" 2>/dev/null
    fi

    echo "$i" > "${tmp_dir}/.count"
    echo "$tmp_dir"
}

# ============================================================ #
#                     ЗАПУСК ПРОВЕРКИ И ОТЧЁТ                  #
# ============================================================ #

# _skynet_censorcheck_run_and_report [--cron]
# --cron подавляет интерактивный вывод (для запуска без TTY).
_skynet_censorcheck_run_and_report() {
    local mode="${1:-}"
    local verbose=1
    [[ "$mode" == "--cron" ]] && verbose=0

    ensure_package "curl" >/dev/null 2>&1 || true
    ensure_package "python3" >/dev/null 2>&1 || true

    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "TG_BOT_TOKEN/TG_CHAT_ID не настроены (пункт [n])."
        log "CensorCheck: TG_BOT_TOKEN/TG_CHAT_ID не настроены, отчёт не отправлен."
        return 1
    fi

    if [[ -z "${RIPE_API_KEY:-}" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "RIPE_API_KEY не настроен (пункт [k])."
        log "CensorCheck: RIPE_API_KEY не настроен, отчёт не отправлен."
        return 1
    fi

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_warning "Флот пуст, нечего проверять."
        log "CensorCheck: флот пуст, проверка пропущена."
        return 1
    fi

    if [[ ! -f "$_TSPU_PROBE_SCRIPT" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "Скрипт проверки не найден: $_TSPU_PROBE_SCRIPT"
        log "CensorCheck: tspu_probe.py не найден."
        return 1
    fi

    local sni="${TSPU_REALITY_SNI:-max.ru}"

    [[ "$verbose" -eq 1 ]] && printf_info "Проверяю доступность всех серверов флота из сетей РФ (RIPE Atlas, параллельно)..."

    local tmp_dir; tmp_dir=$(_skynet_tspu_check_fleet_parallel "$sni" "$RIPE_API_KEY")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    # Все три группы - одинаковый вид: сворачиваемая (expandable) цитата
    # с заголовком-счётчиком, внутри - КАЖДЫЙ сервер отдельной строкой.
    local ok_list="" fail_list="" skip_list=""
    local total=0 ok_n=0 blocked_n=0 skip_n=0 idx name result kind detail esc_name

    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        result=$(cat "${tmp_dir}/${idx}.result" 2>/dev/null)
        total=$((total + 1))
        esc_name=$(_skynet_censorcheck_html_escape "$name")

        kind="${result%% *}"
        detail="${result#* }"
        [[ "$detail" == "$result" ]] && detail=""
        detail=$(_skynet_censorcheck_html_escape "$detail")

        case "$kind" in
            AVAILABLE)
                ok_n=$((ok_n + 1))
                ok_list+="• ${esc_name}"$'\n'
                ;;
            BLOCKED)
                blocked_n=$((blocked_n + 1))
                fail_list+="• ${esc_name} — ${detail}"$'\n'
                ;;
            *)
                skip_n=$((skip_n + 1))
                skip_list+="• ${esc_name}${detail:+ — ${detail}}"$'\n'
                ;;
        esac
    done
    rm -rf "$tmp_dir"

    local report="<tg-emoji emoji-id=\"5474410313853998290\">💡</tg-emoji> <b>Блокировка ТСПУ — отчёт по флоту</b>"$'\n'"🕐 $(msk_date '+%Y-%m-%d %H:%M') МСК"$'\n\n'

    if [[ -n "$ok_list" ]]; then
        report+="<blockquote expandable>✅ <b>Доступно (${ok_n}):</b>"$'\n'"${ok_list}</blockquote>"$'\n'
    fi

    if [[ -n "$fail_list" ]]; then
        report+=$'\n'"<blockquote expandable>🚫 <b>Заблокировано (${blocked_n}):</b>"$'\n'"${fail_list}</blockquote>"$'\n'
    fi

    if [[ -n "$skip_list" ]]; then
        report+=$'\n'"<blockquote expandable>🔍 <b>Требуют проверки (${skip_n}):</b>"$'\n'"${skip_list}</blockquote>"$'\n'
    fi

    report+=$'\n'"Итого: ${total} серверов · ${blocked_n} заблокировано · ${skip_n} пропущено"

    if _skynet_censorcheck_tg_send "$report"; then
        [[ "$verbose" -eq 1 ]] && printf_ok "Отчёт отправлен в Telegram (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено)."
        log "CensorCheck: отчёт отправлен (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено)."
        return 0
    else
        [[ "$verbose" -eq 1 ]] && printf_error "Не удалось отправить отчёт в Telegram."
        log "CensorCheck: ОШИБКА отправки отчёта в Telegram."
        return 1
    fi
}

# ============================================================ #
#                       ПЛАНИРОВЩИК (CRON)                     #
# ============================================================ #

_skynet_censorcheck_cron_exec_path() {
    if [[ -x "${INSTALL_PATH:-}" ]]; then
        echo "$INSTALL_PATH"
    else
        echo "${SCRIPT_DIR}/reshala.sh"
    fi
}

# Понимает ли установленный cron переменную CRON_TZ (Vixie-cron в Debian/Ubuntu
# и cronie — да, busybox crond — нет). Ищем литерал прямо в бинарнике: man-страниц
# на голом сервере может не быть, а в cron с поддержкой строка есть всегда.
_skynet_censorcheck_cron_has_tz() {
    local bin
    for bin in /usr/sbin/cron /usr/sbin/crond /usr/bin/crond /sbin/cron; do
        [[ -x "$bin" ]] || continue
        grep -qa "CRON_TZ" "$bin" 2>/dev/null && return 0
    done
    return 1
}

# Переводит московское время в локальное время сервера — для cron без CRON_TZ.
# Считаем арифметикой по текущему смещению сервера (date +%z), а не через
# `date -d "TZ=..."`: последнее есть только в GNU date. Печатает "часы минуты".
# Если сам сервер живёт в зоне с переходом на лето, задание после перевода
# стрелок сдвинется на час — на UTC-серверах (типичный VPS) этого не бывает.
_skynet_censorcheck_msk_to_local() {
    local hour="$1" minute="$2"
    local z; z=$(date +%z)   # вида +0300 / -0500
    local offset=$(( 10#${z:1:2} * 60 + 10#${z:3:2} ))
    [[ "${z:0:1}" == "-" ]] && offset=$(( -offset ))

    local total=$(( 10#$hour * 60 + 10#$minute - RESHALA_TZ_OFFSET_MIN + offset ))
    total=$(( (total % 1440 + 1440) % 1440 ))
    echo "$(( total / 60 )) $(( total % 60 ))"
}

_skynet_censorcheck_install_cron() {
    local hour minute
    hour=$(ask_number_in_range "Час запуска по Москве (0-23)" 0 23 "9") || return
    minute=$(ask_number_in_range "Минута запуска (0-59)" 0 59 "0") || return

    local exec_path; exec_path=$(_skynet_censorcheck_cron_exec_path)
    local msk_time; msk_time=$(printf '%02d:%02d' "$hour" "$minute")

    # Поля cron считаются в часовом поясе сервера. Либо просим считать по Москве
    # сам cron (CRON_TZ), либо, если он этого не умеет, переводим время сами.
    local tz_line cron_hour="$hour" cron_minute="$minute"
    if _skynet_censorcheck_cron_has_tz; then
        tz_line="CRON_TZ=${RESHALA_TZ}"
    else
        read -r cron_hour cron_minute <<< "$(_skynet_censorcheck_msk_to_local "$hour" "$minute")"
        tz_line="# Этот cron не понимает CRON_TZ, поэтому ${msk_time} МСК записаны ниже"$'\n'"# как $(printf '%02d:%02d' "$cron_hour" "$cron_minute") по времени сервера."
    fi

    # Строка "# reshala-msk-time" — источник правды для меню: по полям cron
    # уже не видно, какое время просил пользователь.
    cat > "$_CENSORCHECK_CRON_FILE" << EOF
# Reshala: ежедневный отчёт "Блокировка ТСПУ" по флоту Skynet.
# Управляется через: reshala -> 🌐 Skynet -> [t] -> [e]/[d].
# reshala-msk-time ${msk_time}
${tz_line}
${cron_minute} ${cron_hour} * * * root ${exec_path} censorcheck-report >> ${LOGFILE} 2>&1
EOF
    chmod 644 "$_CENSORCHECK_CRON_FILE"
    printf_ok "Ежедневный отчёт запланирован на ${msk_time} по Москве."
    sleep 1
}

_skynet_censorcheck_remove_cron() {
    if [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
        rm -f "$_CENSORCHECK_CRON_FILE"
        printf_ok "Ежедневный отчёт выключен."
    else
        printf_info "Ежедневный отчёт и так был выключен."
    fi
    sleep 1
}

# ============================================================ #
#                          МЕНЮ                                #
# ============================================================ #

_skynet_censorcheck_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "📡 Отчёт «Блокировка ТСПУ» в Telegram"
        printf_description "Ежедневно бьёт зондами RIPE Atlas (сети РФ-операторов) в IP"
        printf_description "каждого сервера флота и присылает сводный отчёт в Telegram."
        echo ""

        local tg_status="${C_RED}не настроен${C_RESET}"
        [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && tg_status="${C_GREEN}настроен${C_RESET}"

        local ripe_status="${C_RED}не настроен${C_RESET}"
        [[ -n "${RIPE_API_KEY:-}" ]] && ripe_status="${C_GREEN}настроен${C_RESET}"

        local cron_status="${C_RED}выключен${C_RESET}"
        if [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
            local cron_time
            cron_time=$(sed -n 's/^# reshala-msk-time //p' "$_CENSORCHECK_CRON_FILE" 2>/dev/null | head -1)
            if [[ -n "$cron_time" ]]; then
                cron_status="${C_GREEN}включен${C_RESET} (${cron_time} МСК)"
            else
                # Задание, записанное до перехода на московское время: там время
                # сервера, и починится оно только пересохранением через [e].
                cron_time=$(grep -oE '^[0-9]+ [0-9]+' "$_CENSORCHECK_CRON_FILE" 2>/dev/null | awk '{printf "%02d:%02d", $2, $1}')
                cron_status="${C_GREEN}включен${C_RESET} (${cron_time:-?} по времени сервера — задай заново через [e])"
            fi
        fi

        printf_description "Telegram:          ${tg_status}"
        printf_description "RIPE Atlas ключ:   ${ripe_status}"
        printf_description "Ежедневный запуск: ${cron_status}"
        echo ""

        printf_menu_option "n" "Настроить TG_BOT_TOKEN / TG_CHAT_ID"
        printf_menu_option "k" "Настроить RIPE Atlas API-ключ / SNI"
        printf_menu_option "e" "Включить/изменить ежедневный запуск"
        printf_menu_option "d" "Выключить ежедневный запуск"
        printf_menu_option "r" "Запустить проверку и отчёт СЕЙЧАС"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [nN]) _skynet_censorcheck_configure_telegram ;;
            [kK]) _skynet_censorcheck_configure_ripe ;;
            [eE]) _skynet_censorcheck_install_cron ;;
            [dD]) _skynet_censorcheck_remove_cron ;;
            [rR])
                if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
                    printf_error "Сначала настрой Telegram [n]."
                    sleep 1
                elif [[ -z "${RIPE_API_KEY:-}" ]]; then
                    printf_error "Сначала настрой RIPE Atlas ключ [k]."
                    sleep 1
                else
                    echo ""
                    _skynet_censorcheck_run_and_report
                    wait_for_enter
                fi
                ;;
            [bB]) break ;;
            *) printf_error "Неверный выбор."; sleep 1 ;;
        esac
    done
    disable_graceful_ctrlc
}
