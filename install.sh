#!/bin/sh
# TorrServer updater for ASUSWRT-Merlin / Entware
# Repository: overmaxx-sketch/torrserver-unblock-bylampa

# Avoid world-writable files created by this script.
umask 022

PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:${PATH:-/usr/bin:/bin}"
export PATH

REPO="overmaxx-sketch/torrserver-unblock-bylampa"

###############################################
# Detect Linux architecture and select binary
###############################################

detect_architecture() {
    MACHINE="$(uname -m 2>/dev/null)"

    case "$MACHINE" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7|armhf) ARCH="arm7" ;;
        armv6l|armv6) ARCH="arm6" ;;
        armv5tel|armv5l|armv5) ARCH="arm5" ;;
        x86_64|amd64) ARCH="amd64" ;;
        i386|i486|i586|i686|x86) ARCH="386" ;;
        mips) ARCH="mips" ;;
        mipsel|mipsle) ARCH="mipsle" ;;
        mips64) ARCH="mips64" ;;
        mips64el|mips64le) ARCH="mips64le" ;;
        *)
            log "ERROR: Unsupported architecture: $MACHINE"
            return 1
            ;;
    esac

    TARGET="TorrServer-linux-$ARCH"

    log "System architecture: $MACHINE"
    log "Selected binary: $TARGET"
    return 0
}

TS_DIR="/opt/etc/torrserver"
TS_BIN="/opt/sbin/torrserver"
INIT="/opt/etc/init.d/S90torrserver"
SETTINGS="$TS_DIR/settings.json"

LOGDIR="/opt/var/log"
LOGFILE="$LOGDIR/torrserver.log"
UPDATELOG="$LOGDIR/torrserver-update.log"
RUNDIR="/tmp/torrserver/run"
PIDFILE="$RUNDIR/torrserver.pid"
WDPID="$RUNDIR/torrserver-watchdog.pid"

BIN_BACKUP="$TS_DIR/torrserver.backup"
INIT_BACKUP="$INIT.backup"

LOCKDIR="/tmp/torrserver-updater.lock"
WORKDIR=""
CANDIDATE=""
INIT_CANDIDATE=""
TMP_JSON=""
AUTO_CHOICE="${AUTO_CHOICE:-}"
AUTO_REINSTALL="${AUTO_REINSTALL:-N}"

WAS_RUNNING=0
HAD_COMPLETE_INSTALL=0
INSTALL_STARTED=0
ROLLBACK_IN_PROGRESS=0
HAD_OLD_BIN=0
HAD_OLD_INIT=0
SETTINGS_EXISTED=0
SETTINGS_CHANGED=0

log() {
    MSG="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$MSG"
    echo "$MSG" >> "$UPDATELOG"
}

# Search PATH directly instead of relying on `which` or `command -v`.
# Entware programs normally live in /opt/bin and /opt/sbin on Merlin.
tool_available() {
    TOOL_TO_FIND="$1"

    # kill is provided by the POSIX shell itself on ASUSWRT/Merlin.
    case "$TOOL_TO_FIND" in
        kill) return 0 ;;
    esac

    OLD_IFS="$IFS"
    IFS=:
    for TOOL_DIR in $PATH; do
        [ -n "$TOOL_DIR" ] || TOOL_DIR="."
        if [ -f "$TOOL_DIR/$TOOL_TO_FIND" ] && [ -x "$TOOL_DIR/$TOOL_TO_FIND" ]; then
            IFS="$OLD_IFS"
            return 0
        fi
    done
    IFS="$OLD_IFS"
    return 1
}

check_dependencies() {
    REQUIRED_TOOLS="
        wget jq grep cut head sed df tail awk
        cp chmod mkdir rm rmdir cat date sleep
        kill mv wc sync env sh start-stop-daemon tr
    "

    MISSING_TOOLS=""

    for TOOL in $REQUIRED_TOOLS; do
        if ! tool_available "$TOOL"; then
            MISSING_TOOLS="$MISSING_TOOLS $TOOL"
        fi
    done

    if [ -n "$MISSING_TOOLS" ]; then
        log "ERROR: Required commands are missing:"
        log "$MISSING_TOOLS"
        log "Install the missing utilities before running the updater."
        return 1
    fi

    if [ -x /opt/bin/patchelf ]; then
        log "Optional dependency found: /opt/bin/patchelf"
    else
        log "WARNING: patchelf is not installed; ELF interpreter will not be modified"
    fi

    log "Dependency check passed"
    return 0
}

cleanup() {
    rm -f "$TS_DIR/.settings.json.tmp.$$" \
        "${TS_BIN}.new.$$" "${INIT}.new.$$" 2>/dev/null
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
    rmdir "$LOCKDIR" 2>/dev/null
}

service_running() {
    [ -f "$PIDFILE" ] || return 1

    PID="$(cat "$PIDFILE" 2>/dev/null)"
    case "$PID" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$PID" 2>/dev/null || return 1
    [ -r "/proc/$PID/cmdline" ] || return 1

    # A live but unrelated process must not be mistaken for TorrServer.
    tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null | grep -q '/opt/sbin/torrserver'
}

