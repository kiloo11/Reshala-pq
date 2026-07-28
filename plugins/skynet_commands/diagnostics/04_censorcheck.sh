#!/bin/bash
# TITLE: Блокировка ТСПУ
# SKYNET_HIDDEN: false
# SKYNET_COLOR: cyan
# Плагин для Скайнета: скачивает и запускает CensorCheck на удалённом сервере.
#

run() {
    if ! command -v wget >/dev/null 2>&1; then
        echo "Утилита wget не найдена на сервере."
        return 1
    fi
    wget -qO- censorcheck.tlab.pw | bash
}

run
