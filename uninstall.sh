#!/bin/sh

INSTALL_DIR="/opt/sbin"
INIT_PATH="/opt/etc/init.d/torrserver.init"
BIN_PATH="$INSTALL_DIR/torrserver"
CONFIG_DIR="/opt/etc/torrserver"

echo "=== Удаление TorrServer ==="

# Остановка службы через init-скрипт, если он существует
if [ -x "$INIT_PATH" ]; then
    echo "Остановка службы..."
    "$INIT_PATH" stop
fi

# Удаление файлов службы и бинарника
echo "Удаление файлов приложения..."
rm -f "$INIT_PATH"
rm -f "$BIN_PATH"
rm -f "/opt/var/run/torrserver.pid"
rm -f "/opt/var/run/torrserver-watchdog.pid"
rm -f "/opt/var/log/torrserver.log"
rm -f "/opt/var/log/torrserver.log.old"

# Раскомментируйте строчку ниже, если хотите полностью удалить настройки и базу данных TorrServer:
# rm -rf "$CONFIG_DIR"

echo "=== Удаление успешно завершено ==="