watchdog_running() {
    [ -f "$WDPID" ] || return 1

    PID="$(cat "$WDPID" 2>/dev/null)"
    case "$PID" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$PID" 2>/dev/null || return 1
    [ -r "/proc/$PID/cmdline" ] || return 1

    # Match the watchdog launched by the current init script.
    # The old RESTARTS=0 signature no longer exists in watchdog-loop mode.
    CMDLINE="$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null)"
    case "$CMDLINE" in
        *"/opt/etc/init.d/S90torrserver"*'watchdog-loop'*) return 0 ;;
        *) return 1 ;;
    esac
}

start_service() {
    if [ -x "$INIT" ]; then
        "$INIT" start
    else
        log "ERROR: Init script is missing or not executable: $INIT"
        return 1
    fi
}

stop_service() {
    if [ -x "$INIT" ]; then
        "$INIT" stop
    fi

    n=0
    while { service_running || watchdog_running; } && [ "$n" -lt 15 ]; do
        sleep 1
        n=$((n + 1))
    done

    if watchdog_running; then
        WPID="$(cat "$WDPID" 2>/dev/null)"
        log "Watchdog did not stop normally; sending TERM to PID $WPID"
        kill -TERM "$WPID" 2>/dev/null

        n=0
        while watchdog_running && [ "$n" -lt 3 ]; do
            sleep 1
            n=$((n + 1))
        done

        if watchdog_running; then
            log "Watchdog ignored TERM; sending KILL to PID $WPID"
            kill -KILL "$WPID" 2>/dev/null
            sleep 1
        fi
    fi

    if service_running; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        log "TorrServer did not stop normally; sending TERM to PID $PID"
        kill -TERM "$PID" 2>/dev/null

        n=0
        while service_running && [ "$n" -lt 5 ]; do
            sleep 1
            n=$((n + 1))
        done

        if service_running; then
            log "TorrServer ignored TERM; sending KILL to PID $PID"
            kill -KILL "$PID" 2>/dev/null
            sleep 1
        fi
    fi

    if service_running; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        log "ERROR: TorrServer is still running (PID $PID)"
        return 1
    fi

    if watchdog_running; then
        log "ERROR: Watchdog is still running"
        return 1
    fi

    return 0
}

get_current_version() {
    if [ -x "$TS_BIN" ]; then
        env GOMAXPROCS=1 GOGC=20 \
            "$TS_BIN" --version 2>/dev/null |
            grep -oE 'MatriX\.[0-9]+([.-][A-Za-z0-9]+)*' |
            head -n 1
    fi
}

verify_service_ready() {
    # Give the service and watchdog time to create/update their PID files.
    n=0
    while [ "$n" -lt 10 ]; do
        if service_running && watchdog_running; then
            break
        fi

        sleep 1
        n=$((n + 1))
    done

    if ! service_running; then
        log "ERROR: TorrServer process is not running"
        return 1
    fi

    if ! watchdog_running; then
        log "ERROR: Watchdog process is not running"
        return 1
    fi

    # A live PID does not guarantee that the HTTP server is ready.
    n=0
    while [ "$n" -lt 10 ]; do
        if wget -q -T 5 -O /dev/null \
            "http://127.0.0.1:8090/"; then
            log "HTTP readiness check passed"
            return 0
        fi

        n=$((n + 1))
        [ "$n" -lt 10 ] && sleep 2
    done

    log "ERROR: HTTP readiness check failed after retries"
    return 1
}

###############################################
# DNS setting
###############################################

