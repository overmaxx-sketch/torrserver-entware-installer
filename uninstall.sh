#!/bin/sh

echo "=================================="
echo "TorrServer Uninstaller"
echo "=================================="

if [ -f /opt/etc/init.d/S99TorrServer ]; then
    /opt/etc/init.d/S99TorrServer stop 2>/dev/null || true
fi

rm -f /opt/etc/init.d/S99TorrServer
rm -f /opt/sbin/torrserver
rm -f /opt/var/run/torrserver.pid
rm -f /opt/var/run/torrserver-watchdog.pid

echo
echo "TorrServer has been removed."

echo
echo "Configuration preserved:"
echo "/opt/etc/torrserver"

echo
echo "Logs preserved:"
echo "/opt/var/log/torrserver.log"
echo "/opt/var/log/torrserver.log.old"
