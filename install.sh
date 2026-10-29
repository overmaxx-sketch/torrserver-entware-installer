#!/bin/sh

# Определяем архитектуру (по умолчанию amd64, можно заменить на arm, arm64, 386 и т.д.)
ARCH="amd64"
BINARY_URL="https://github.com/TorrServer/TorrServer/releases/latest/download/TorrServer-linux-$ARCH"

INSTALL_DIR="/opt/sbin"
CONFIG_DIR="/opt/etc/torrserver"
INIT_DIR="/opt/etc/init.d"
BIN_PATH="$INSTALL_DIR/torrserver"
INIT_PATH="$INIT_DIR/torrserver.init"

echo "=== Установка TorrServer ==="

# Проверка окружения Entware
if [ ! -d "/opt" ]; then
    echo "Ошибка: Окружение Entware (/opt) не найдено!"
    exit 1
fi

# Создание необходимых директорий
echo "Создание директорий..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$INIT_DIR"
mkdir -p "/opt/var/run"
mkdir -p "/opt/var/log"

# Скачивание бинарного файла TorrServer
echo "Скачивание TorrServer для архитектуры $ARCH..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$BIN_PATH" "$BINARY_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$BIN_PATH" "$BINARY_URL"
else
    echo "Ошибка: Не найдены curl или wget для скачивания."
    exit 1
fi

# Делаем файл исполняемым
chmod +x "$BIN_PATH"

# Создание init-скрипта из предоставленного текста
echo "Создание скрипта инициализации ($INIT_PATH)..."
cat << 'EOF' > "$INIT_PATH"
#!/bin/sh

PIDFILE=/opt/var/run/torrserver.pid
BIN=/opt/sbin/torrserver
ARGS="-d /opt/etc/torrserver -p 8090"
WDPID=/opt/var/run/torrserver-watchdog.pid
LOGFILE=/opt/var/log/torrserver.log
MAX_LOG_SIZE=524288 # 500 КБ

log_msg() {
    if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt $MAX_LOG_SIZE ]; then
        mv "$LOGFILE" "${LOGFILE}.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
}

get_uptime() {
    PID=$1
    if [ -d "/proc/$PID" ]; then
        if [ -f "/proc/$PID/stat" ] && [ -f "/proc/uptime" ]; then
            CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
            SYS_UPTIME=$(cut -d. -f1 /proc/uptime)
            START_TIME_TICKS=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)

            if [ -n "$START_TIME_TICKS" ]; then
                START_TIME_SEC=$((START_TIME_TICKS / CLK_TCK))
                UP_SEC=$((SYS_UPTIME - START_TIME_SEC))

                DAYS=$((UP_SEC / 86400))
                HOURS=$(( (UP_SEC % 86400) / 3600 ))
                MINS=$(( (UP_SEC % 3600) / 60 ))
                SECS=$((UP_SEC % 60))

                UPTIME_STR=""
                [ $DAYS -gt 0 ] && UPTIME_STR="${DAYS}d "
                [ $HOURS -gt 0 ] && UPTIME_STR="${UPTIME_STR}${HOURS}h "
                UPTIME_STR="${UPTIME_STR}${MINS}m ${SECS}s"

                echo "$UPTIME_STR"
                return
            fi
        fi

        NOW=$(date +%s)
        PROC_START=$(stat -c %Y "/proc/$PID" 2>/dev/null)
        if [ -n "$PROC_START" ]; then
            UP_SEC=$((NOW - PROC_START))
            MINS=$((UP_SEC / 60))
            echo "${MINS}m $((UP_SEC % 60))s"
            return
        fi
    fi
    echo "unknown"
}

