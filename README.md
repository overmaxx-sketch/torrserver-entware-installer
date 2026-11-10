# TorrServer Entware Installer

An installation, update, and maintenance script for **TorrServer Unblock byLampa** on ASUSWRT-Merlin routers and other Linux devices running Entware.

The script automates release selection, binary installation, compatibility adjustments, DNS configuration, service management, watchdog supervision, backup and rollback, and post-installation health checks.

**Tested on:** ASUS RT-AX88U running ASUSWRT-Merlin with Entware installed.

The script is designed to use standard Entware paths and utilities and may work on other Entware-based devices. However, compatibility with platforms other than the tested router has not been confirmed.

## Features

- Fresh installation without requiring an existing TorrServer binary or init script.
- Interactive selection of available TorrServer releases.
- Installation and version switching, including the byLampa-enabled release range starting with version 147.
- Automatic architecture detection and selection of the corresponding binary.
- Optional ELF interpreter patching with `patchelf` when required and supported.
- DNS configuration using the router's local resolver at `127.0.0.1`, rather than directly using WAN-provided DNS server addresses.
- A custom Entware init script, `S90torrserver`, for service management.
- A watchdog that monitors the TorrServer process and attempts to restart it after a crash.
- Go runtime settings intended to help manage CPU concurrency and garbage collection on resource-constrained devices.
- Binary validation before installation and after replacement.
- Backups of the previous binary and init script.
- Automatic rollback attempts when an update fails.
- Preservation of the service's previous running or stopped state during updates.
- HTTP readiness checks after starting or updating the service.
- Dedicated logs for TorrServer and installer operations.
- Log rotation to limit the size of the main TorrServer log.
- A lock to help prevent multiple updater instances from running simultaneously.
- Cleanup of temporary update files after execution.

## Tested environment

| Component | Tested configuration |
|---|---|
| Router | ASUS RT-AX88U |
| Firmware | ASUSWRT-Merlin |
| Package environment | Entware |
| Architecture | AArch64 / ARM64 |
| Tested release | `MatriX.150-bylampa` |
| Default HTTP port | `8090` |

The installation and local HTTP readiness check succeeded on this configuration.

### Compatibility with other Entware devices

The script may also work on other routers, NAS devices, and Linux systems running Entware.

Compatibility depends on:

- CPU architecture and available release binaries.
- The operating environment and system loader.
- C library and ABI compatibility.
- Availability of the required shell utilities.
- Availability of `patchelf` when ELF interpreter adjustment is needed.
- Directory permissions and Entware layout.
- DNS and network configuration.

**Only the ASUS RT-AX88U running ASUSWRT-Merlin with Entware has been confirmed as tested.** Other platforms should be considered potentially compatible, not officially verified.

## TorrServer source

The script downloads TorrServer binaries from the upstream project:

