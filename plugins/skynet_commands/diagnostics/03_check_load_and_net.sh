#!/bin/bash
# TITLE: Нагрузка и сеть (процессы по CPU, адреса и маршруты)
# SKYNET_HIDDEN: false
# Плагин для Скайнета: показывает нагрузку и базовую сетевую инфу.
#

run() {
    echo "===== LOAD AVERAGE ====="
    uptime
    echo ""
    echo "===== 5 ПРОЦЕССОВ С НАИБОЛЬШЕЙ НАГРУЗКОЙ НА CPU ====="
    if command -v ps >/dev/null 2>&1; then
        ps aux --sort=-%cpu | head -n 6
    else
        echo "Утилита ps недоступна."
    fi
    echo ""
    echo "===== СЕТЬ (ip -4 addr / route) ====="
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show
        echo ""
        ip route show
    else
        echo "Утилита ip недоступна."
    fi
}

run
