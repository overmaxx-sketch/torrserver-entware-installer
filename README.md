# TorrServer for ASUSWRT-Merlin / Entware

A script for installing and updating **TorrServer Unblock byLampa** on ASUS routers running ASUSWRT-Merlin with Entware installed.

The script is designed to support both fresh installations and updates of existing TorrServer installations, with service health checks after installation or updating.

## Features

- **Fresh installation** — install TorrServer even if the executable does not already exist.
- **Updates** — download a new TorrServer version from the project's GitHub repository.
- **Version selection** — select an available release from the list provided by the GitHub API.
- **Architecture detection** — select the appropriate binary for the device's processor architecture.
- **Binary validation** — check the downloaded binary before installation.
- **Backup creation** — preserve the previous version and related files before replacing them.
- **Rollback on failure** — restore the previous state if an update fails and a backup is available.
- **Service management** — use an Entware init script to start, stop, and restart TorrServer.
- **Health checks** — verify the local HTTP service after startup.
- **Logging** — maintain a separate log for installation and update operations.
- **Configuration management** — use the configuration file at `/opt/etc/torrserver/settings.json`.
- **Entware compatibility** — use standard `/opt` paths and utilities available in the Entware environment.

## TorrServer source

The script downloads releases from the following project:

https://github.com/overmaxx-sketch/torrserver-unblock-bylampa

The available versions and binaries depend on the releases published by that repository and the availability of a binary compatible with your device.

## Requirements

Before installation, make sure that:

- You have an ASUS router running ASUSWRT-Merlin or a compatible environment.
- Entware is installed and working.
- SSH access to the router is available.
- Your account has sufficient permissions to write to the required `/opt` directories.
- The router can access GitHub to download releases.
- The utilities required by the installer are available in Entware.
- Local HTTP port `8090` is available for TorrServer.

Additional tools or configuration changes may be required depending on the router architecture and firmware.

## Supported architectures

The TorrServer repository may provide binaries for the following architectures:

| Device architecture | Binary suffix |
|---|---|
| ARM64 / AArch64 | `arm64` |
| ARMv7 | `arm7` |
| ARMv6 | `arm6` |
| ARMv5 | `arm5` |
| x86-64 | `amd64` |
| x86 | `386` |
| MIPS | `mips` |
| MIPS little-endian | `mipsle` |
| MIPS64 | `mips64` |
| MIPS64 little-endian | `mips64le` |

Actual compatibility depends not only on the processor architecture but also on the ABI, C library, system loader, and other firmware-specific details.

**The availability of a binary for a particular architecture does not guarantee that it will run on every device using that architecture.** Test compatibility on your own router before relying on the installation.

## Installation

### 1. Connect to your router via SSH

Connect to your router using an account with sufficient permissions to work with Entware.

### 2. Download the installer

Replace `OWNER/REPO` with your GitHub repository name:

```sh
wget -O /tmp/torrserver-install.sh \
  https://raw.githubusercontent.com/OWNER/REPO/main/install.sh
```

If your repository uses a different default branch, replace `main` with the appropriate branch name.

### 3. Review the script

Before running the installer, you can inspect its contents:

```sh
less /tmp/torrserver-install.sh
```

You can also check its shell syntax:

```sh
sh -n /tmp/torrserver-install.sh
```

### 4. Run the installer

```sh
sh /tmp/torrserver-install.sh
```

Follow the installer's instructions and select the desired release if prompted.

> **Important:** Only run the installer after reviewing its contents. It downloads and replaces executable files, may modify configuration files, and can manage the TorrServer service.

## Updating TorrServer

Use the same installer for both fresh installations and updates.

Download the latest version of `install.sh` from your repository and run it:

```sh
wget -O /tmp/torrserver-install.sh \
  https://raw.githubusercontent.com/OWNER/REPO/main/install.sh

sh /tmp/torrserver-install.sh
```

The remaining steps depend on the installer's implementation and the release you select.

Before updating, it is recommended that you back up your TorrServer configuration and any other important files.

## File locations

The default paths are:

| Purpose | Path |
|---|---|
| TorrServer executable | `/opt/sbin/torrserver` |
| Configuration file | `/opt/etc/torrserver/settings.json` |
| Service init script | `/opt/etc/init.d/S90torrserver` |
| TorrServer log | `/opt/var/log/torrserver.log` |
| Installer and update log | `/opt/var/log/torrserver-update.log` |
| TorrServer PID file | `/opt/var/run/torrserver.pid` |
| Watchdog PID file | `/opt/var/run/torrserver-watchdog.pid` |

The actual paths may vary depending on the version of the script.

## Service management

If the installer created `/opt/etc/init.d/S90torrserver`, you can manage the service using the following commands.

Start:

```sh
/opt/etc/init.d/S90torrserver start
```

Stop:

```sh
/opt/etc/init.d/S90torrserver stop
```

Restart:

```sh
/opt/etc/init.d/S90torrserver restart
```

Check status:

```sh
/opt/etc/init.d/S90torrserver status
```

Support for the `status` command depends on the implementation of the init script.

## Web interface

