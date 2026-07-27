#!/bin/bash
# ============================================================ #
# ==   SKYNET: ЕЖЕДНЕВНЫЙ ОТЧЁТ "БЛОКИРОВКА ТСПУ" В TELEGRAM == #
# ============================================================ #
#
# Модуль запускает плагин "Блокировка ТСПУ"
# (plugins/skynet_commands/diagnostics/04_censorcheck.sh) на всех
# серверах флота и присылает сводный отчёт в Telegram.
# Работает и из TUI (настройка/ручной запуск), и headless из cron
# (см. reshala.sh -> censorcheck-report).
#
# @menu.manifest
# @item( skynet | t | 📡 Отчёт "Блокировка ТСПУ" в Telegram | _skynet_censorcheck_menu | 50 | 2 | Ежедневная проверка DPI-блокировок на всём флоте с отчётом в Telegram. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Подключаем зависимости на случай headless-вызова из cron, где
# modules/skynet/menu.sh не был подключён.
source "${SCRIPT_DIR}/modules/skynet/keys.sh"
source "${SCRIPT_DIR}/modules/skynet/db.sh"
source "${SCRIPT_DIR}/modules/skynet/executor.sh"

_CENSORCHECK_PLUGIN="${SCRIPT_DIR}/plugins/skynet_commands/diagnostics/04_censorcheck.sh"
_CENSORCHECK_CRON_FILE="/etc/cron.d/reshala-censorcheck"

# ============================================================ #
#                        TELEGRAM                              #
# ============================================================ #

# Отправляет ОДИН кусок текста (<=4096 символов) в Telegram.
# Печатает HTTP-код ответа в stdout.
_skynet_censorcheck_tg_send_chunk() {
    local text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    curl -s -m 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
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
    printf_description "1. Напиши @BotFather в Telegram и создай бота — получишь TG_BOT_TOKEN."
    printf_description "2. Напиши созданному боту любое сообщение (например /start)."
    printf_description "3. Открой в браузере (замени <TOKEN> на свой):"
    printf_description "   https://api.telegram.org/bot<TOKEN>/getUpdates"
    printf_description "4. Найди там \"chat\":{\"id\":ЧИСЛО — это твой TG_CHAT_ID."
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
        printf_ok "Готово! Проверь Telegram."
    else
        printf_error "Не удалось отправить тестовое сообщение. Проверь токен/chat_id."
    fi
    wait_for_enter
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

    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "TG_BOT_TOKEN/TG_CHAT_ID не настроены (пункт [n])."
        log "CensorCheck: TG_BOT_TOKEN/TG_CHAT_ID не настроены, отчёт не отправлен."
        return 1
    fi

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_warning "Флот пуст, нечего проверять."
        log "CensorCheck: флот пуст, проверка пропущена."
        return 1
    fi

    if [[ ! -f "$_CENSORCHECK_PLUGIN" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "Плагин не найден: $_CENSORCHECK_PLUGIN"
        log "CensorCheck: плагин не найден ($_CENSORCHECK_PLUGIN)."
        return 1
    fi

    [[ "$verbose" -eq 1 ]] && printf_info "Проверяю все серверы флота одновременно (параллельно)..."

    local tmp_dir; tmp_dir=$(_skynet_run_plugin_on_fleet_parallel_capture "$_CENSORCHECK_PLUGIN")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    local report="Блокировка ТСПУ — отчёт по флоту"$'\n'"$(date '+%Y-%m-%d %H:%M')"$'\n'
    local total=0 failed=0 idx name status out short_out

    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        status=$(cat "${tmp_dir}/${idx}.status" 2>/dev/null)
        total=$((total + 1))

        if [[ "$status" == "OK" ]]; then
            # Обрезаем вывод, чтобы один "болтливый" сервер не съел весь отчёт
            short_out=$(tail -c 600 "${tmp_dir}/${idx}.out" 2>/dev/null | tr -d '\r')
            report+=$'\n'"✅ ${name}:"$'\n'"${short_out}"$'\n'
        else
            failed=$((failed + 1))
            report+=$'\n'"❌ ${name} — сервер недоступен или проверка не выполнена"
        fi
    done
    rm -rf "$tmp_dir"

    report+=$'\n'"Итого: ${total} серверов, ${failed} недоступно."

    if _skynet_censorcheck_tg_send "$report"; then
        [[ "$verbose" -eq 1 ]] && printf_ok "Отчёт отправлен в Telegram (${total} серверов, ${failed} недоступно)."
        log "CensorCheck: отчёт отправлен (${total} серверов, ${failed} недоступно)."
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

_skynet_censorcheck_install_cron() {
    local hour minute
    hour=$(ask_number_in_range "Час запуска (0-23)" 0 23 "9") || return
    minute=$(ask_number_in_range "Минута запуска (0-59)" 0 59 "0") || return

    local exec_path; exec_path=$(_skynet_censorcheck_cron_exec_path)

    cat > "$_CENSORCHECK_CRON_FILE" << EOF
# Reshala: ежедневный отчёт "Блокировка ТСПУ" по флоту Skynet.
# Управляется через: reshala -> 🌐 Skynet -> [t] -> [e]/[d].
${minute} ${hour} * * * root ${exec_path} censorcheck-report >> ${LOGFILE} 2>&1
EOF
    chmod 644 "$_CENSORCHECK_CRON_FILE"
    printf_ok "Ежедневный отчёт запланирован на $(printf '%02d:%02d' "$hour" "$minute")."
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
        printf_description "Ежедневно запускает проверку DPI-блокировок на всех серверах"
        printf_description "флота и присылает сводный отчёт в Telegram."
        echo ""

        local tg_status="${C_RED}не настроен${C_RESET}"
        [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && tg_status="${C_GREEN}настроен${C_RESET}"

        local cron_status="${C_RED}выключен${C_RESET}"
        if [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
            local cron_time
            cron_time=$(grep -oE '^[0-9]+ [0-9]+' "$_CENSORCHECK_CRON_FILE" 2>/dev/null | awk '{printf "%02d:%02d", $2, $1}')
            cron_status="${C_GREEN}включен${C_RESET} (${cron_time:-?})"
        fi

        printf_description "Telegram:          ${tg_status}"
        printf_description "Ежедневный запуск: ${cron_status}"
        echo ""

        printf_menu_option "n" "Настроить TG_BOT_TOKEN / TG_CHAT_ID"
        printf_menu_option "e" "Включить/изменить ежедневный запуск"
        printf_menu_option "d" "Выключить ежедневный запуск"
        printf_menu_option "r" "Запустить проверку и отчёт СЕЙЧАС"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [nN]) _skynet_censorcheck_configure_telegram ;;
            [eE]) _skynet_censorcheck_install_cron ;;
            [dD]) _skynet_censorcheck_remove_cron ;;
            [rR])
                if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
                    printf_error "Сначала настрой Telegram [n]."
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
