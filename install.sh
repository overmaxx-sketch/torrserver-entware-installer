#!/bin/sh
# TorrServer updater for ASUSWRT-Merlin / Entware
# Repository: overmaxx-sketch/torrserver-unblock-bylampa

export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

REPO="overmaxx-sketch/torrserver-unblock-bylampa"

###############################################
# Detect Linux architecture and select binary
###############################################

detect_architecture() {
    MACHINE="$(uname -m 2>/dev/null)"

    case "$MACHINE" in
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv7|armhf)
            ARCH="arm7"
            ;;
        armv6l|armv6)
            ARCH="arm6"
            ;;
        armv5tel|armv5l|armv5)
            ARCH="arm5"
            ;;
        x86_64|amd64)
            ARCH="amd64"
            ;;
        i386|i486|i586|i686|x86)
            ARCH="386"
            ;;
        mips)
            ARCH="mips"
            ;;
        mipsel|mipsle)
            ARCH="mipsle"
            ;;
        mips64)
            ARCH="mips64"
            ;;
        mips64el|mips64le)
            ARCH="mips64le"
            ;;
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
RUNDIR="/opt/var/run"
PIDFILE="$RUNDIR/torrserver.pid"
WDPID="$RUNDIR/torrserver-watchdog.pid"

BIN_BACKUP="$TS_DIR/torrserver.backup"
INIT_BACKUP="$INIT.backup"

LOCKDIR="/tmp/torrserver-updater.lock"
WORKDIR="/tmp/torrserver-update.$$"
CANDIDATE="$WORKDIR/torrserver.new"
INIT_CANDIDATE="$WORKDIR/S90torrserver.new"
TMP_JSON="$WORKDIR/releases.json"

WAS_RUNNING=0
INSTALL_STARTED=0
ROLLBACK_IN_PROGRESS=0
HAD_OLD_BIN=0
HAD_OLD_INIT=0

log() {
    MSG="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$MSG"
    echo "$MSG" >> "$UPDATELOG"
}

check_dependencies() {
    REQUIRED_TOOLS="
        wget grep cut head sed df tail awk
        cp chmod mkdir rm rmdir cat date sleep
        kill mv wc sync env sh
    "

    MISSING_TOOLS=""

    for TOOL in $REQUIRED_TOOLS; do
        if ! which "$TOOL" >/dev/null 2>&1; then
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
    rm -rf "$WORKDIR"
    rmdir "$LOCKDIR" 2>/dev/null
}

service_running() {
    [ -f "$PIDFILE" ] || return 1

    PID="$(cat "$PIDFILE" 2>/dev/null)"
    case "$PID" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$PID" 2>/dev/null
}

watchdog_running() {
    [ -f "$WDPID" ] || return 1

    PID="$(cat "$WDPID" 2>/dev/null)"
    case "$PID" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$PID" 2>/dev/null
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
    # Fresh installation: create a minimal settings file if none exists.
    if [ ! -f "$SETTINGS" ]; then
        log "settings.json does not exist; creating initial configuration"
        if ! printf '{\n  "Dns": "127.0.0.1"\n}\n' > "$SETTINGS"; then
            log "ERROR: Could not create settings.json: $SETTINGS"
            return 1
        fi
        chmod 644 "$SETTINGS" 2>/dev/null || true
        log "Initial settings.json created with Dns=127.0.0.1"
        return 0
    fi

    if grep -Eq '"Dns"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' "$SETTINGS"; then
        log "DNS is already set to 127.0.0.1"
        return 0
    fi

    DNS_BACKUP="$SETTINGS.before-dns"

    if [ ! -f "$DNS_BACKUP" ]; then
        if ! cp -p "$SETTINGS" "$DNS_BACKUP"; then
            log "ERROR: Could not back up settings.json"
            return 1
        fi

        log "Settings backup saved: $DNS_BACKUP"
    fi

    TMP_SETTINGS="$WORKDIR/settings.json"

    if grep -Eq '"Dns"[[:space:]]*:' "$SETTINGS"; then
        # Update the existing Dns value.
        sed 's/"Dns"[[:space:]]*:[[:space:]]*"[^"]*"/"Dns": "127.0.0.1"/' \
            "$SETTINGS" > "$TMP_SETTINGS" || {
                log "ERROR: Failed to update Dns setting"
                return 1
            }
    else
        log "Dns key is missing; adding it to settings.json"

        # Insert the new root-level key immediately after the first opening brace.
        # Handle an empty object separately to avoid a trailing comma.
        if grep -Eq '^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$' "$SETTINGS"; then
            awk '
                /^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$/ {
                    sub(/\{[[:space:]]*\}/, "{\n  \"Dns\": \"127.0.0.1\"\n}")
                }
                { print }
            ' "$SETTINGS" > "$TMP_SETTINGS" || {
                log "ERROR: Could not add Dns to empty JSON object"
                return 1
            }
        else
            awk '
                BEGIN { inserted=0 }
                {
                    line=$0

                    if (!inserted && match(line, /\{/)) {
                        prefix=substr(line, 1, RSTART)
                        rest=substr(line, RSTART+1)

                        print prefix
                        print "  \"Dns\": \"127.0.0.1\","

                        if (rest != "") {
                            print rest
                        }

                        inserted=1
                    } else {
                        print line
                    }
                }
                END {
                    if (!inserted) exit 2
                }
            ' "$SETTINGS" > "$TMP_SETTINGS" || {
                log "ERROR: Could not safely add Dns to settings.json"
                return 1
            }
        fi
    fi

    if ! grep -Eq '"Dns"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' "$TMP_SETTINGS"; then
        log "ERROR: DNS verification failed in temporary settings"
        return 1
    fi

    if ! cp "$TMP_SETTINGS" "$SETTINGS"; then
        log "ERROR: Failed to save updated settings.json"
        return 1
    fi

    log "DNS successfully set to 127.0.0.1"
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

