#!/bin/sh

PIDFILE=/opt/var/run/torrserver.pid
WDPID=/opt/var/run/torrserver-watchdog.pid

echo "=================================="
echo "TorrServer Uninstaller"
echo "=================================="

echo "Stopping service..."

if [ -x /opt/etc/init.d/S99TorrServer ]; then
    /opt/etc/init.d/S99TorrServer stop 2>/dev/null || true
fi

# watchdog
if [ -f "$WDPID" ]; then
    kill "$(cat "$WDPID" 2>/dev/null)" 2>/dev/null || true
    rm -f "$WDPID"
fi

# torrserver
if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PIDFILE"
fi

sleep 2

# emergency cleanup
killall torrserver 2>/dev/null || true

rm -f /opt/etc/init.d/S99TorrServer
rm -f /opt/sbin/torrserver

echo
echo "TorrServer removed."

echo
echo "Preserved:"
echo "  /opt/etc/torrserver"
echo "  /opt/var/log/torrserver.log"
echo "  /opt/var/log/torrserver.log.old"

echo
echo "If you want full cleanup, remove manually:"
echo "rm -rf /opt/etc/torrserver"
echo "rm -f /opt/var/log/torrserver.log*"
