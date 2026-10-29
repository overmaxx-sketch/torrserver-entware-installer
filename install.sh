#!/bin/sh

set -e

REPO="overmaxx-sketch/torrserver-bylampa-unlock"
INIT_URL="https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/torrserver.init"

echo "=================================="
echo "TorrServer Bylampa Unlock Installer"
echo "=================================="

# Entware check
if [ ! -d /opt/bin ]; then
    echo "ERROR: Entware is not installed."
    exit 1
fi

# Dependencies check
for CMD in curl grep awk cut chmod mkdir uname; do
    command -v "$CMD" >/dev/null 2>&1 || {
        echo "ERROR: Missing dependency: $CMD"
        exit 1
    }
done

mkdir -p /opt/sbin
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/torrserver
mkdir -p /opt/var/run
mkdir -p /opt/var/log

ARCH="$(uname -m)"

case "$ARCH" in
    aarch64)
        PLATFORM="linux_arm64"
        ;;
    armv7l|armv7*)
        PLATFORM="linux_arm7"
        ;;
    arm*)
        PLATFORM="linux_arm5"
        ;;
    x86_64)
        PLATFORM="linux_amd64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Detected architecture: $ARCH"

LATEST_TAG="$(curl -fsSL \
"https://api.github.com/repos/${REPO}/releases/latest" \
| grep '"tag_name"' \
| head -n1 \
| cut -d '"' -f4)"

if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: Failed to get latest release."
    exit 1
fi

echo "Latest release: $LATEST_TAG"

DOWNLOAD_URL="$(curl -fsSL \
"https://api.github.com/repos/${REPO}/releases/tags/${LATEST_TAG}" \
| grep browser_download_url \
| grep "$PLATFORM" \
| head -n1 \
| cut -d '"' -f4)"

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ERROR: Release asset not found for $PLATFORM"
    exit 1
fi

echo "Downloading binary..."
curl -fL "$DOWNLOAD_URL" -o /opt/sbin/torrserver

chmod 755 /opt/sbin/torrserver

echo "Installing init script..."
curl -fL "$INIT_URL" -o /opt/etc/init.d/S99TorrServer

chmod 755 /opt/etc/init.d/S99TorrServer

echo "Starting TorrServer..."
/opt/etc/init.d/S99TorrServer restart

echo
echo "=================================="
echo "Installation completed"
echo "=================================="
echo
echo "Check status:"
echo "/opt/etc/init.d/S99TorrServer status"
echo