[overmaxx-sketch/torrserver-unblock-bylampa](https://github.com/overmaxx-sketch/torrserver-unblock-bylampa)

This project provides TorrServer builds with byLampa-related changes.

The installer uses the upstream GitHub releases API to discover available versions and their downloadable assets.

## Version selection

The installer provides an interactive menu of available releases instead of always installing a single hard-coded version.

The release range of particular interest begins with **version 147**, associated with the introduction of byLampa blocking-related changes by the upstream developer.

Depending on the available releases and the installer's selection logic, the menu can include the latest release and several previous releases. The exact options may change as new releases are published or older releases become unavailable.

This makes it possible to select a specific available version when a newer release is unsuitable for a particular device or setup.

The installer can also be used to switch to another version available through the selection menu, subject to the installer's validation and recovery logic.

## How the installer works

### 1. Checks dependencies and prepares directories

The installer checks for the required command-line utilities and prepares the directories used for the executable, configuration, logs, and PID files.

It uses a lock directory under `/tmp` to help prevent concurrent updater instances from modifying the installation at the same time.

Temporary download and validation files are kept in a separate working directory and cleaned up when the installer exits normally.

### 2. Detects the architecture and selects a binary

The installer identifies the device architecture and maps it to the upstream binary naming convention.

The upstream project may provide the following targets:

| Architecture | Binary suffix |
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

Actual support depends on the architecture-detection logic and the assets published for the selected release.

Matching the processor architecture does not guarantee that a binary will run on a particular firmware.

### 3. Downloads and validates the candidate binary

The selected binary is downloaded to a temporary location before the existing executable is replaced.

The installer runs the candidate with `--version` to verify that it can start and report its version.

This validation is performed before installation so that an obviously unusable candidate can be rejected without immediately replacing the current executable.

A successful version check is an initial compatibility test, not a complete functional test.

### 4. Attempts ELF interpreter adjustment when necessary

Some Linux binaries require an ELF interpreter path that differs from the one available on the target system.

When appropriate, the installer can attempt to modify the candidate binary's ELF interpreter using `patchelf` and architecture-specific candidate paths.

If `patchelf` is unavailable, the installer logs a warning and proceeds with the available validation path rather than applying an ELF patch.

This mechanism is intended to address certain executable startup problems in constrained Linux environments.

It does **not** guarantee compatibility with every firmware, libc, ABI, or system loader. Changing the ELF interpreter cannot resolve every missing-library or binary compatibility problem.

### 5. Configures DNS

The installer ensures that the TorrServer configuration uses:

```json
{
  "Dns": "127.0.0.1"
}
```

This directs TorrServer to the local loopback address, where the router's local DNS resolver is expected to be available.

The intention is to use the router's DNS handling for client-side name resolution rather than directly configuring TorrServer to use WAN-provided DNS server addresses.

This is useful when the router provides DNS forwarding, filtering, or other DNS behavior to LAN clients.

Actual behavior depends on the router's DNS configuration and firmware. The setting does not itself guarantee encrypted DNS, DNS privacy, or successful resolution of every domain.

### 6. Creates or installs the custom service init script

The installer prepares a custom init script:

`/opt/etc/init.d/S90torrserver`

It validates the generated script before installing it and sets executable permissions.

The script provides commands to start, stop, restart, and check the status of TorrServer and its watchdog.

During an update, the previous init script is backed up when present so that it can be restored if recovery is necessary.

### 7. Applies resource-conscious Go runtime settings

TorrServer is launched with these environment variables:

```sh
GOMAXPROCS=1
GOGC=20
```

These settings influence the Go runtime.

- **`GOMAXPROCS=1`** limits the number of operating-system CPUs that can execute Go code simultaneously. This can reduce CPU concurrency, but may also reduce throughput or increase processing time under load.
- **`GOGC=20`** sets a relatively low garbage collection target compared with Go's default value of 100. This generally causes garbage collection to run more frequently, trading additional GC work for a smaller target amount of newly allocated heap between collections.

These settings are intended to help manage resource usage on routers with limited memory and CPU capacity. They do not impose a strict memory limit and do not guarantee lower total memory consumption in every workload.

More information is available in the official Go documentation:

- [Go runtime environment variables](https://pkg.go.dev/runtime)
- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide)

### 8. Starts and supervises the service

The init script launches TorrServer with its configuration directory and HTTP port:

```sh
/opt/sbin/torrserver -d /opt/etc/torrserver -p 8090
```

The actual service launch also applies the Go runtime environment variables and redirects output to the TorrServer log.

The init script records the process ID in a PID file and starts the watchdog if one is not already running.

### 9. Preserves service state during updates

The installer checks whether TorrServer was running before the update.

- If the service was running, the installer attempts to start the updated service and verify its readiness.
- If the service was stopped, the installer leaves it stopped after a successful update.

During a fresh installation, the installer may attempt to start the service so that the installation can be verified.

This behavior avoids unexpectedly starting a service that the administrator intentionally stopped before performing an update.

### 10. Verifies the installation

After starting the service, the installer performs readiness checks that include the TorrServer process, watchdog, and local HTTP endpoint.

The default HTTP check targets:

`http://127.0.0.1:8090/`

If the updated service fails validation, the installer attempts to roll back to the previous installation when a usable backup is available.

## Custom `S90torrserver` init script

The custom init script manages the TorrServer process and watchdog as a single service.

It supports the following commands:

| Command | Purpose |
|---|---|
| `start` | Start TorrServer and ensure the watchdog is running. |
| `stop` | Stop the watchdog and TorrServer. |
| `restart` | Stop the service and start it again. |
| `status` | Report whether TorrServer and the watchdog are running. |

The script also includes:

- PID file management.
- Startup checks.
- Graceful termination attempts.
- Forced termination if a process does not stop within the configured timeout.
- Timestamped logging.
- Log rotation when the main log reaches approximately 512 KiB.

When the log reaches the configured threshold, the current log is renamed to `torrserver.log.old`. This is a simple single-backup rotation mechanism, not an unlimited log archive.

### Automatic startup after reboot

The init script is installed in Entware's standard init directory. Automatic startup after reboot depends on the Entware startup integration being enabled and correctly configured on the device.

On ASUSWRT-Merlin, verify that Entware init scripts are invoked during boot if you expect TorrServer to start automatically after a router restart.

## Watchdog behavior

The watchdog is a lightweight shell process started by `S90torrserver`.

Its purpose is to detect unexpected termination of TorrServer and attempt to bring the service back without requiring manual intervention.

### Monitoring interval

The watchdog checks the process approximately every **10 seconds**.

It uses the TorrServer PID file and verifies whether the recorded process is still running.

### Automatic restart after a crash

If the TorrServer process has exited:

1. The watchdog removes the stale TorrServer PID file.
2. It increments the restart counter.
3. It writes a crash message to the TorrServer log.
4. It attempts to start TorrServer again using the configured runtime environment.
5. It records the new process ID.

### Restart limit

The watchdog allows up to 10 consecutive automatic restart attempts under its restart-counting logic.

If the restart limit is exceeded, it logs an error, removes its own PID file, and exits rather than continuing an unlimited restart loop.

This helps prevent endless rapid restarts if the executable is broken, incompatible, or unable to start reliably.

### Stability-based counter reset

If TorrServer remains running after a restart, the watchdog tracks its stability.

After approximately **five minutes of stable operation**, the restart counter is reset. This allows the watchdog to recover from a temporary problem without permanently exhausting its restart allowance.

### What the watchdog does not do

The watchdog primarily monitors whether the process is alive. It does not continuously verify every TorrServer function or guarantee that a running process is responsive to HTTP requests.

The installer's post-start health check provides a separate readiness check during installation and updating.

The watchdog also cannot recover from every possible system failure, such as a missing or incompatible binary, insufficient storage, or a broader router outage.

## Installation requirements

Before using the installer, make sure that:

- Entware is installed and working.
- SSH access to the device is available.
- The account has sufficient permissions to write to the required `/opt` directories.
- The device can access GitHub.
- Required command-line utilities are available.
- Port `8090` is available for TorrServer.
- The binary published for the selected architecture is compatible with the target system.

`patchelf` is optional but may be required for ELF interpreter adjustment.

## Installation

Connect to the device via SSH.

### 1. Download the installer

```sh
wget -O /tmp/torrserver-install.sh \
  https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/install.sh
```

### 2. Review the script

```sh
less /tmp/torrserver-install.sh
```

### 3. Check shell syntax

```sh
sh -n /tmp/torrserver-install.sh
```

### 4. Run the installer

```sh
sh /tmp/torrserver-install.sh
```

Follow the on-screen instructions and select the desired release.

> **Security notice:** The installer downloads and replaces executable files, modifies configuration, and manages service processes. Review the script before running it.

## Updating or changing versions

The same installer is intended for fresh installations and updates.

Download the current installer and run it again:

```sh
wget -O /tmp/torrserver-install.sh \
  https://raw.githubusercontent.com/overmaxx-sketch/torrserver-entware-installer/main/install.sh

sh /tmp/torrserver-install.sh
```

Select the required release from the available menu.

The installer attempts to preserve the existing installation and service state. Keep backups until the new version has been verified.

## File locations

| Purpose | Path |
|---|---|
| TorrServer executable | `/opt/sbin/torrserver` |
| Configuration directory | `/opt/etc/torrserver/` |
| Settings file | `/opt/etc/torrserver/settings.json` |
| Custom init script | `/opt/etc/init.d/S90torrserver` |
| TorrServer log | `/opt/var/log/torrserver.log` |
| Previous TorrServer log | `/opt/var/log/torrserver.log.old` |
| Installer/update log | `/opt/var/log/torrserver-update.log` |
| TorrServer PID file | `/opt/var/run/torrserver.pid` |
| Watchdog PID file | `/opt/var/run/torrserver-watchdog.pid` |
| Binary backup | `/opt/etc/torrserver/torrserver.backup` |
| Init script backup | `/opt/etc/init.d/S90torrserver.backup` |

These are the paths used by the installer and generated service script.

## Service management

Start TorrServer:

```sh
/opt/etc/init.d/S90torrserver start
```

Stop TorrServer and its watchdog:

```sh
/opt/etc/init.d/S90torrserver stop
```

Restart both:

```sh
/opt/etc/init.d/S90torrserver restart
```

Check service status:

```sh
/opt/etc/init.d/S90torrserver status
```

The status command reports TorrServer and watchdog state separately, helping identify cases where the main process has exited but the watchdog remains active.

## Web interface

The default HTTP port is `8090`.

Open this address from a device that can access the router:

```text
http://ROUTER-IP-ADDRESS:8090/
```

For example:

```text
http://192.168.1.1:8090/
```

Replace the example address with your router's actual LAN IP address.

Do not expose the TorrServer port to the public internet without appropriate security measures.

## Logs and diagnostics

View the latest TorrServer log entries:

```sh
tail -n 50 /opt/var/log/torrserver.log
```

View installer and update logs:

```sh
tail -n 100 /opt/var/log/torrserver-update.log
```

Check whether the process is running:

```sh
ps | grep '[t]orrserver'
```

Check the local HTTP endpoint:

```sh
wget -O /dev/null http://127.0.0.1:8090/
```

The main TorrServer log includes service startup, shutdown, and watchdog-related messages. The update log records installation progress, validation, backup, rollback, and error messages.

## Backups and rollback

Before replacing an existing installation, the installer creates backups of the previous binary and init script where applicable.

The expected backup locations are:

- `/opt/etc/torrserver/torrserver.backup`
- `/opt/etc/init.d/S90torrserver.backup`

If an update fails, the installer attempts to:

1. Stop the updated service and watchdog.
2. Restore the previous binary and validate it.
3. Restore the previous init script and validate its shell syntax.
4. Restore the original running or stopped state.
5. Verify the restored service if it was previously running.

During a fresh installation, there may be no previous binary or init script to restore. Recovery behavior therefore differs from an ordinary update.

Rollback is best-effort and cannot guarantee recovery from every failure. Keep separate backups of important configuration files.

### Manual configuration backup

```sh
cp -a /opt/etc/torrserver \
  /opt/etc/torrserver.backup
```

Only run this command when the source directory exists.

## Troubleshooting

### TorrServer does not start

Check:

- Whether `/opt/sbin/torrserver` exists and is executable.
- Whether the selected binary matches the architecture.
- Whether the required ELF interpreter and libraries are available.
- Whether the init script reports a startup error.
- The contents of the TorrServer and installer logs.

### The watchdog is running but TorrServer is stopped

Check the logs for repeated crash messages or a restart-limit error.

A running watchdog does not guarantee that TorrServer can start successfully. If the binary is incompatible or the system lacks required resources, the watchdog may eventually stop retrying.

### The web interface is unavailable

Check the process status and test the local HTTP endpoint.

If the endpoint works locally but not from another device, check the router's LAN IP address, firewall rules, and network accessibility.

### DNS resolution does not behave as expected

The installer configures TorrServer to use `127.0.0.1`.

Verify that the router's local DNS resolver is available and correctly forwards queries. Actual behavior depends on the router's firmware and DNS configuration.

### Binary download or validation fails

Check GitHub connectivity, the availability of the requested release asset, and the compatibility of the selected binary.

A successful download does not guarantee that the binary is compatible with the device.

### Rollback fails

Inspect the update log and verify that the backup files exist and are usable. Manual recovery may be necessary if a backup is missing or the previous binary no longer starts.

## Security and limitations

- Review the installer before executing it.
- Download binaries only from the configured upstream repository.
- Do not commit credentials, access tokens, or private configuration to GitHub.
- Do not expose TorrServer to the public internet without suitable protection.
- Keep backups before updating.
- Do not assume that every upstream architecture is supported by the installer on every firmware.
- ELF interpreter patching cannot resolve every ABI or library compatibility issue.
- The watchdog monitors process liveness, not every aspect of service functionality.
- `GOMAXPROCS=1` and `GOGC=20` are tuning parameters, not strict CPU or memory limits.
- Automatic startup after reboot depends on the device's Entware startup integration.

## Repository structure

```text
torrserver-entware-installer/
├── README.md
├── install.sh
├── LICENSE
└── CHANGELOG.md
```

- `README.md` — project description and instructions.
- `install.sh` — installation and update script.
- `LICENSE` — license for the installer's own code.
- `CHANGELOG.md` — optional installer change history.

Choose the installer project's license separately, taking into account the origin of the code and the licenses of third-party components.

## Changelog

For each installer release, consider documenting:

- Installer version and release date.
- Changes to fresh installation and update behavior.
- New release-selection options.
- Binary validation and ELF patching changes.
- DNS configuration changes.
- Init script and watchdog improvements.
- Backup, rollback, and health-check changes.
- Newly tested devices or architectures.

Keep the installer version separate from the TorrServer version.

## Disclaimer

This project is provided **as is**, without warranties of compatibility, reliability, or fitness for a particular purpose.

The installer may modify executable files, configuration, and service state. Back up important data and verify compatibility before relying on it.

TorrServer binaries are provided by the upstream project. This installer is a community utility intended to simplify deployment on Entware-based systems and is not necessarily affiliated with the TorrServer developers.

## Acknowledgements

Thanks to the developers of TorrServer Unblock byLampa, Entware, and ASUSWRT-Merlin for their respective projects and tools.

**Upstream TorrServer project:**  
https://github.com/overmaxx-sketch/torrserver-unblock-bylampa

**Installer repository:**  
https://github.com/overmaxx-sketch/torrserver-entware-installer
