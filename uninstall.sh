```sh
#!/bin/sh
# TorrServer Unblock byLampa uninstaller / rollback
# ASUSWRT-Merlin / Entware
# Repository: overmaxx-sketch/torrserver-entware-installer

export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

TS_DIR="/opt/etc/torrserver"
TS_BIN="/opt/sbin/torrserver"
INIT="/opt/etc/init.d/S90torrserver"
SETTINGS="$TS_DIR/settings.json"
DNS_BACKUP="$SETTINGS.before-dns"

LOGDIR="/opt/var/log"
LOGFILE="$LOGDIR/torrserver.log"
UPDATELOG="$LOGDIR/torrserver-update.log"

RUNDIR="/opt/var/run"
PIDFILE="$RUNDIR/torrserver.pid"
WDPID="$RUNDIR/torrserver-watchdog.pid"

BIN_BACKUP="$TS_DIR/torrserver.backup"
INIT_BACKUP="$INIT.backup"

LOCKDIR="/tmp/torrserver-updater.lock"

log() {
    MSG="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$MSG"
    if [ -d "$LOGDIR" ]; then
        echo "$MSG" >> "$UPDATELOG"
    fi
}

confirm() {
    printf '%s [y/N]: ' "$1"
    read answer
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

valid_pid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

restore_dns() {
    if [ ! -f "$DNS_BACKUP" ]; then
        log "WARNING: No DNS backup found: $DNS_BACKUP"
        log "DNS settings were not changed by this script."
        return 0
    fi

    if [ ! -f "$SETTINGS" ]; then
        log "WARNING: settings.json is missing; cannot restore DNS settings."
        return 1
    fi

    echo
    echo "The DNS backup contains the complete settings.json from before"
    echo "the installer changed the DNS setting."
    echo "Restoring it will overwrite changes made to settings.json since then."

    if ! confirm "Restore the original settings.json"; then
        log "Keeping current settings.json; DNS backup retained."
        return 0
    fi

    if cp -p "$DNS_BACKUP" "$SETTINGS"; then
        log "Original settings.json restored."
        rm -f "$DNS_BACKUP"
        return 0
    fi

    log "ERROR: Failed to restore settings.json."
    return 1
}

stop_service() {
    log "Stopping TorrServer and watchdog..."

    if [ -x "$INIT" ]; then
        "$INIT" stop
    else
        log "WARNING: Init script is missing or not executable."
    fi

    # Wait for the service and watchdog to stop.
    n=0
    while [ "$n" -lt 15 ]; do
        alive=0

        if [ -f "$PIDFILE" ]; then
            PID="$(cat "$PIDFILE" 2>/dev/null)"
            if valid_pid "$PID" && kill -0 "$PID" 2>/dev/null; then
                alive=1
            fi
        fi

        if [ -f "$WDPID" ]; then
            PID="$(cat "$WDPID" 2>/dev/null)"
            if valid_pid "$PID" && kill -0 "$PID" 2>/dev/null; then
                alive=1
            fi
        fi

        [ "$alive" -eq 0 ] && break

        sleep 1
        n=$((n + 1))
    done

    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if valid_pid "$PID" && kill -0 "$PID" 2>/dev/null; then
            log "ERROR: TorrServer may still be running (PID $PID)."
            log "Refusing to remove files while the process is running."
            return 1
        fi
    fi

    if [ -f "$WDPID" ]; then
        PID="$(cat "$WDPID" 2>/dev/null)"
        if valid_pid "$PID" && kill -0 "$PID" 2>/dev/null; then
            log "ERROR: Watchdog may still be running (PID $PID)."
            log "Refusing to remove files while the watchdog is running."
            return 1
        fi
    fi

    rm -f "$PIDFILE" "$WDPID"
    log "Service stop check completed."
    return 0
}

rollback_installation() {
    echo
    echo "Rollback restores the binary and init script saved before an update."
    echo "Both backup files must exist."

    [ -s "$BIN_BACKUP" ] || {
        log "ERROR: Binary backup missing: $BIN_BACKUP"
        return 1
    }

    [ -s "$INIT_BACKUP" ] || {
        log "ERROR: Init-script backup missing: $INIT_BACKUP"
        return 1
    }

    sh -n "$INIT_BACKUP" || {
        log "ERROR: Backup init script has invalid shell syntax."
        return 1
    }

    stop_service || return 1

    cp -p "$BIN_BACKUP" "$TS_BIN" || {
        log "ERROR: Failed to restore the previous binary."
        return 1
    }
    chmod 755 "$TS_BIN" || return 1

    cp -p "$INIT_BACKUP" "$INIT" || {
        log "ERROR: Failed to restore the previous init script."
        return 1
    }
    chmod 755 "$INIT" || return 1

    sh -n "$INIT" || {
        log "ERROR: Restored init script failed syntax validation."
        return 1
    }

    sync
    log "Previous binary and init script restored."

    restore_dns || return 1

    echo
    echo "Rollback completed."
    echo "The previous TorrServer installation has been restored."
    echo "The service has been left stopped."
    echo "Start it manually if needed:"
    echo "  $INIT start"
}

full_uninstall() {
    echo
    echo "This will remove:"
    echo "  - TorrServer binary"
    echo "  - TorrServer init script"
    echo "  - Installer-created binary/init backups"
    echo "  - TorrServer PID files"
    echo
    echo "The settings.json file and logs will be kept."
    echo "DNS restoration may replace settings.json with its old backup."

    confirm "Continue with full TorrServer removal" || {
        echo "Cancelled."
        return 0
    }

    stop_service || return 1

    restore_dns || return 1

    rm -f "$TS_BIN" || return 1
    rm -f "$INIT" || return 1
    rm -f "$BIN_BACKUP" "$INIT_BACKUP"
    rm -f "$PIDFILE" "$WDPID"

    # Remove the configuration directory only if it is empty.
    rmdir "$TS_DIR" 2>/dev/null

    sync
    log "TorrServer binary and init script removed."

    echo
    echo "TorrServer has been removed."
    echo "User settings and logs, if present, have been preserved."
    echo "Review these paths manually if you also want to remove data:"
    echo "  Settings: $SETTINGS"
    echo "  Logs:     $LOGFILE"
    echo "  Updater:  $UPDATELOG"
}

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: Run this script as root (Entware/router admin)."
    exit 1
fi

if [ -d "$LOCKDIR" ]; then
    echo "ERROR: Installer lock exists: $LOCKDIR"
    echo "Make sure no installer/update is running before continuing."
    exit 1
fi

echo "TorrServer Unblock byLampa — maintenance"
echo
echo "1) Roll back the last update"
echo "   Restore the previous binary and init script from backups."
echo
echo "2) Completely uninstall TorrServer"
echo "   Remove the binary and init script; preserve settings and logs."
echo
printf "Select an action [1-2], or anything else to cancel: "
read choice

case "$choice" in
    1)
        confirm "Proceed with rollback" || exit 0
        rollback_installation
        ;;
    2)
        full_uninstall
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

exit $?
```
