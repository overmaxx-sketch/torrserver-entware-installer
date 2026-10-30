#!/bin/sh

set -e

REPO="overmaxx-sketch/torrserver-bylampa-unlock"

echo "Installing TorrServer Bylampa Unlock..."

for CMD in curl grep awk; do
    command -v $CMD >/dev/null || {
        echo "$CMD not found"
        exit 1
    }
done

mkdir -p /opt/sbin
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/torrserver

ARCH="$(uname -m)"

case "$ARCH" in
    aarch64)
        ASSET="linux-arm64"
        ;;
    armv7l)
        ASSET="linux-arm7"
        ;;
    arm*)
        ASSET="linux-arm5"
        ;;
    x86_64)
        ASSET="linux-amd64"
        ;;
    *)
        echo "Unsupported CPU: $ARCH"
        exit 1
        ;;
esac

TAG=$(
curl -s \
https://api.github.com/repos/${REPO}/releases/latest \
| grep tag_name \
| cut -d '"' -f4
)

echo "Latest release: $TAG"

URL=$(
curl -s \
https://api.github.com/repos/${REPO}/releases/tags/${TAG} |
grep browser_download_url |
grep "$ASSET" |
head -n1 |
cut -d '"' -f4
)

curl -L "$URL" -o /opt/sbin/torrserver

chmod +x /opt/sbin/torrserver

curl -L \
https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware/main/torrserver.init \
-o /opt/etc/init.d/S99TorrServer

chmod +x /opt/etc/init.d/S99TorrServer

/opt/etc/init.d/S99TorrServer restart

echo
echo "TorrServer installed."
echo "Web interface:"
echo "http://$(hostname -I | awk '{print $1}'):8090"
