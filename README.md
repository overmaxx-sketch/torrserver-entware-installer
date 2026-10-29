TorrServer Bylampa Unlock Installer
One-command installer for TorrServer builds from the Bylampa-unlocked fork.

This project automatically installs and maintains the latest release from:

https://github.com/overmaxx-sketch/torrserver-bylampa-unlock

Features
Automatic installation of the latest TorrServer release
Uses Bylampa-unlocked builds
Architecture auto-detection
Entware support
ASUSWRT-Merlin support
Automatic startup via Entware init script
Built-in watchdog
Automatic crash recovery
Log rotation
Easy upgrade
Easy removal
Supported Architectures
ARM64 (aarch64)
ARMv7
ARMv5
x86_64
Requirements
Entware installed
curl
wget (optional)
Installation
Run:

curl -fsSL https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/install.sh | sh

or

wget -qO- https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/install.sh | sh

Service Management
Status:
/opt/etc/init.d/S99TorrServer status

Start:
/opt/etc/init.d/S99TorrServer start

Stop:
/opt/etc/init.d/S99TorrServer stop

Restart:
/opt/etc/init.d/S99TorrServer restart

Uninstall
curl -fsSL https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/uninstall.sh | sh

Source Project
https://github.com/overmaxx-sketch/torrserver-bylampa-unlock

Disclaimer
This project is not affiliated with the official TorrServer project. It only provides automated installation of releases built from a personal fork.
