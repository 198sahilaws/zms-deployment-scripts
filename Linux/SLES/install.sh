#!/bin/bash
#===============================================================================
# Zscaler Microsegmentation (ZMS) Enforcer Provisioning Script
# OS:       SUSE Linux Enterprise Server (SLES 15, SLES 16)
# Agent:    Requires ZMS agent / agent manager 1.11.1 or later
# Usage:    sudo ./install.sh [--nonce <nonce_value>]
# Example:  sudo ./install.sh --nonce "4|prod.zpath.net|v2cANh..."
#
# NOTE ON THE PACKAGE:
#   This script pulls the same el7-built RPM used by the RHEL and Amazon Linux
#   scripts. Zscaler has not published a SLES-specific package name. If the
#   el7 RPM's dependencies do not resolve on SLES (different provides names for
#   glibc/systemd are the usual cause), ask Zscaler for the SLES build and
#   change INSTALLER below - that is the only line that needs to change.
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
INSTALLER="eyez-agentmanager-default-1.el7.x86_64.rpm"
URL="https://eyez-dist.private.zscaler.com/linux"          # Production
# URL="https://eyez-dist.zpabeta.net/linux"                # Beta
DIR="/opt/zscaler/zms"
LOG_FILE="/var/log/zscaler_zms_provision.log"
PROVISION_KEY_FILENAME="provision_key"
STAGE_DIR=""                                               # Private download staging dir (set at runtime)
SUPPORTED_MAJOR_VERSIONS="15 16"

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
init_logging() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir" 2>/dev/null || true

    # Redirect stdout and stderr to both console and log file
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo ""
    echo "========================================================================"
    echo " Zscaler ZMS Provisioning — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "========================================================================"
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"
}

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    # 1. Check OS is SLES and version is supported

    if [ ! -f /etc/os-release ]; then
        log_error "Cannot determine OS. /etc/os-release not found."
        exit 1
    fi

    # Source os-release for ID and VERSION_ID
    . /etc/os-release

    # SLES reports ID="sles"; SLES for SAP reports ID="sles_sap" and is the
    # same base platform, so accept both. openSUSE (ID=opensuse-*) is not
    # a supported platform for the ZMS Enforcer.
    case "${ID:-}" in
        sles|sles_sap)
            ;;
        *)
            log_error "Unsupported OS: ${PRETTY_NAME:-unknown}."
            log_error "This script requires SUSE Linux Enterprise Server. Detected: ${ID:-unknown}."
            exit 1
            ;;
    esac

    # VERSION_ID is "15.5", "15.6", "16.0", etc. Extract the major version.
    SLES_MAJOR_VERSION="$(echo "${VERSION_ID:-}" | cut -d'.' -f1)"

    if [ -z "$SLES_MAJOR_VERSION" ]; then
        log_error "Could not determine SLES major version from VERSION_ID='${VERSION_ID:-}'."
        exit 1
    fi

    # Validate major version is in the supported list
    MAJOR_MATCHED=false
    for supported in $SUPPORTED_MAJOR_VERSIONS; do
        if [ "$SLES_MAJOR_VERSION" = "$supported" ]; then
            MAJOR_MATCHED=true
            break
        fi
    done

    if [ "$MAJOR_MATCHED" = false ]; then
        log_error "==========================================================="
        log_error " UNSUPPORTED SLES MAJOR VERSION: ${SLES_MAJOR_VERSION}"
        log_error "==========================================================="
        log_error " Zscaler ZMS Enforcer supports:"
        log_error "   - SUSE Linux Enterprise Server 15 (all service packs)"
        log_error "   - SUSE Linux Enterprise Server 16"
        log_error " Please re-image to a supported version before running this"
        log_error " script. Aborting."
        log_error "==========================================================="
        exit 1
    fi

    log_success "${PRETTY_NAME:-SLES ${VERSION_ID}} is a supported version."

    # 2. Check running as root or with sudo
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run with root/sudo privileges."
        log_error "Re-run as:  sudo $0 ${REDACTED_ARGS}"
        exit 1
    fi
    log_success "Running with root privileges (UID=$(id -u))."

    # 3. Check that wget or curl is available
    if command -v wget >/dev/null 2>&1; then
        log_success "wget is available."
    elif command -v curl >/dev/null 2>&1; then
        log_success "curl is available."
    else
        log_error "Neither wget nor curl is installed. Install one and re-run."
        log_error "On SLES:  zypper --non-interactive install wget"
        exit 1
    fi

    # 4. Check zypper is available (SLES package manager)
    if ! command -v zypper >/dev/null 2>&1; then
        log_error "zypper not found. This script requires the SUSE package manager."
        exit 1
    fi
    log_success "zypper is available."

    # 5. Check disk space (minimum 500 MB free on /opt)
    local avail_kb
    avail_kb=$(df --output=avail /opt 2>/dev/null | tail -1 | tr -d ' ')
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 512000 ]; then
        log_warn "Low disk space on /opt: $(( avail_kb / 1024 )) MB available (recommended ≥ 500 MB)."
    else
        log_success "Disk space check passed."
    fi

    log_info "Pre-flight checks complete."
    echo ""
}