By default, TorrServer uses port `8090`.

If the service and network are configured correctly, the web interface should be accessible at:

```text
http://ROUTER-IP-ADDRESS:8090/
```

For example, if your router's IP address is `192.168.1.1`:

```text
http://192.168.1.1:8090/
```

If the interface is unavailable, verify your router's IP address and network configuration.

Do not expose the TorrServer port to the public internet without understanding the security implications and implementing appropriate protection.

## Health checks

To test the local HTTP endpoint on the router, you can use `wget` if it is installed:

```sh
wget -O /dev/null http://127.0.0.1:8090/
```

You can also check whether the process is running:

```sh
ps | grep '[t]orrserver'
```

View the latest TorrServer log entries:

```sh
tail -n 50 /opt/var/log/torrserver.log
```

View the installer log:

```sh
tail -n 100 /opt/var/log/torrserver-update.log
```

A successful HTTP response confirms that the local HTTP endpoint is responding. It does not necessarily guarantee that every TorrServer feature is working correctly.

## Configuration

The configuration file is located at:

```text
/opt/etc/torrserver/settings.json
```

Before editing it manually, create a backup:

```sh
cp /opt/etc/torrserver/settings.json \
   /opt/etc/torrserver/settings.json.bak
```

If the configuration file does not exist, automatic creation depends on the installer version.

Avoid replacing existing settings unnecessarily, as this may remove your custom configuration.

## Backups and recovery

Before updating, you can back up the configuration directory:

```sh
cp -a /opt/etc/torrserver \
      /opt/etc/torrserver.backup
```

You can also back up the current executable:

```sh
cp -p /opt/sbin/torrserver \
      /opt/sbin/torrserver.backup
```

These commands assume that the source files already exist. During a fresh installation, some or all of them may be absent.

If an update fails, inspect the installer log:

```sh
tail -n 100 /opt/var/log/torrserver-update.log
```

If the installer created a backup and implements automatic rollback, it may restore the previous version. Keep your backups until you have confirmed that the updated service works correctly.

## Troubleshooting

### TorrServer does not start

Check the following:

1. Verify that `/opt/sbin/torrserver` exists.
2. Make sure the file has executable permissions.
3. Check whether the service starts through the init script.
4. Review `/opt/var/log/torrserver.log` for errors.
5. Verify that the binary is compatible with your router's architecture and system environment.

### The web interface is unavailable

Check whether the process is running:

```sh
ps | grep '[t]orrserver'
```

Then test the local endpoint:

```sh
wget -O /dev/null http://127.0.0.1:8090/
```

If the local request works but the interface cannot be accessed from other devices, check the router's IP address, network configuration, firewall rules, and port accessibility.

### Release download fails

Possible causes include:

- Temporary GitHub unavailability.
- DNS or internet connectivity issues.
- No binary available for the required architecture.
- Access restrictions affecting GitHub.
- A failed download or corrupted file.

Check the installer log and try again when the connection is available.

### The binary does not run

A successfully downloaded binary may still be incompatible with the firmware. Check the architecture, system loader, ABI, and required libraries.

Do not modify the ELF interpreter path without verifying compatibility. Changing the loader path does not make an otherwise incompatible binary compatible.

### An update fails

Do not delete your backups. Review the installer log and check the state of the executable and service. If automatic rollback does not work, manual recovery may be necessary.

## Security

- Use the installer only from a trusted repository.
- Review `install.sh` before executing it.
- Do not commit passwords, access tokens, or private configuration data to the repository.
- Do not expose the TorrServer port to the public internet without appropriate protection.
- Keep backups before updating.
- A successful download does not guarantee that a binary is safe or compatible.

## Repository structure

A minimal repository layout is recommended:

```text
torrserver-entware/
├── README.md
├── install.sh
├── LICENSE
└── CHANGELOG.md
```

File descriptions:

- `README.md` — project overview and installation instructions.
- `install.sh` — TorrServer installation and update script.
- `LICENSE` — license for the installer itself.
- `CHANGELOG.md` — installer change history, if maintained.

Choose a license for your installer separately, taking into account the origin of the code and the licenses of any components you use.

## Changelog

You can maintain the installer's history in `CHANGELOG.md` or through GitHub Releases.

It is recommended to document:

- Installer version.
- Release date.
- Bug fixes.
- Changes to installation and rollback logic.
- Changes to supported architectures.
- Changes to Entware or firmware requirements.

The installer version should be tracked separately from the TorrServer version.

## Disclaimer

This project is provided **“as is”**, without guarantees of error-free operation or compatibility with every device.

Using the script may interrupt the service, modify configuration files, or require manual recovery. Back up important files and test the installer on your own configuration before relying on it.

TorrServer and its associated binaries are distributed by their respective authors. This repository is intended to simplify installation and updating and is not necessarily affiliated with the TorrServer authors.

## Acknowledgements

Thanks to the developers of TorrServer Unblock byLampa, Entware, and ASUSWRT-Merlin for their respective projects and tools.

**TorrServer release source:**  
https://github.com/overmaxx-sketch/torrserver-unblock-bylampa
