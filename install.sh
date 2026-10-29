#!/bin/sh

set -e

REPO="overmaxx-sketch/torrserver-bylampa-unlock"
SERVICE_URL="https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/torrserver.init"

echo "=================================="
echo "TorrServer Bylampa Unlock Installer"
echo "=================================="

# Check Entware
if [ ! -d /opt/bin ]; then
    echo "ERROR: Entware is not installed."
    exit 1
fi

# Check dependencies
for CMD in curl grep awk cut chmod mkdir uname; do
    command -v "$CMD" >/dev/null 2>&1 || {
        echo "ERROR: Missing dependency: $CMD"
        exit 1
    }
done

# Create required directories
mkdir -p /opt/sbin
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/torrserver
mkdir -p /opt/var/log
mkdir -p /opt/var/run

# Detect architecture
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
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Architecture: $ARCH"
echo "Platform: $PLATFORM"

echo "Getting latest release information..."

LATEST_TAG="$(curl -fsSL \
    "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | head -n1 \
    | cut -d '"' -f4)"

if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: Unable to determine latest release."
    exit 1
fi

echo "Latest release: $LATEST_TAG"

# Find release asset
DOWNLOAD_URL="$(curl -fsSL \
    "https://api.github.com/repos/${REPO}/releases/tags/${LATEST_TAG}" \
    | grep browser_download_url \
    | grep "$PLATFORM" \
    | head -n1 \
    | cut -d '"' -f4)"

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ERROR: No binary found for platform $PLATFORM"
    exit 1
fi

echo "Downloading TorrServer..."
curl -fL "$DOWNLOAD_URL" -o /opt/sbin/torrserver

chmod 755 /opt/sbin/torrserver

echo "Installing service..."

curl -fL "$SERVICE_URL" \
    -o /opt/etc/init.d/S99TorrServer

chmod 755 /opt/etc/init.d/S99TorrServer

echo "Starting service..."

/opt/etc/init.d/S99TorrServer restart

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo "=================================="
echo "Installation completed successfully"
echo "=================================="
echo "Version : $LATEST_TAG"
echo "Binary  : /opt/sbin/torrserver"
echo "Service : /opt/etc/init.d/S99TorrServer"

if [ -n "$IP_ADDR" ]; then
    echo "Web UI  : http://$IP_ADDR:8090"
fi

echo
echo "Useful commands:"
echo "/opt/etc/init.d/S99TorrServer status"
echo "/opt/etc/init.d/S99TorrServer restart"
echo "/opt/etc/init.d/S99TorrServer stop"