#-------------------------------------------------------------------------------
# Create required directories
#-------------------------------------------------------------------------------
cleanup_stage() {
    if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
}

create_directories() {
    log_info "Creating directory structure: ${DIR}/var"
    mkdir -p "${DIR}/var"
    log_success "Directory created."

    # Stage the download in a private, unpredictable directory.
    # /tmp is world-writable: downloading to a fixed name there would let any
    # local user pre-plant a package that this script then installs as root.
    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zms-provision.XXXXXXXX")"
    chmod 700 "$STAGE_DIR"
    trap cleanup_stage EXIT
    log_success "Staging directory created: ${STAGE_DIR}"
    echo ""
}

#-------------------------------------------------------------------------------
# Nonce / Provision Key handling
#-------------------------------------------------------------------------------
get_nonce() {
    local nonce_value=""

    # Check if nonce was passed via CLI argument
    if [ -n "${NONCE_ARG:-}" ]; then
        nonce_value="$NONCE_ARG"
        log_info "Nonce value received via CLI argument."
    else
        # Prompt user interactively
        echo ""
        log_info "No nonce provided via --nonce flag. Please enter it now."
        echo "------------------------------------------------------------------------"
        echo " Paste the nonce value provided by the Zscaler ZMS console."
        echo " Example: 4|prod.zpath.net|v2cANhOXQrrx...  (truncated)"
        echo "------------------------------------------------------------------------"
        read -rp "Nonce: " nonce_value
    fi

    # Trim leading/trailing whitespace
    nonce_value="$(echo -n "$nonce_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Validate non-empty
    if [ -z "$nonce_value" ]; then
        log_error "Nonce value cannot be empty."
        exit 1
    fi

    # Basic format validation: expect pipe-delimited segments
    if [[ "$nonce_value" != *"|"* ]]; then
        log_warn "Nonce value does not appear to contain '|' delimiters. Verify the value is correct."
    fi

    NONCE="$nonce_value"
    log_success "Nonce value accepted (length: ${#NONCE} characters)."
    echo ""
}

create_provision_key() {
    local dest_var="${DIR}/var/${PROVISION_KEY_FILENAME}"

    # Write provision_key directly to ZMS var directory
    log_info "Writing provision_key to: ${dest_var}"
    printf '%s' "$NONCE" > "$dest_var"
    chmod 600 "$dest_var"
    log_success "provision_key created at ${dest_var}."
    echo ""
}

#-------------------------------------------------------------------------------
# Network connectivity test
#-------------------------------------------------------------------------------
test_network() {
    local test_host
    test_host="$(echo "$URL" | sed 's|https://||;s|/.*||')"
    log_info "Testing network connectivity to ${test_host}..."

    # Try a lightweight HEAD/connection check
    if command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=10 "https://${test_host}" 2>/dev/null; then
            log_success "Network connectivity verified via wget."
            return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -sf --connect-timeout 10 --max-time 15 -o /dev/null "https://${test_host}"; then
            log_success "Network connectivity verified via curl."
            return 0
        fi
    fi

    log_error "Cannot reach ${test_host}. Check DNS, firewall, and proxy settings."
    exit 1
}