export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

BIN="/opt/sbin/torrserver"
TS_DIR="/opt/etc/torrserver"
LOGDIR="/opt/var/log"
LOGFILE="$LOGDIR/torrserver.log"
RUNDIR="/opt/var/run"
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
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$1" 2>/dev/null
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

start() {
    mkdir -p "$LOGDIR" "$RUNDIR" "$TS_DIR" || return 1

    if [ -f "$PIDFILE" ] && valid_pid "$(cat "$PIDFILE" 2>/dev/null)"; then
        echo "TorrServer is already running (pid $(cat "$PIDFILE"))"
    else
        rm -f "$PIDFILE"
        rotate_log
        log_msg "INFO: Starting TorrServer"

        (
            export GOMAXPROCS=1
            export GOGC=20
            exec "$BIN" -d "$TS_DIR" -p 8090
        ) >> "$LOGFILE" 2>&1 &

        echo $! > "$PIDFILE"
        sleep 2

        if ! valid_pid "$(cat "$PIDFILE" 2>/dev/null)"; then
            log_msg "ERROR: TorrServer failed to start"
            rm -f "$PIDFILE"
            return 1
        fi

        echo "TorrServer is running (pid $(cat "$PIDFILE"))"
    fi

    if [ ! -f "$WDPID" ] || ! valid_pid "$(cat "$WDPID" 2>/dev/null)"; then
        rm -f "$WDPID"

        (
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

                    (
                        export GOMAXPROCS=1
                        export GOGC=20
                        exec "$BIN" -d "$TS_DIR" -p 8090
                    ) >> "$LOGFILE" 2>&1 &

                    echo $! > "$PIDFILE"
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
        ) >/dev/null 2>&1 &

        # The parent writes the watchdog PID so it is available immediately.
        echo $! > "$WDPID"
    fi

    return 0
}

stop() {
    echo "Stopping TorrServer & Watchdog..."
    log_msg "INFO: Stop requested"

    WPID="$(cat "$WDPID" 2>/dev/null)"

    if valid_pid "$WPID"; then
        # Remove the PID file first; this is the watchdog's stop signal.
        rm -f "$WDPID"
        kill "$WPID" 2>/dev/null
    else
        rm -f "$WDPID"
    fi

    n=0
    while valid_pid "$WPID" && [ "$n" -lt 5 ]; do
        sleep 1
        n=$((n + 1))
    done

    if valid_pid "$WPID"; then
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

    if valid_pid "$WPID"; then
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

mkdir -p "$WORKDIR" || {
    rmdir "$LOCKDIR" 2>/dev/null
    exit 1
}

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

ALL_TAGS="$(grep '"tag_name"' "$TMP_JSON" |
    cut -d '"' -f 4 |
    grep '^MatriX\.')"

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

while :; do
    printf "Enter choice (1-%s): " "$EXIT_CHOICE"
    read CHOICE

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

log "Selected version: $TARGET_TAG"

if [ "$TARGET_TAG" = "$CURRENT_TAG" ]; then
    printf "Version %s is already installed. Reinstall? (y/N): " "$TARGET_TAG"
    read REINSTALL

    case "$REINSTALL" in
        y|Y|yes|YES) ;;
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

if ! wget --no-hsts --timeout=30 --tries=2 -q -O "$CANDIDATE" "$BIN_URL"; then
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

# Configure DNS only after the downloaded binary has passed validation.
if ! ensure_dns; then
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

log "Stopping TorrServer before replacing files"

if ! stop_service; then
    log "ERROR: Could not stop the service safely"
    rollback
    exit 1
fi

log "Installing candidate binary"

if ! cp "$CANDIDATE" "$TS_BIN"; then
    log "ERROR: Failed to install the new binary"
    rollback
    exit 1
fi

chmod 755 "$TS_BIN" || {
    log "ERROR: Failed to set binary permissions"
    rollback
    exit 1
}

if ! env GOMAXPROCS=1 GOGC=20 "$TS_BIN" --version; then
    log "ERROR: Installed binary failed the version test"
    rollback
    exit 1
fi

log "Installing new init script"

if ! cp "$INIT_CANDIDATE" "$INIT"; then
    log "ERROR: Failed to install the new init script"
    rollback
    exit 1
fi

chmod 755 "$INIT" || {
    log "ERROR: Failed to set init script permissions"
    rollback
    exit 1
}

if ! sh -n "$INIT"; then
    log "ERROR: Installed init script failed syntax validation"
    rollback
    exit 1
fi

sync

###############################################
# Restore original running/stopped state
###############################################

if [ "$WAS_RUNNING" -eq 1 ] || [ "$HAD_OLD_BIN" -eq 0 ] || [ "$HAD_OLD_INIT" -eq 0 ]; then
    if [ "$WAS_RUNNING" -eq 1 ]; then
        log "Service was running before update; starting updated service"
    else
        log "Fresh/incomplete installation detected; starting TorrServer"
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
    log "Existing installation was stopped before update; leaving it stopped"
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
