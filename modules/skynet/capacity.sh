#!/bin/bash
# ============================================================ #
# ==        SKYNET: УМНЫЙ ЗАМЕР ПО ВСЕМУ ФЛОТУ              == #
# ============================================================ #
#
# Гоняет «Умный замер» (Ookla-спидтест + расчёт вместимости) сразу на всех
# серверах флота и складывает их вместимость в одно число — «Общую
# вместимость», которую потом показывает дашборд.
#
# Считаем только по серверам из базы флота: локальная машина в сумму не
# входит, её вместимость дашборд и так показывает отдельной строкой
# (LAST_VPN_CAPACITY, локальный замер в modules/local/local_care.sh).
#
#   ( РОДИТЕЛЬ | КЛАВИША | НАЗВАНИЕ | ФУНКЦИЯ | ПОРЯДОК | ГРУППА | ОПИСАНИЕ )
# @menu.manifest
#
# @item( skynet | p | 🏎️  Умный замер флота | _skynet_capacity_fleet_test | 45 | 2 | Спидтест на всех серверах разом и общая вместимость для дашборда. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Модуль вызывается из меню флота, которое executor.sh уже подключило, но
# source идемпотентен — так модуль остаётся рабочим и при вызове напрямую
# через run_module.
source "${SCRIPT_DIR}/modules/skynet/executor.sh"

_SKYNET_CAPACITY_PLUGIN="${SCRIPT_DIR}/plugins/skynet_commands/diagnostics/05_speed_capacity.sh"

_skynet_capacity_fleet_test() {
    clear
    menu_header "🏎️ Умный замер флота"
    printf_description "Ookla-спидтест на каждом сервере + расчёт, скольких юзеров он потянет."
    echo ""

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        printf_error "База флота пуста. Сначала добавь серверы."
        wait_for_enter
        return
    fi

    if [[ ! -f "$_SKYNET_CAPACITY_PLUGIN" ]]; then
        printf_error "Плагин замера не найден: ${_SKYNET_CAPACITY_PLUGIN}"
        wait_for_enter
        return
    fi

    local total; total=$(grep -c . "$FLEET_DATABASE_FILE" 2>/dev/null || echo 0)
    printf_warning "Замер займёт пару минут и скачает трафик на каждом из ${total} серверов."
    printf_description "Где нет бинарника Ookla — плагин поставит его сам."
    echo ""
    if ! ask_yes_no "Погнали? (y/n): " "n"; then
        return
    fi

    printf_info "Гоняю замер параллельно на ${total} серверах. Жду всех, руки убрал..."
    local tmp_dir; tmp_dir=$(_skynet_run_plugin_on_fleet_parallel_capture "$_SKYNET_CAPACITY_PLUGIN")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    echo ""
    print_separator "=" 60
    printf_info "РЕЗУЛЬТАТЫ ЗАМЕРА"
    print_separator "=" 60

    local sum=0 ok_count=0
    local idx name status capacity
    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        status=$(cat "${tmp_dir}/${idx}.status" 2>/dev/null)
        echo ""

        if [[ "$status" != "OK" ]]; then
            printf "${C_RED}❌ %s — сервер недоступен${C_RESET}\n" "$name"
            continue
        fi

        # Плагин печатает человекочитаемый отчёт, а последней строкой -
        # машиночитаемое CAPACITY_USERS=<число>. Сумму собираем только по
        # ней: цифры из текста отчёта (скорость, пинг) в неё не попадут.
        capacity=$(grep -m1 '^CAPACITY_USERS=' "${tmp_dir}/${idx}.out" 2>/dev/null | cut -d'=' -f2)
        if [[ "$capacity" =~ ^[0-9]+$ ]]; then
            sum=$((sum + capacity))
            ok_count=$((ok_count + 1))
            printf "${C_GREEN}✅ %s${C_RESET}\n" "$name"
        else
            printf "${C_YELLOW}⚠️  %s — замер не удался${C_RESET}\n" "$name"
        fi

        grep -v '^CAPACITY_USERS=' "${tmp_dir}/${idx}.out" 2>/dev/null | sed 's/^/   /'
    done

    rm -rf "$tmp_dir"

    echo ""
    print_separator "=" 60

    if [[ "$ok_count" -eq 0 ]]; then
        printf_error "Ни один сервер не отдал результат. Общая вместимость не обновлена."
        wait_for_enter
        return
    fi

    # Дата в формате без '|' и '/': set_config_var пишет значение через sed
    # с разделителем '|', а сам конфиг потом сорсится как shell-файл.
    local stamp; stamp=$(date '+%d.%m %H:%M')
    set_config_var "FLEET_TOTAL_CAPACITY" "$sum"
    set_config_var "FLEET_CAPACITY_SERVERS" "${ok_count} из ${count}"
    set_config_var "FLEET_CAPACITY_DATE" "$stamp"
    log "Замер флота: общая вместимость ${sum} юзеров (${ok_count} из ${count} серверов)"

    printf "\n%b💎 ОБЩАЯ ВМЕСТИМОСТЬ ФЛОТА:%b %b%s юзеров%b\n" \
        "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "$sum" "${C_RESET}"
    printf "   Ответили %s из %s серверов, замер от %s\n" "$ok_count" "$count" "$stamp"
    echo "   (Цифра сохранена и теперь висит на дашборде)"

    wait_for_enter
}
