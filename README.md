# Zscaler Microsegmentation (ZMS) Enforcer — Provisioning Scripts

Manual installation scripts for deploying the Zscaler Microsegmentation (ZMS) Enforcer agent on Linux and Windows Server platforms.

## Supported Platforms

| Platform | Script | Package |
|---|---|---|
| Ubuntu (Debian-based) | `Linux/Ubuntu/install.sh` | `.deb` |
| Red Hat Enterprise Linux | `Linux/Redhat/install.sh` | `.rpm` |
| Windows Server | `Windows/install.ps1` | `.msi` |

### Supported Versions

- **Ubuntu:** 16.04.7, 18.04.6, 20.04.6, 22.04.5, 24.04.2, 24.04.3
- **RHEL:** 7.4+ (kernel 3.10.0-693.el7.x86_64 or later), 8.x, 9.x
- **Windows Server:** 2016, 2019, 2022, 2025

## Prerequisites

- A provisioning **nonce value** obtained from the Zscaler Microsegmentation Console
- Outbound HTTPS (port 443) access to `eyez-dist.private.zscaler.com`
- Root/Administrator privileges on the target machine
- **Linux:** `wget` or `curl`, `apt-get` (Ubuntu) or `dnf`/`yum` (RHEL)
- **Windows:** PowerShell 5.1 or later

## Usage

### Ubuntu

```bash
sudo ./install.sh --nonce "4|prod.zpath.net|v2cANh..."
```

Or run without arguments to be prompted interactively:

```bash
sudo ./install.sh
```

### Red Hat Enterprise Linux

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
4. **Download** — Fetches the installer package with retry logic over TLS 1.2
5. **Install** — Installs the agent package silently (`apt-get`, `dnf`/`yum`, or `msiexec`)

## Log Files

| Platform | Log Location |
|---|---|
| Ubuntu / RHEL | `/var/log/zscaler_zms_provision.log` |
| Windows | `%TEMP%\ZscalerZMS\zms-install.log` |

## Network Endpoints

| Environment | Endpoint |
|---|---|
| Production | `eyez-dist.private.zscaler.com` |
| Beta | `eyez-dist.zpabeta.net` |

The Linux scripts target Production by default. The Windows script automatically falls back to the Beta endpoint if Production is unreachable.
