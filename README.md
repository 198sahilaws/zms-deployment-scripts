# Zscaler Microsegmentation (ZMS) Enforcer — Provisioning Scripts

Manual installation scripts for deploying the Zscaler Microsegmentation (ZMS) Enforcer agent on Linux and Windows Server platforms.

## Supported Platforms

| Platform | Script | Package |
|---|---|---|
| Ubuntu (Debian-based) | `Linux/Ubuntu/install.sh` | `.deb` |
| Red Hat Enterprise Linux | `Linux/Redhat/install.sh` | `.rpm` |
| SUSE Linux Enterprise Server | `Linux/SLES/install.sh` | `.rpm` |
| Amazon Linux | `Linux/AmazonLinux/install.sh` | `.rpm` |
| Windows Server | `windows/install.ps1` | `.msi` |

### Supported Versions

- **Ubuntu:** 16.04.7, 18.04.6, 20.04.6, 22.04.5, 24.04.2, 24.04.3, 24.04.4, 26.04.2
- **RHEL:** 7.4+ (kernel 3.10.0-693.el7.x86_64 or later), 8.x, 9.x
- **SLES:** 15 (all service packs), 16 — requires ZMS agent / agent manager **1.11.1** or later
- **Amazon Linux:** Amazon Linux 2, Amazon Linux 2023
- **Windows Server:** 2016, 2019, 2022, 2025

> **SLES packaging note:** the SLES script pulls the same el7-built RPM used by the RHEL and Amazon Linux scripts, since Zscaler has not published a SLES-specific package name. If dependency resolution fails on SLES, request the SLES build from Zscaler and update the `INSTALLER` constant at the top of `Linux/SLES/install.sh` — that is the only line that needs to change.

## Prerequisites

- A provisioning **nonce value** obtained from the Zscaler Microsegmentation Console
- Outbound HTTPS (port 443) access to `eyez-dist.private.zscaler.com`
- Root/Administrator privileges on the target machine
- **Linux:** `wget` or `curl`, plus the platform package manager — `apt-get` (Ubuntu), `dnf`/`yum` (RHEL, Amazon Linux), `zypper` (SLES)
- **Windows:** PowerShell 5.1 or later

## Usage

### Ubuntu / RHEL / SLES / Amazon Linux

All four Linux scripts take the same arguments:

```bash
sudo ./install.sh --nonce "4|prod.zpath.net|v2cANh..."
```

Or run without arguments to be prompted interactively:

```bash
sudo ./install.sh
```

### Windows Server

Run from an elevated PowerShell session:

```powershell
.\install.ps1 -NonceValue "4|prod.zpath.net|v2cANh..."
```

Or run without arguments to be prompted interactively:

```powershell
.\install.ps1
```

## What the Scripts Do

Each script performs the following steps:

1. **Pre-flight checks** — Validates OS version, privileges, required tools, and available disk space
2. **Provision key creation** — Writes the nonce value to `/opt/zscaler/zms/var/provision_key` (Linux) or a temp staging directory (Windows)
3. **Network test** — Verifies HTTPS connectivity to the Zscaler download endpoint; Windows also validates the SSL certificate
4. **Download** — Fetches the installer package with retry logic over TLS 1.2, into a private staging directory that is removed on exit (Linux)
5. **Install** — Installs the agent package silently (`apt-get`, `dnf`/`yum`, `zypper`, or `msiexec`)

The nonce is a live secret: the Linux scripts write it to `provision_key` with `0600` permissions and never echo its value to the console or log.

## Log Files

| Platform | Log Location |
|---|---|
| Linux (all) | `/var/log/zscaler_zms_provision.log` |
| Windows | `%TEMP%\ZscalerZMS\zms-install.log` |

## Network Endpoints

| Environment | Endpoint |
|---|---|
| Production | `eyez-dist.private.zscaler.com` |
| Beta | `eyez-dist.zpabeta.net` |

The Linux scripts target Production by default; switch by editing the `URL` constant at the top of the script. The Windows script automatically falls back to the Beta endpoint if Production is unreachable.

## Line Endings

The `.sh` scripts must check out with LF endings — a CRLF checkout fails on Linux with `/bin/bash^M: bad interpreter`. This is enforced by `.gitattributes`; do not override it when editing on Windows.