#-------------------------------------------------------------------------------
# Download file
#-------------------------------------------------------------------------------
download_file() {
    local src_url="$1"
    local dest_dir="$2"

    log_info "Downloading: ${src_url}"
    log_info "Destination: ${dest_dir}"

    mkdir -p "$dest_dir"

    if command -v wget >/dev/null 2>&1; then
        log_info "Using wget..."
        if wget --secure-protocol=TLSv1_2 --tries=3 \
                --retry-connrefused --retry-on-host-error \
                --directory-prefix="$dest_dir" "$src_url"; then
            log_success "Download complete (wget, TLSv1.2)."
            return 0
        fi

        log_warn "Primary wget attempt failed. Trying fall-back options..."
        if wget --tries=3 --directory-prefix="$dest_dir" "$src_url"; then
            log_success "Download complete (wget, fall-back)."
            return 0
        fi

        log_error "All wget download attempts failed."

    elif command -v curl >/dev/null 2>&1; then
        log_info "Using curl..."
        if curl --tlsv1.2 --retry 3 \
                --remote-name --create-dirs --output-dir "$dest_dir" "$src_url"; then
            log_success "Download complete (curl, TLSv1.2)."
            return 0
        fi

        log_warn "Primary curl attempt failed. Trying fall-back options..."
        local filename
        filename="$(basename "$src_url")"
        if curl --retry 3 -o "${dest_dir}/${filename}" "$src_url"; then
            log_success "Download complete (curl, fall-back)."
            return 0
        fi

        log_error "All curl download attempts failed."
    else
        log_error "Neither wget nor curl found. Cannot download."
    fi

    exit 1
}

#-------------------------------------------------------------------------------
# Install the RPM package
#-------------------------------------------------------------------------------
install_package() {
    local rpm_path="${STAGE_DIR}/${INSTALLER}"

    if [ ! -f "$rpm_path" ]; then
        log_error "Package not found at ${rpm_path}. Download may have failed."
        exit 1
    fi

    log_info "Installing RPM package: ${rpm_path} (using zypper)"

    # --allow-unsigned-rpm matches the effective behaviour of the RHEL/Amazon
    # Linux scripts, where dnf/yum do not GPG-check a local package by default.
    # Signed packages are still verified.
    if zypper --non-interactive install --allow-unsigned-rpm "$rpm_path"; then
        log_success "Package installed successfully."
    else
        log_error "Failed to install the RPM package."
        log_error "If this failed on unresolved dependencies, the el7-built package"
        log_error "may not be compatible with this SLES release — request the SLES"
        log_error "build from Zscaler and update INSTALLER at the top of this script."
        log_error "Check the log for details: ${LOG_FILE}"
        exit 1
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# Parse CLI arguments
#-------------------------------------------------------------------------------
NONCE_ARG=""
REDACTED_ARGS=""        # Args with the nonce masked - safe to print to console/log

while [ $# -gt 0 ]; do
    case "$1" in
        --nonce|-n)
            if [ -n "${2:-}" ]; then
                NONCE_ARG="$2"
                shift 2
            else
                echo "ERROR: --nonce requires a value." >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: sudo $0 [--nonce <nonce_value>]"
            echo ""
            echo "Options:"
            echo "  --nonce, -n   Provide the ZMS provisioning nonce value."
            echo "  --help,  -h   Show this help message."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Build a log-safe rendering of the arguments (the nonce is a live secret).
if [ -n "$NONCE_ARG" ]; then
    REDACTED_ARGS="--nonce <redacted>"
fi

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    init_logging
    preflight_checks
    create_directories
    get_nonce
    create_provision_key
    test_network
    download_file "${URL}/${INSTALLER}" "$STAGE_DIR"
    install_package

    echo ""
    echo "========================================================================"
    log_success "Zscaler ZMS Enforcer provisioning complete!"
    echo "========================================================================"
    log_info "Log file: ${LOG_FILE}"
    echo ""
}

main