ensure_dns() {
    TMP_SETTINGS="$TS_DIR/.settings.json.tmp.$$"

    # Fresh installation: create settings.json with jq and install it atomically.
    if [ ! -f "$SETTINGS" ]; then
        log "settings.json does not exist; no backup is needed"
        log "Creating initial configuration with jq"

        if ! printf '{}' | jq '.Dns = "127.0.0.1" | .BitTorr.StoreSettingsInJson = true' > "$TMP_SETTINGS"; then
            rm -f "$TMP_SETTINGS"
            log "ERROR: jq could not create the initial settings.json"
            return 1
        fi

        if ! jq -e 'type == "object" and .Dns == "127.0.0.1" and .BitTorr.StoreSettingsInJson == true' \
            "$TMP_SETTINGS" >/dev/null 2>&1; then
            rm -f "$TMP_SETTINGS"
            log "ERROR: Initial settings.json failed JSON validation"
            return 1
        fi

        if ! chmod 600 "$TMP_SETTINGS"; then
            rm -f "$TMP_SETTINGS"
            log "ERROR: Could not set permissions on initial settings.json"
            return 1
        fi

        if ! mv -f "$TMP_SETTINGS" "$SETTINGS"; then
            rm -f "$TMP_SETTINGS"
            log "ERROR: Could not install initial settings.json"
            return 1
        fi

        SETTINGS_CHANGED=1
        log "Initial settings.json created and validated with jq"
        return 0
    fi

    # Back up an existing configuration before any DNS checks or changes.
    # Keep the first backup intact on subsequent installer runs.
    DNS_BACKUP="$SETTINGS.before-dns"

    if [ ! -f "$DNS_BACKUP" ]; then
        if cp -p "$SETTINGS" "$DNS_BACKUP"; then
            log "Settings backup saved: $DNS_BACKUP"
        else
            log "ERROR: Could not back up settings.json; refusing to change it"
            return 1
        fi
    else
        log "Settings backup already exists; leaving it unchanged"
    fi

    # jq is mandatory, so validate the JSON before inspecting or modifying it.
    if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
        log "ERROR: settings.json is not a valid JSON object; refusing to modify it"
        return 1
    fi

    if jq -e '.Dns == "127.0.0.1"' "$SETTINGS" >/dev/null 2>&1; then
        log "DNS is already set to 127.0.0.1"
        return 0
    fi

    if ! jq '.Dns = "127.0.0.1"' "$SETTINGS" > "$TMP_SETTINGS"; then
        rm -f "$TMP_SETTINGS"
        log "ERROR: jq failed to update Dns setting"
        return 1
    fi

    if ! jq -e 'type == "object" and .Dns == "127.0.0.1"' \
        "$TMP_SETTINGS" >/dev/null 2>&1; then
        rm -f "$TMP_SETTINGS"
        log "ERROR: JSON verification failed after updating Dns"
        return 1
    fi

    if ! chmod 600 "$TMP_SETTINGS"; then
        rm -f "$TMP_SETTINGS"
        log "ERROR: Could not set permissions on updated settings.json"
        return 1
    fi

    if ! mv -f "$TMP_SETTINGS" "$SETTINGS"; then
        rm -f "$TMP_SETTINGS"
        log "ERROR: Failed to atomically save updated settings.json"
        return 1
    fi

    SETTINGS_CHANGED=1
    log "DNS successfully set to 127.0.0.1 (validated with jq)"
    return 0
}

###############################################
# Rollback
###############################################

rollback() {
    [ "$INSTALL_STARTED" -eq 1 ] || return 0
    [ "$ROLLBACK_IN_PROGRESS" -eq 0 ] || return 0

    ROLLBACK_IN_PROGRESS=1
    trap '' HUP INT TERM

    log "ROLLBACK: restoring previous installation"

    # Stop the new service before restoring the old files.
    if [ -x "$INIT" ]; then
        "$INIT" stop >/dev/null 2>&1
    fi

    # Fallback termination if the init script could not stop the processes.
    if service_running; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        log "ROLLBACK: sending TERM to TorrServer PID $PID"
        kill -TERM "$PID" 2>/dev/null
        sleep 2

        if service_running; then
            log "ROLLBACK: sending KILL to TorrServer PID $PID"
            kill -KILL "$PID" 2>/dev/null
        fi
    fi

    if watchdog_running; then
        WPID="$(cat "$WDPID" 2>/dev/null)"
        log "ROLLBACK: sending TERM to watchdog PID $WPID"
        kill -TERM "$WPID" 2>/dev/null
        sleep 1

        if watchdog_running; then
            log "ROLLBACK: sending KILL to watchdog PID $WPID"
            kill -KILL "$WPID" 2>/dev/null
        fi
    fi

    # Restore the previous binary, or remove the new one on a fresh install.
    if [ "$HAD_OLD_BIN" -eq 1 ]; then
        if [ ! -s "$BIN_BACKUP" ]; then
            log "CRITICAL: binary backup is missing or empty: $BIN_BACKUP"
        elif ! env GOMAXPROCS=1 GOGC=20 \
            "$BIN_BACKUP" --version >/dev/null 2>&1; then
            log "CRITICAL: binary backup failed --version validation"
        elif cp -p "$BIN_BACKUP" "$TS_BIN"; then
            chmod 755 "$TS_BIN"
            sync

            if env GOMAXPROCS=1 GOGC=20 \
                "$TS_BIN" --version >/dev/null 2>&1; then
                log "ROLLBACK: previous binary restored and validated"
            else
                log "CRITICAL: restored binary failed --version validation"
            fi
        else
            log "CRITICAL: failed to restore previous binary"
        fi
    else
        rm -f "$TS_BIN"
        log "ROLLBACK: removed newly installed binary (no previous binary existed)"
    fi

    # Restore the previous init script, or remove the new one on a fresh install.
    if [ "$HAD_OLD_INIT" -eq 1 ]; then
        if [ ! -s "$INIT_BACKUP" ]; then
            log "CRITICAL: init-script backup is missing or empty: $INIT_BACKUP"
        elif ! sh -n "$INIT_BACKUP"; then
            log "CRITICAL: init-script backup failed syntax validation"
        elif cp -p "$INIT_BACKUP" "$INIT"; then
            chmod 755 "$INIT"
            sync

            if sh -n "$INIT"; then
                log "ROLLBACK: previous init script restored and validated"
            else
                log "CRITICAL: restored init script failed syntax validation"
            fi
        else
            log "CRITICAL: failed to restore previous init script"
        fi
    else
        rm -f "$INIT"
        log "ROLLBACK: removed newly installed init script (no previous init script existed)"
    fi

    # Restore settings.json if this installation attempt changed it.
    if [ "$SETTINGS_CHANGED" -eq 1 ]; then
        if [ "$SETTINGS_EXISTED" -eq 1 ]; then
            if [ -f "$WORKDIR/settings.original" ] &&
               cp -p "$WORKDIR/settings.original" "$SETTINGS"; then
                log "ROLLBACK: original settings.json restored"
            else
                log "CRITICAL: could not restore original settings.json"
            fi
        else
            rm -f "$SETTINGS"
            log "ROLLBACK: removed settings.json created by this attempt"
        fi
    fi

    sync

    # Restore the service's original running/stopped state.
    if [ "$WAS_RUNNING" -eq 1 ]; then
        log "ROLLBACK: service was running before update; starting restored service"

        if [ -x "$INIT" ]; then
            if "$INIT" start; then
                sleep 3

                if verify_service_ready; then
                    log "ROLLBACK: restored TorrServer, watchdog and HTTP checks passed"
                else
                    log "CRITICAL: rollback completed, but service health checks failed"
                fi
            else
                log "CRITICAL: failed to start the restored service"
            fi
        else
            log "CRITICAL: cannot start service; init script is unavailable"
        fi
    else
        log "ROLLBACK: service was stopped before update; leaving it stopped"
    fi

    INSTALL_STARTED=0
    log "ROLLBACK: finished"
}

