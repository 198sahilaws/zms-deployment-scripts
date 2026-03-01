#!/bin/bash
#===============================================================================
# Zscaler Microsegmentation (ZMS) Enforcer Provisioning Script
# OS:       RHEL (Red Hat Enterprise Linux)
# Usage:    sudo ./install.sh [--nonce <nonce_value>]
# Example:  sudo ./install.sh --nonce "4|prod.zpath.net|v2cANh..."
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
INSTALLER="eyez-agentmanager-default-1.x86_64.rpm"
URL="https://eyez-dist.private.zscaler.com/linux"          # Production
# URL="https://eyez-dist.zpabeta.net/linux"                # Beta
DIR="/opt/zscaler/zms"
LOG_FILE="/var/log/zscaler_zms_provision.log"
PROVISION_KEY_FILENAME="provision_key"
SUPPORTED_MAJOR_VERSIONS="7 8 9"
RHEL7_MIN_MINOR=4                                          # Minimum RHEL 7 minor version
PKG_MANAGER=""                                             # Set during pre-flight (dnf or yum)

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

    # 1. Check OS is RHEL and version is supported

    if [ ! -f /etc/os-release ]; then
        log_error "Cannot determine OS. /etc/os-release not found."
        exit 1
    fi

    # Source os-release for ID and VERSION_ID
    . /etc/os-release

    if [ "${ID:-}" != "rhel" ]; then
        log_error "Unsupported OS: ${PRETTY_NAME:-unknown}."
        log_error "This script requires Red Hat Enterprise Linux. Detected: ${ID:-unknown}."
        exit 1
    fi

    # Extract major version (VERSION_ID is "7", "8", "8.6", "9.3", etc.)
    RHEL_MAJOR_VERSION="$(echo "${VERSION_ID:-}" | cut -d'.' -f1)"

    if [ -z "$RHEL_MAJOR_VERSION" ]; then
        log_error "Could not determine RHEL major version from VERSION_ID='${VERSION_ID:-}'."
        exit 1
    fi

    # Validate major version is in the supported list
    MAJOR_MATCHED=false
    for supported in $SUPPORTED_MAJOR_VERSIONS; do
        if [ "$RHEL_MAJOR_VERSION" = "$supported" ]; then
            MAJOR_MATCHED=true
            break
        fi
    done

    if [ "$MAJOR_MATCHED" = false ]; then
        log_error "==========================================================="
        log_error " UNSUPPORTED RHEL MAJOR VERSION: ${RHEL_MAJOR_VERSION}"
        log_error "==========================================================="
        log_error " Zscaler ZMS Enforcer supports:"
        log_error "   - RHEL 7.4 (kernel 3.10.0-693.el7.x86_64 or later)"
        log_error "   - RHEL 8.x"
        log_error "   - RHEL 9.x"
        log_error " Please re-image to a supported version before running this"
        log_error " script. Aborting."
        log_error "==========================================================="
        exit 1
    fi

    # For RHEL 7, enforce minimum minor version 7.4.
    # /etc/redhat-release is the most reliable source for the full version on RHEL 7
    # since VERSION_ID in os-release typically only contains the major version ("7").
    if [ "$RHEL_MAJOR_VERSION" = "7" ]; then
        RHEL_FULL_VERSION=""

        if [ -f /etc/redhat-release ]; then
            RHEL_FULL_VERSION="$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)"
        fi

        # Fallback: VERSION_ID may already include the minor version (e.g., "7.4")
        if [ -z "$RHEL_FULL_VERSION" ] && echo "${VERSION_ID:-}" | grep -qE '^7\.[0-9]+$'; then
            RHEL_FULL_VERSION="${VERSION_ID}"
        fi

        RHEL_MINOR_VERSION="$(echo "${RHEL_FULL_VERSION:-7.0}" | cut -d'.' -f2)"

        if [ -z "$RHEL_MINOR_VERSION" ] || [ "$RHEL_MINOR_VERSION" -lt "$RHEL7_MIN_MINOR" ]; then
            log_error "==========================================================="
            log_error " UNSUPPORTED RHEL 7 MINOR VERSION: ${RHEL_FULL_VERSION:-unknown}"
            log_error "==========================================================="
            log_error " Zscaler ZMS Enforcer requires RHEL 7.${RHEL7_MIN_MINOR} or later."
            log_error " Detected: RHEL ${RHEL_FULL_VERSION:-7.x (unknown minor version)}"
            log_error " Aborting."
            log_error "==========================================================="
            exit 1
        fi

        log_success "RHEL ${RHEL_FULL_VERSION} is a supported version."
    else
        # RHEL 8 or 9 — any minor version is accepted
        log_success "RHEL ${VERSION_ID:-${RHEL_MAJOR_VERSION}} is a supported version."
    fi

    # 2. Check running as root or with sudo
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run with root/sudo privileges."
        log_error "Re-run as:  sudo $0 ${ORIGINAL_ARGS}"
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
        exit 1
    fi

    # 4. Check dnf (RHEL 8/9) or yum (RHEL 7) is available
    if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        log_success "dnf is available."
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        log_success "yum is available."
    else
        log_error "Neither dnf nor yum found. Cannot install packages."
        exit 1
    fi

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
create_directories() {
    log_info "Creating directory structure: ${DIR}/var"
    mkdir -p "${DIR}/var"
    log_success "Directory created."
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
        if wget -N --secure-protocol=TLSv1_2 --tries=3 \
                --retry-connrefused --retry-on-host-error \
                --directory-prefix="$dest_dir" "$src_url"; then
            log_success "Download complete (wget, TLSv1.2)."
            return 0
        fi

        log_warn "Primary wget attempt failed. Trying fall-back options..."
        if wget -N --tries=3 --directory-prefix="$dest_dir" "$src_url"; then
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
    local rpm_path="/tmp/${INSTALLER}"

    if [ ! -f "$rpm_path" ]; then
        log_error "Package not found at ${rpm_path}. Download may have failed."
        exit 1
    fi

    log_info "Installing RPM package: ${rpm_path} (using ${PKG_MANAGER})"
    if "${PKG_MANAGER}" install -y "$rpm_path"; then
        log_success "Package installed successfully."
    else
        log_error "Failed to install the RPM package."
        log_error "Check the log for details: ${LOG_FILE}"
        exit 1
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# Parse CLI arguments
#-------------------------------------------------------------------------------
NONCE_ARG=""
ORIGINAL_ARGS="$*"

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
    download_file "${URL}/${INSTALLER}" "/tmp"
    install_package

    echo ""
    echo "========================================================================"
    log_success "Zscaler ZMS Enforcer provisioning complete!"
    echo "========================================================================"
    log_info "Log file: ${LOG_FILE}"
    echo ""
}

main