start() {
    echo "Starting TorrServer..."

    if [ ! -x "$BIN" ]; then
        echo "Binary not found: $BIN"
        log_msg "ERROR: Binary not found at $BIN"
        logger -p user.err -t "TorrServer" "Binary not found: $BIN"
        return 1
    fi

    mkdir -p /opt/var/log /opt/var/run

    if [ -f $PIDFILE ] && kill -0 "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null; then
        echo "TorrServer already running (pid $(cat $PIDFILE))"
        return 0
    fi

    rm -f $PIDFILE

    start-stop-daemon -S -b -m \
        -p $PIDFILE \
        -x /bin/sh -- -c "exec $BIN $ARGS >> $LOGFILE 2>&1"

    sleep 1
    TS_PID=$(cat $PIDFILE 2>/dev/null)
    log_msg "INFO: TorrServer started with PID $TS_PID"

    if [ -f $WDPID ] && kill -0 "$(cat $WDPID 2>/dev/null)" 2>/dev/null; then
        return 0
    fi

    start-stop-daemon -S -b -m \
        -p $WDPID \
        -x /bin/sh -- -c "
            RESTARTS=0
            STABLE_TIME=0
            while true; do
                sleep 10
                PID=\$(cat $PIDFILE 2>/dev/null)

                if [ -z \"\$PID\" ] || ! kill -0 \$PID 2>/dev/null; then
                    echo \"\$(date '+%Y-%m-%d %H:%M:%S') - CRASH: Process died!\" >> $LOGFILE
                    logger -p user.err -t \"TorrServer-Watchdog\" \"CRASH: Process stopped unexpectedly. Restarting...\"

                    rm -f $PIDFILE

                    start-stop-daemon -S -b -m \
                        -p $PIDFILE \
                        -x /bin/sh -- -c \"exec $BIN $ARGS >> $LOGFILE 2>&1\"

                    sleep 1
                    NEWPID=\$(cat $PIDFILE 2>/dev/null)
                    echo \"\$(date '+%Y-%m-%d %H:%M:%S') - INFO: Restarted with PID \$NEWPID\" >> $LOGFILE

                    RESTARTS=\$((RESTARTS+1))
                    STABLE_TIME=0
                    if [ \$RESTARTS -gt 10 ]; then
                        echo \"\$(date '+%Y-%m-%d %H:%M:%S') - FATAL: Exceeded 10 restart attempts.\" >> $LOGFILE
                        logger -p user.err -t \"TorrServer-Watchdog\" \"FATAL: Exceeded max restarts (10). Giving up.\"
                        exit 1
                    fi
                else
                    if [ \$RESTARTS -gt 0 ]; then
                        STABLE_TIME=\$((STABLE_TIME + 10))
                        if [ \$STABLE_TIME -ge 300 ]; then
                            RESTARTS=0
                            STABLE_TIME=0
                            echo \"\$(date '+%Y-%m-%d %H:%M:%S') - INFO: Process stable for 5min, reset restart counter\" >> $LOGFILE
                        fi
                    fi
                fi
            done
        "
}

stop() {
    echo "Stopping TorrServer & Watchdog..."
    log_msg "INFO: Service stop requested"
    if [ -f $WDPID ]; then
        kill "$(cat $WDPID 2>/dev/null)" 2>/dev/null
        rm -f $WDPID
    fi
    if [ -f $PIDFILE ]; then
        kill "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null
        rm -f $PIDFILE
    fi
}

restart() {
    log_msg "INFO: Service restart requested"
    stop
    sleep 2
    start
}

status() {
    if [ -f $PIDFILE ] && kill -0 "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null; then
        PID=$(cat $PIDFILE)
        UPTIME=$(get_uptime $PID)
        echo "TorrServer is running (pid $PID, uptime: $UPTIME)"
    else
        echo "TorrServer is stopped"
    fi

    if [ -f $WDPID ] && kill -0 "$(cat $WDPID 2>/dev/null)" 2>/dev/null; then
        echo "Watchdog is running (pid $(cat $WDPID))"
    else
        echo "Watchdog is stopped"
    fi
}

case "$1" in
    start) stop &>/dev/null; exit 0 ;; # На всякий случай для совместимости или штатно:
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
EOF

chmod +x "$INIT_PATH"

echo "=== Установка завершена ==="
echo "Запуск службы..."
"$INIT_PATH" start