on_signal() {
    trap '' HUP INT TERM
    log "Interrupted by signal"

    if [ "$INSTALL_STARTED" -eq 1 ] &&
       [ "$ROLLBACK_IN_PROGRESS" -eq 0 ]; then
        rollback
    fi

    cleanup
    exit 1
}

on_exit() {
    RC=$?
    trap - EXIT

    if [ "$INSTALL_STARTED" -eq 1 ] &&
       [ "$ROLLBACK_IN_PROGRESS" -eq 0 ]; then
        rollback
        RC=1
    fi

    cleanup
    exit "$RC"
}

###############################################
# Init script generator
###############################################

create_init_script() {
    cat > "$INIT_CANDIDATE" <<'INITEOT'
#!/bin/sh

PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:${PATH:-/usr/bin:/bin}"
export PATH

BIN="/opt/sbin/torrserver"
TS_DIR="/opt/etc/torrserver"
LOGDIR="/opt/var/log"
LOGFILE="$LOGDIR/torrserver.log"
RUNDIR="/tmp/torrserver/run"
PIDFILE="$RUNDIR/torrserver.pid"
WDPID="$RUNDIR/torrserver-watchdog.pid"
MAX_LOG_SIZE=524288

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOGFILE"
}

rotate_log() {
    [ -f "$LOGFILE" ] || return 0

    SIZE="$(wc -c < "$LOGFILE" 2>/dev/null)"
    case "$SIZE" in
        ''|*[!0-9]*) return 0 ;;
    esac

    if [ "$SIZE" -ge "$MAX_LOG_SIZE" ]; then
        mv -f "$LOGFILE" "$LOGFILE.old"
    fi
}

valid_pid() {
    # Validate the TorrServer process only; never accept a shell merely because
    # its command line contains a watchdog counter.
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null |
        grep -q '/opt/sbin/torrserver'
}

valid_watchdog_pid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 1
    CMDLINE="$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)"
    case "$CMDLINE" in
        *"/opt/etc/init.d/S90torrserver"*'watchdog-loop'*) return 0 ;;
        *) return 1 ;;
    esac
}

get_uptime() {
    PID="$1"

    if [ -r "/proc/$PID/stat" ]; then
        START="$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)"
        NOW="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
        HZ=100

        case "$START:$NOW" in
            *[!0-9:]*|'':*)
                echo "unknown"
                return
                ;;
        esac

        SECONDS_UP=$((NOW - START / HZ))
        [ "$SECONDS_UP" -lt 0 ] && SECONDS_UP=0
        echo "$((SECONDS_UP / 60))m $((SECONDS_UP % 60))s"
    else
        echo "unknown"
    fi
}

watchdog_loop() {
    RESTARTS=0
    STABLE_TIME=0

    while :; do
        sleep 10

        # Removing the watchdog PID file is the stop request.
        [ -f "$WDPID" ] || exit 0

        PID="$(cat "$PIDFILE" 2>/dev/null)"

        if ! valid_pid "$PID"; then
            rm -f "$PIDFILE"
            RESTARTS=$((RESTARTS + 1))
            STABLE_TIME=0

            log_msg "CRASH: Process died (restart $RESTARTS/10)"

            if [ "$RESTARTS" -gt 10 ]; then
                log_msg "ERROR: Restart limit reached. Giving up."
                rm -f "$WDPID"
                exit 1
            fi

            rotate_log

            start-stop-daemon -S -b -m -p "$PIDFILE" \
                -x /bin/sh -- -c "export GOMAXPROCS=1; export GOGC=20; exec \"$BIN\" -d \"$TS_DIR\" -p 8090 >> \"$LOGFILE\" 2>&1" || {
                    log_msg "ERROR: Watchdog could not restart TorrServer"
                    rm -f "$PIDFILE"
                }
        else
            if [ "$RESTARTS" -gt 0 ]; then
                STABLE_TIME=$((STABLE_TIME + 10))

                if [ "$STABLE_TIME" -ge 300 ]; then
                    RESTARTS=0
                    STABLE_TIME=0
                    log_msg "INFO: Process stable for 5min; restart counter reset"
                fi
            fi
        fi
    done
}

start() {
    mkdir -p "$LOGDIR" "$RUNDIR" "$TS_DIR" || return 1

    if [ -f "$PIDFILE" ] && valid_pid "$(cat "$PIDFILE" 2>/dev/null)"; then
        echo "TorrServer is already running (pid $(cat "$PIDFILE"))"
    else
        rm -f "$PIDFILE"
        rotate_log
        log_msg "INFO: Starting TorrServer"

        # Use the same daemonization mechanism as the old working init script.
        start-stop-daemon -S -b -m \
            -p "$PIDFILE" \
            -x /bin/sh -- -c "export GOMAXPROCS=1; export GOGC=20; exec $BIN -d $TS_DIR -p 8090 >> $LOGFILE 2>&1" || {
                log_msg "ERROR: start-stop-daemon could not launch TorrServer"
                rm -f "$PIDFILE"
                return 1
            }

        sleep 2

        if ! valid_pid "$(cat "$PIDFILE" 2>/dev/null)"; then
            log_msg "ERROR: TorrServer failed to start"
            rm -f "$PIDFILE"
            return 1
        fi

        echo "TorrServer is running (pid $(cat "$PIDFILE"))"
    fi

    if [ ! -f "$WDPID" ] || ! valid_watchdog_pid "$(cat "$WDPID" 2>/dev/null)"; then
        rm -f "$WDPID"

        # Run the watchdog through this init script so it uses the same
        # validated watchdog_loop() implementation as the service manager.
        start-stop-daemon -S -b -m \
            -p "$WDPID" \
            -x "$0" -- watchdog-loop || {
                log_msg "ERROR: start-stop-daemon could not launch watchdog"
                rm -f "$WDPID"
                return 1
            }
    fi

    return 0
}

stop() {
    echo "Stopping TorrServer & Watchdog..."
    log_msg "INFO: Stop requested"

    WPID="$(cat "$WDPID" 2>/dev/null)"

    if valid_watchdog_pid "$WPID"; then
        # Remove the PID file first; this is the watchdog's stop signal.
        rm -f "$WDPID"
        kill "$WPID" 2>/dev/null
    else
        rm -f "$WDPID"
    fi

    n=0
    while valid_watchdog_pid "$WPID" && [ "$n" -lt 5 ]; do
        sleep 1
        n=$((n + 1))
    done

    if valid_watchdog_pid "$WPID"; then
        log_msg "WARNING: Watchdog did not stop after TERM; sending KILL"
        kill -KILL "$WPID" 2>/dev/null
    fi

    PID="$(cat "$PIDFILE" 2>/dev/null)"

    if valid_pid "$PID"; then
        kill "$PID" 2>/dev/null

        n=0
        while valid_pid "$PID" && [ "$n" -lt 10 ]; do
            sleep 1
            n=$((n + 1))
        done

        if valid_pid "$PID"; then
            log_msg "WARNING: TorrServer did not stop after TERM; sending KILL"
            kill -KILL "$PID" 2>/dev/null
        fi
    fi

    rm -f "$PIDFILE" "$WDPID"
    log_msg "INFO: Stop completed"
}

restart() {
    stop
    sleep 2
    start
}

status() {
    PID="$(cat "$PIDFILE" 2>/dev/null)"

    if valid_pid "$PID"; then
        echo "TorrServer is running (pid $PID, uptime: $(get_uptime "$PID"))"
    else
        echo "TorrServer is stopped"
    fi

    WPID="$(cat "$WDPID" 2>/dev/null)"

    if valid_watchdog_pid "$WPID"; then
        echo "Watchdog is running (pid $WPID)"
    else
        echo "Watchdog is stopped"
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    watchdog-loop) watchdog_loop ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
INITEOT

    if [ ! -s "$INIT_CANDIDATE" ]; then
        return 1
    fi

    chmod 755 "$INIT_CANDIDATE" || return 1

    if ! sh -n "$INIT_CANDIDATE"; then
        log "ERROR: Generated init script failed syntax validation"
        return 1
    fi

    return 0
}

###############################################
# Main
###############################################

echo "===== TorrServer Update & Maintenance ====="
echo "$(date): Starting task"

mkdir -p "$TS_DIR" "$LOGDIR" "$RUNDIR" || exit 1

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "ERROR: Another updater may be running ($LOCKDIR exists)."
    exit 1
fi

# Use an unpredictable temporary directory where supported. BusyBox/Entware
# installations without a compatible mktemp fall back to a PID-based name.
if tool_available mktemp; then
    WORKDIR="$(mktemp -d /tmp/torrserver-update.XXXXXX 2>/dev/null)"
fi
if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
    WORKDIR="/tmp/torrserver-update.$$"
    if ! (umask 077 && mkdir "$WORKDIR"); then
        log "ERROR: Cannot create temporary working directory"
        rmdir "$LOCKDIR" 2>/dev/null
        exit 1
    fi
fi
CANDIDATE="$WORKDIR/torrserver.new"
INIT_CANDIDATE="$WORKDIR/S90torrserver.new"
TMP_JSON="$WORKDIR/releases.json"

trap on_signal HUP INT TERM
trap on_exit EXIT

log "Checking updater dependencies"

if ! check_dependencies; then
    exit 1
fi

log "Checking settings and installed version"

if ! detect_architecture; then
    exit 1
fi

if service_running; then
    WAS_RUNNING=1
fi

# Preserve the stopped state for an already complete installation.
# Fresh or incomplete installations are started after installation.
if [ -x "$TS_BIN" ] && [ -x "$INIT" ]; then
    HAD_COMPLETE_INSTALL=1
fi

CURRENT_TAG="$(get_current_version)"
[ -n "$CURRENT_TAG" ] || CURRENT_TAG="unknown"
log "Current installed version: $CURRENT_TAG"

# A missing binary/init script means this is a fresh or incomplete installation.
# Do not abort: the release will be downloaded and the missing files created.
if [ ! -x "$TS_BIN" ]; then
    log "No executable TorrServer binary found; proceeding with installation"
fi
if [ ! -f "$INIT" ]; then
    log "Init script is missing; a new one will be installed"
fi

###############################################
# Get releases
###############################################

log "Fetching release list from GitHub"

if ! wget --no-hsts --timeout=15 --tries=2 -qO "$TMP_JSON" \
    "https://api.github.com/repos/$REPO/releases?per_page=30"; then
    log "ERROR: Could not fetch release list"
    exit 1
fi

if [ ! -s "$TMP_JSON" ]; then
    log "ERROR: GitHub returned an empty release list"
    exit 1
fi

if ! jq -e 'type == "array"' "$TMP_JSON" >/dev/null 2>&1; then
    log "ERROR: GitHub response is not a valid releases JSON array"
    exit 1
fi
ALL_TAGS="$(jq -r '.[].tag_name | select(type == "string" and startswith("MatriX."))' "$TMP_JSON")"

if [ -z "$ALL_TAGS" ]; then
    log "ERROR: No MatriX.* releases found"
    exit 1
fi

LATEST_TAG="$(echo "$ALL_TAGS" | head -n 1)"
LAST_TAGS="$(echo "$ALL_TAGS" | sed '1d' | head -n 5)"

echo
echo "===== Select TorrServer version to install ====="
echo "1) $LATEST_TAG (latest)"

i=2
for TAG in $LAST_TAGS; do
    echo "$i) $TAG"
    i=$((i + 1))
done

echo "$i) Exit without installing"
EXIT_CHOICE="$i"

if [ -n "$AUTO_CHOICE" ]; then
    CHOICE="$AUTO_CHOICE"
    log "Using AUTO_CHOICE=$CHOICE"
else
    CHOICE=""
    while :; do
        printf "Enter choice (1-%s): " "$EXIT_CHOICE"
        if ! IFS= read -r CHOICE; then
            echo
            log "Input closed; exiting without installing TorrServer"
            exit 0
        fi

        case "$CHOICE" in
        ''|*[!0-9]*)
            echo "Please enter a number between 1 and $EXIT_CHOICE."
            continue
            ;;
    esac

    if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$EXIT_CHOICE" ]; then
        break
    fi

        echo "Invalid choice."
    done
fi

case "$CHOICE" in
    ''|*[!0-9]*)
        log "ERROR: AUTO_CHOICE must be a number between 1 and $EXIT_CHOICE"
        exit 1
        ;;
esac
if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$EXIT_CHOICE" ]; then
    log "ERROR: Choice is outside the valid range 1-$EXIT_CHOICE"
    exit 1
fi

if [ "$CHOICE" -eq "$EXIT_CHOICE" ]; then
    log "Exiting without installing TorrServer"
    exit 0
fi

if [ "$CHOICE" -eq 1 ]; then
    TARGET_TAG="$LATEST_TAG"
else
    IDX=$((CHOICE - 1))
    TARGET_TAG="$(echo "$LAST_TAGS" | sed -n "${IDX}p")"
fi

[ -n "$TARGET_TAG" ] || {
    log "ERROR: Could not determine selected release"
    exit 1
}

# Validate the selected tag using POSIX shell patterns (no jq regex support needed).
case "$TARGET_TAG" in
    MatriX.*) ;;
    *)
        log "ERROR: Selected release tag has an unexpected format: $TARGET_TAG"
        exit 1
        ;;
esac
case "$TARGET_TAG" in
    *[!A-Za-z0-9._-]*|*..*|*/*)
        log "ERROR: Selected release tag contains unsafe characters: $TARGET_TAG"
        exit 1
        ;;
esac

# Confirm the selected release advertises the expected architecture-specific binary.
if ! jq -e --arg tag "$TARGET_TAG" --arg asset "$TARGET" '
    [ .[]
      | select(.tag_name == $tag)
      | .assets[]?
      | select(.name == $asset)
    ] | length > 0
' "$TMP_JSON" >/dev/null 2>&1; then
    log "ERROR: Release $TARGET_TAG does not contain the expected asset $TARGET"
    exit 1
fi

log "Selected version: $TARGET_TAG"

if [ "$TARGET_TAG" = "$CURRENT_TAG" ]; then
    if [ -n "$AUTO_CHOICE" ]; then
        REINSTALL="$AUTO_REINSTALL"
        log "Using AUTO_REINSTALL=$REINSTALL"
    else
        printf "Version %s is already installed. Reinstall? (y/N): " "$TARGET_TAG"
        if ! IFS= read -r REINSTALL; then
            echo
            log "Input closed; installation cancelled"
            exit 0
        fi
    fi

    case "$REINSTALL" in
        y|Y|yes|YES|1) ;;
        *) log "Installation cancelled"; exit 0 ;;
    esac
fi

###############################################
# Check free space and download candidate
###############################################

FREE_KB="$(df -k /opt | tail -n 1 | awk '{print $4}')"

case "$FREE_KB" in
    ''|*[!0-9]*)
        log "WARNING: Could not determine free space on /opt"
        ;;
    *)
        if [ "$FREE_KB" -lt 30720 ]; then
            log "ERROR: Less than 30 MB free on /opt"
            exit 1
        fi
        ;;
esac

BIN_URL="https://github.com/$REPO/releases/download/$TARGET_TAG/$TARGET"
log "Downloading $TARGET_TAG to temporary storage"

if ! wget --no-hsts --timeout=30 --tries=2 -O "$CANDIDATE" "$BIN_URL"; then
    log "ERROR: Download failed"
    exit 1
fi

if [ ! -s "$CANDIDATE" ]; then
    log "ERROR: Downloaded file is empty"
    exit 1
fi

if head -c 256 "$CANDIDATE" | grep -qiE '<html|<!doctype'; then
    log "ERROR: GitHub returned HTML instead of a binary"
    exit 1
fi

chmod 755 "$CANDIDATE" || {
    log "ERROR: Cannot make downloaded binary executable"
    exit 1
}

# Detect and repair the ELF interpreter only when necessary.
if [ -x /opt/bin/patchelf ]; then
    ELF_INTERPRETER="$(/opt/bin/patchelf --print-interpreter \
        "$CANDIDATE" 2>/dev/null)"
    PATCHELF_RC=$?

    if [ "$PATCHELF_RC" -ne 0 ] || [ -z "$ELF_INTERPRETER" ]; then
        log "No patchable ELF interpreter detected; testing binary as-is"
    elif [ -e "$ELF_INTERPRETER" ]; then
        log "ELF interpreter exists: $ELF_INTERPRETER"
    else
        log "Required ELF interpreter is missing: $ELF_INTERPRETER"
        ENTWARE_INTERPRETER=""

        case "$ARCH" in
            arm64)
                for LOADER in \
                    /opt/lib/ld-linux-aarch64.so.1
                do
                    if [ -e "$LOADER" ]; then
                        ENTWARE_INTERPRETER="$LOADER"
                        break
                    fi
                done
                ;;
            arm7|arm6|arm5)
                for LOADER in \
                    /opt/lib/ld-linux.so.3 \
                    /opt/lib/ld-linux-armhf.so.3
                do
                    if [ -e "$LOADER" ]; then
                        ENTWARE_INTERPRETER="$LOADER"
                        break
                    fi
                done
                ;;
            amd64)
                for LOADER in \
                    /opt/lib/ld-linux-x86-64.so.2
                do
                    if [ -e "$LOADER" ]; then
                        ENTWARE_INTERPRETER="$LOADER"
                        break
                    fi
                done
                ;;
            386)
                for LOADER in \
                    /opt/lib/ld-linux.so.2
                do
                    if [ -e "$LOADER" ]; then
                        ENTWARE_INTERPRETER="$LOADER"
                        break
                    fi
                done
                ;;
            mips|mipsle|mips64|mips64le)
                for LOADER in \
                    /opt/lib/ld.so.1 \
                    /opt/lib/ld-uClibc.so.0 \
                    /opt/lib/ld-musl-mips*.so.1
                do
                    if [ -e "$LOADER" ]; then
                        ENTWARE_INTERPRETER="$LOADER"
                        break
                    fi
                done
                ;;
            *)
                log "No interpreter mapping for architecture: $ARCH"
                ;;
        esac

        if [ -n "$ENTWARE_INTERPRETER" ]; then
            log "Trying Entware interpreter: $ENTWARE_INTERPRETER"

            if ! /opt/bin/patchelf \
                --set-interpreter "$ENTWARE_INTERPRETER" "$CANDIDATE"
            then
                log "ERROR: Failed to set ELF interpreter"
                exit 1
            fi
        else
            log "ERROR: No candidate Entware interpreter found"
            exit 1
        fi
    fi
else
    log "WARNING: patchelf is unavailable; testing binary without changes"
fi

log "Testing candidate binary"
if ! env GOMAXPROCS=1 GOGC=20 "$CANDIDATE" --version; then
    log "ERROR: Candidate binary failed the --version test"
    exit 1
fi

###############################################
# Prepare and validate new init script
###############################################

log "Preparing new init script"

if ! create_init_script; then
    log "ERROR: Could not create or validate the new init script"
    exit 1
fi

###############################################
# Back up existing files
###############################################

if [ -f "$TS_BIN" ]; then
    if ! cp -p "$TS_BIN" "$BIN_BACKUP"; then
        log "ERROR: Cannot back up the current binary; refusing to replace it"
        exit 1
    fi

    HAD_OLD_BIN=1
    log "Binary backup saved: $BIN_BACKUP"
else
    log "No previous binary; proceeding as a fresh installation"
fi

if [ -f "$INIT" ]; then
    if ! cp -p "$INIT" "$INIT_BACKUP"; then
        log "ERROR: Cannot back up the current init script; refusing to replace it"
        exit 1
    fi

    HAD_OLD_INIT=1
    log "Init script backup saved: $INIT_BACKUP"
else
    log "No previous init script; a new one will be installed"
fi

###############################################
# Installation transaction
###############################################

INSTALL_STARTED=1

# Snapshot the exact pre-update settings before ensure_dns can modify them.
if [ -f "$SETTINGS" ]; then
    SETTINGS_EXISTED=1
    if ! cp -p "$SETTINGS" "$WORKDIR/settings.original"; then
        log "ERROR: Cannot snapshot settings.json; refusing to modify it"
        rollback
        exit 1
    fi
fi

log "Checking DNS settings"
if ! ensure_dns; then
    rollback
    exit 1
fi

log "Stopping TorrServer before replacing files"

if ! stop_service; then
    log "ERROR: Could not stop the service safely"
    rollback
    exit 1
fi

log "Installing candidate binary"

# Stage the binary beside the destination, then rename atomically on /opt.
BIN_STAGE="${TS_BIN}.new.$$"
if ! cp "$CANDIDATE" "$BIN_STAGE"; then
    log "ERROR: Failed to stage the new binary"
    rm -f "$BIN_STAGE"
    rollback
    exit 1
fi

if ! chmod 755 "$BIN_STAGE"; then
    log "ERROR: Failed to set staged binary permissions"
    rm -f "$BIN_STAGE"
    rollback
    exit 1
fi

if ! env GOMAXPROCS=1 GOGC=20 "$BIN_STAGE" --version; then
    log "ERROR: Staged binary failed the version test"
    rm -f "$BIN_STAGE"
    rollback
    exit 1
fi

if ! mv -f "$BIN_STAGE" "$TS_BIN"; then
    log "ERROR: Failed to atomically install the new binary"
    rm -f "$BIN_STAGE"
    rollback
    exit 1
fi

log "Installing new init script"

# The init script is staged in the destination directory for an atomic rename.
INIT_STAGE="${INIT}.new.$$"
if ! cp "$INIT_CANDIDATE" "$INIT_STAGE"; then
    log "ERROR: Failed to stage the new init script"
    rm -f "$INIT_STAGE"
    rollback
    exit 1
fi

if ! chmod 755 "$INIT_STAGE"; then
    log "ERROR: Failed to set staged init-script permissions"
    rm -f "$INIT_STAGE"
    rollback
    exit 1
fi

if ! sh -n "$INIT_STAGE"; then
    log "ERROR: Staged init script failed syntax validation"
    rm -f "$INIT_STAGE"
    rollback
    exit 1
fi

if ! mv -f "$INIT_STAGE" "$INIT"; then
    log "ERROR: Failed to atomically install the new init script"
    rm -f "$INIT_STAGE"
    rollback
    exit 1
fi

sync

###############################################
# Restore the intended service state
###############################################

if [ "$WAS_RUNNING" -eq 1 ] || [ "$HAD_COMPLETE_INSTALL" -eq 0 ]; then
    if [ "$WAS_RUNNING" -eq 1 ]; then
        log "Service was running before update; starting updated service"
    else
        log "Fresh or incomplete installation; starting TorrServer"
    fi

    if ! start_service; then
        log "ERROR: Updated service failed to start"
        rollback
        exit 1
    fi

    if ! verify_service_ready; then
        log "ERROR: Post-install service health checks failed"
        rollback
        exit 1
    fi

    log "TorrServer, watchdog and HTTP readiness checks passed"
else
    log "Service was stopped before update; leaving it stopped"
fi

INSTALL_STARTED=0
log "Update completed successfully: $TARGET_TAG"

echo
echo "=========================================="
echo "TorrServer update completed successfully"
echo "Installed version: $TARGET_TAG"
echo "=========================================="
echo
echo "Manual service management commands:"
echo "  Status:  /opt/etc/init.d/S90torrserver status"
echo "  Start:   /opt/etc/init.d/S90torrserver start"
echo "  Stop:    /opt/etc/init.d/S90torrserver stop"
echo "  Restart: /opt/etc/init.d/S90torrserver restart"
echo
echo "Updater log:    $UPDATELOG"
echo "TorrServer log: $LOGFILE"
echo

exit 0
