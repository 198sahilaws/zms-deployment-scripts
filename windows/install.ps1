<#
.SYNOPSIS
    Zscaler Microsegmentation (ZMS) Enforcer - Provisioning & Installation Script

.DESCRIPTION
    This script automates the provisioning, download, and installation of the Zscaler Microsegmentation Enforcer on Windows Server.
    It performs the following operations:
      1. Writes the provision_key file to a temp staging directory with the user-supplied nonce value
      2. Tests network connectivity to Zscaler download endpoints (production, then beta fallback)
      3. Validates the SSL certificate of the resolved download endpoint
      4. Downloads the ZMS Enforcer MSI installer (eyez-agentmanager-default.msi)
      5. Installs the enforcer silently via msiexec with the PROVISIONKEY_FILE property

    Reference: https://github.com/zscaler/zscaler-microsegmentation/blob/main/deployment/azure/vm-applications/windows/install.ps1

.PARAMETER NonceValue
    The provisioning nonce value obtained from the Zscaler Microsegmentation Console.
    If not provided, the script will prompt for it interactively.

.PARAMETER LogPath
    Path to the script execution log file.
    Default: %TEMP%\ZscalerZMS\zms-install.log

.EXAMPLE
    .\Install-ZscalerMicrosegmentation.ps1
    Runs interactively, prompting for the nonce value.

.EXAMPLE
    .\Install-ZscalerMicrosegmentation.ps1 -NonceValue "4|prod.zpath.net|v2cANh..."
    Runs with the nonce value passed as a parameter.

.NOTES
    Author  : Zscaler Microsegmentation Deployment
    Requires: PowerShell 5.1+, Administrator privileges, Windows Server 2016/2019/2022/2025
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Provisioning nonce value from the ZMS Console")]
    [string]$NonceValue,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $env:TEMP "ZscalerZMS\zms-install.log")
)

# ==============================================================================
# CONFIGURATION
# ==============================================================================
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TEMP_DIR         = Join-Path $env:TEMP "ZscalerZMS"
$PROVISION_KEY    = Join-Path $TEMP_DIR "provision_key"
$MSI_FILENAME     = "eyez-agentmanager-default.msi"
$INSTALLER_PATH   = Join-Path $TEMP_DIR $MSI_FILENAME

$DOWNLOAD_RETRY_COUNT     = 3
$DOWNLOAD_RETRY_DELAY_SEC = 5

# Enforce TLS 1.2 for all web requests in this session
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Zscaler Microsegmentation download endpoints (production first, beta fallback)
$ZMS_ENDPOINTS = @(
    @{
        Name     = "ZPA Production"
        Host     = "eyez-dist.private.zscaler.com"
        Url      = "https://eyez-dist.private.zscaler.com/windows/$MSI_FILENAME"
    },
    @{
        Name     = "ZPA Beta"
        Host     = "eyez-dist.zpabeta.net"
        Url      = "https://eyez-dist.zpabeta.net/windows/$MSI_FILENAME"
    }
)

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes the log file and ensures the log directory exists.
    #>
    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $header = @"
================================================================================
  Zscaler Microsegmentation Enforcer - Provisioning & Installation Log
  Timestamp : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC")
  Computer  : $($env:COMPUTERNAME)
  User      : $($env:USERNAME)
  OS        : $((Get-CimInstance Win32_OperatingSystem).Caption)
  PowerShell: $($PSVersionTable.PSVersion)
================================================================================
"@
    Set-Content -Path $LogPath -Value $header -Encoding UTF8
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to both the console and the log file.
    .PARAMETER Message
        The log message to write.
    .PARAMETER Level
        Log level: INFO, WARN, ERROR, SUCCESS, DEBUG
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"

    # Append to log file
    Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8

    # Console output with color coding
    switch ($Level) {
        "INFO"    { Write-Host $logEntry -ForegroundColor Cyan }
        "WARN"    { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "DEBUG"   { Write-Verbose $logEntry }
    }
}

# ==============================================================================
# PREREQUISITE CHECKS
# ==============================================================================

function Assert-Administrator {
    <#
    .SYNOPSIS
        Verifies the script is running with Administrator privileges.
    #>
    Write-Log "Checking for Administrator privileges..."
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script must be run as Administrator. Please re-launch with elevated privileges." -Level ERROR
        throw "Administrator privileges required."
    }
    Write-Log "Administrator privileges confirmed." -Level SUCCESS
}

function Assert-WindowsServer {
    <#
    .SYNOPSIS
        Verifies the script is running on a supported Windows Server platform.
    #>
    Write-Log "Checking Windows Server platform..."
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "Detected OS: $($os.Caption) (Build $($os.BuildNumber))"

    if ($os.ProductType -eq 1) {
        Write-Log "WARNING: This script is intended for Windows Server platforms. Detected a workstation OS." -Level WARN
        Write-Log "Proceeding anyway, but production deployments should target Windows Server." -Level WARN
    }
    else {
        Write-Log "Windows Server platform confirmed." -Level SUCCESS
    }
}

function Assert-PowerShellVersion {
    <#
    .SYNOPSIS
        Verifies PowerShell version meets minimum requirements.
    #>
    $minVersion = [Version]"5.1"
    $currentVersion = $PSVersionTable.PSVersion
    Write-Log "Checking PowerShell version... Current: $currentVersion, Required: >= $minVersion"

    if ($currentVersion -lt $minVersion) {
        Write-Log "PowerShell $minVersion or higher is required. Current version: $currentVersion" -Level ERROR
        throw "PowerShell version requirement not met."
    }
    Write-Log "PowerShell version requirement met." -Level SUCCESS
}

# ==============================================================================
# STEP 1: CREATE PROVISION_KEY FILE WITH NONCE VALUE
# ==============================================================================

function Get-NonceValue {
    <#
    .SYNOPSIS
        Retrieves the nonce value from the parameter or prompts the user interactively.
    #>
    if ([string]::IsNullOrWhiteSpace($script:NonceValue)) {
        Write-Log "No nonce value provided via parameter. Requesting from user..." -Level INFO
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor White
        Write-Host "  PROVISIONING NONCE VALUE REQUIRED" -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor White
        Write-Host ""
        Write-Host "  Obtain the nonce value from the Zscaler Microsegmentation" -ForegroundColor White
        Write-Host "  Console and paste it below." -ForegroundColor White
        Write-Host ""
        Write-Host "  Example format:" -ForegroundColor Gray
        Write-Host "  4|prod.zpath.net|v2cANhOXQrrx...|288263465653501952|1" -ForegroundColor Gray
        Write-Host ""

        $script:NonceValue = Read-Host -Prompt "Enter the nonce value"

        if ([string]::IsNullOrWhiteSpace($script:NonceValue)) {
            Write-Log "No nonce value provided. Cannot proceed without a valid nonce." -Level ERROR
            throw "Nonce value is required."
        }
    }

    # Trim any leading/trailing whitespace from the nonce
    $script:NonceValue = $script:NonceValue.Trim()
    Write-Log "Nonce value received (length: $($script:NonceValue.Length) characters)." -Level INFO

    # Basic validation: nonce should contain pipe-delimited segments
    $segments = $script:NonceValue.Split("|")
    if ($segments.Count -lt 3) {
        Write-Log "WARNING: Nonce value does not appear to match the expected pipe-delimited format." -Level WARN
        Write-Log "Expected format: <version>|<domain>|<token>|<id>|<flag>" -Level WARN
        Write-Log "Proceeding anyway - verify the nonce value is correct." -Level WARN
    }
    else {
        Write-Log "Nonce validation: $($segments.Count) segments detected, domain=$($segments[1])" -Level INFO
    }
}

function Set-ProvisionKey {
    <#
    .SYNOPSIS
        Creates the provision_key file with the nonce value.
        The file is written with NO preceding or trailing whitespace/newlines.
    #>
    Write-Log "========================================" -Level INFO
    Write-Log "STEP 1: Creating provision_key file" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Log "Target file: $PROVISION_KEY"

    # Ensure the temp staging directory exists
    if (-not (Test-Path -Path $TEMP_DIR)) {
        Write-Log "Creating temp staging directory: $TEMP_DIR"
        New-Item -Path $TEMP_DIR -ItemType Directory -Force | Out-Null
    }

    try {
        # Write the nonce value without any BOM, trailing newline, or extra whitespace
        # Using .NET method to ensure precise control over file content
        # Note: System.Text.Encoding.UTF8 includes a BOM; instantiate UTF8Encoding with $false to suppress it
        [System.IO.File]::WriteAllText($PROVISION_KEY, $script:NonceValue, (New-Object System.Text.UTF8Encoding $false))

        Write-Log "provision_key file created successfully." -Level SUCCESS

        # Verify the file content
        $verifyContent = [System.IO.File]::ReadAllText($PROVISION_KEY)
        if ($verifyContent -eq $script:NonceValue) {
            Write-Log "File content verified - nonce value written correctly (no leading/trailing whitespace)." -Level SUCCESS
        }
        else {
            Write-Log "WARNING: File content verification mismatch. Please inspect the provision_key file manually." -Level WARN
        }

        # Log file metadata
        $fileInfo = Get-Item -Path $PROVISION_KEY
        Write-Log "File size: $($fileInfo.Length) bytes" -Level INFO
    }
    catch {
        Write-Log "Failed to create provision_key: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ==============================================================================
# STEP 2: NETWORK CONNECTIVITY & SSL VALIDATION
# ==============================================================================

function Test-SSLCertificate {
    <#
    .SYNOPSIS
        Tests SSL/TLS connectivity to a given FQDN and logs certificate details.
        Used to detect packet inspection or mTLS issues that may break the agent.
    .PARAMETER Fqdn
        The fully qualified domain name to check.
    .PARAMETER Port
        The port to connect on. Default: 443.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Fqdn,

        [Parameter(Mandatory = $false)]
        [int]$Port = 443
    )

    Write-Log "Running SSL certificate check against ${Fqdn}:${Port}..."
    $tcpSocket = $null
    $sslStream = $null
    try {
        $tcpSocket = New-Object Net.Sockets.TcpClient($Fqdn, $Port)
        $tcpStream = $tcpSocket.GetStream()
        $sslStream = New-Object Net.Security.SslStream($tcpStream, $false)
        # Use SslProtocols (not SecurityProtocolType) as required by AuthenticateAsClient; TLS 1.2 only
        $sslStream.AuthenticateAsClient($Fqdn, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)

        $certInfo = New-Object Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)

        Write-Log "SSL handshake successful to $Fqdn" -Level SUCCESS
        Write-Log "  Protocol   : $($sslStream.SslProtocol)" -Level INFO
        Write-Log "  Subject    : $($certInfo.Subject)" -Level INFO
        Write-Log "  Issuer     : $($certInfo.Issuer)" -Level INFO
        Write-Log "  Thumbprint : $($certInfo.Thumbprint)" -Level INFO
        Write-Log "  Valid From : $($certInfo.NotBefore) to $($certInfo.NotAfter)" -Level INFO

        return $true
    }
    catch {
        Write-Log "SSL certificate check failed for ${Fqdn}: $($_.Exception.Message)" -Level WARN
        Write-Log "This may indicate packet inspection or a proxy intercepting TLS, which will break agent mTLS." -Level WARN
        return $false
    }
    finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpSocket) { $tcpSocket.Close() }
    }
}

function Resolve-DownloadEndpoint {
    <#
    .SYNOPSIS
        Tests connectivity to Zscaler download endpoints (production first, beta fallback)
        and returns the first reachable download URL.
    .OUTPUTS
        The download URL string of the first reachable endpoint.
    #>
    Write-Log "========================================" -Level INFO
    Write-Log "STEP 2: Testing network connectivity" -Level INFO
    Write-Log "========================================" -Level INFO

    $resolvedUrl = ""

    foreach ($endpoint in $ZMS_ENDPOINTS) {
        Write-Log "Testing connection to $($endpoint.Name): $($endpoint.Host):443"
        try {
            $result = Test-NetConnection -ComputerName $endpoint.Host -Port 443 -WarningAction SilentlyContinue
            if ($result.TcpTestSucceeded) {
                Write-Log "TCP connectivity to $($endpoint.Host):443 successful." -Level SUCCESS
                Write-Log "  Remote address : $($result.RemoteAddress)" -Level INFO

                # Run SSL certificate check to detect packet inspection issues
                $sslOk = Test-SSLCertificate -Fqdn $endpoint.Host
                if (-not $sslOk) {
                    Write-Log "SSL validation warning for $($endpoint.Host). Proceeding, but agent mTLS may fail." -Level WARN
                }

                $resolvedUrl = $endpoint.Url
                Write-Log "Resolved download URL: $resolvedUrl" -Level SUCCESS
                break
            }
            else {
                Write-Log "TCP connectivity to $($endpoint.Host):443 failed." -Level WARN
            }
        }
        catch {
            Write-Log "Failed to connect to $($endpoint.Name): $($_.Exception.Message)" -Level WARN
        }
    }

    if ($resolvedUrl -eq "") {
        Write-Log "No download endpoint is reachable." -Level ERROR
        Write-Log "Endpoints tested:" -Level ERROR
        foreach ($endpoint in $ZMS_ENDPOINTS) {
            Write-Log "  - $($endpoint.Host) ($($endpoint.Name))" -Level ERROR
        }
        Write-Log "Verify firewall rules allow outbound HTTPS (port 443) to these hosts." -Level ERROR
        throw "No download URL resolved. Cannot proceed."
    }

    return $resolvedUrl
}

# ==============================================================================
# STEP 3: DOWNLOAD THE MSI INSTALLER
# ==============================================================================

function Get-ZMSInstaller {
    <#
    .SYNOPSIS
        Downloads the Zscaler Microsegmentation Enforcer MSI installer with retry logic.
    .PARAMETER DownloadUrl
        The resolved download URL from the connectivity test.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl
    )

    Write-Log "========================================" -Level INFO
    Write-Log "STEP 3: Downloading ZMS Enforcer MSI" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Log "Source URL : $DownloadUrl"
    Write-Log "Destination: $INSTALLER_PATH"

    # Remove stale installer if present
    if (Test-Path -Path $INSTALLER_PATH) {
        Write-Log "Removing existing installer file: $INSTALLER_PATH" -Level WARN
        Remove-Item -Path $INSTALLER_PATH -Force
    }

    $attempt = 0
    $downloaded = $false

    while (($attempt -lt $DOWNLOAD_RETRY_COUNT) -and (-not $downloaded)) {
        $attempt++
        Write-Log "Download attempt $attempt of $DOWNLOAD_RETRY_COUNT..."

        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $INSTALLER_PATH -UseBasicParsing -ErrorAction Stop

            # Verify the downloaded file
            if (Test-Path -Path $INSTALLER_PATH) {
                $fileInfo = Get-Item -Path $INSTALLER_PATH
                if ($fileInfo.Length -gt 0) {
                    Write-Log "Download completed. File size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -Level SUCCESS
                    $downloaded = $true
                }
                else {
                    Write-Log "Downloaded file is empty (0 bytes). Retrying..." -Level WARN
                    Remove-Item -Path $INSTALLER_PATH -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            Write-Log "Download attempt $attempt failed: $($_.Exception.Message)" -Level WARN
            if ($attempt -lt $DOWNLOAD_RETRY_COUNT) {
                Write-Log "Retrying in $DOWNLOAD_RETRY_DELAY_SEC seconds..." -Level INFO
                Start-Sleep -Seconds $DOWNLOAD_RETRY_DELAY_SEC
            }
        }
    }

    if (-not $downloaded) {
        Write-Log "All $DOWNLOAD_RETRY_COUNT download attempts failed." -Level ERROR
        Write-Log "Please verify:" -Level ERROR
        Write-Log "  - Network/proxy/firewall allows HTTPS to the Zscaler download server" -Level ERROR
        Write-Log "  - TLS 1.2 is supported on this system" -Level ERROR
        Write-Log "  - No packet inspection is breaking the TLS connection" -Level ERROR
        throw "MSI download failed after $DOWNLOAD_RETRY_COUNT attempts."
    }

    # Validate the MSI file signature (basic check: MSI magic bytes)
    # Read only the first 4 bytes via FileStream to avoid loading the full MSI into memory
    try {
        $bytes = [byte[]]::new(4)
        $fs = [System.IO.File]::OpenRead($INSTALLER_PATH)
        try {
            $read = $fs.Read($bytes, 0, 4)
        }
        finally {
            $fs.Dispose()
        }
        # MSI files (OLE Compound Documents) start with D0 CF 11 E0
        if ($read -eq 4 -and
            $bytes[0] -eq 0xD0 -and $bytes[1] -eq 0xCF -and
            $bytes[2] -eq 0x11 -and $bytes[3] -eq 0xE0) {
            Write-Log "MSI file signature validated (OLE Compound Document)." -Level SUCCESS
        }
        else {
            Write-Log "WARNING: File does not have standard MSI header bytes. It may not be a valid MSI." -Level WARN
            Write-Log "First 4 bytes: $($bytes | ForEach-Object { '0x{0:X2}' -f $_ })" -Level WARN
        }
    }
    catch {
        Write-Log "Could not validate MSI file signature: $($_.Exception.Message)" -Level WARN
    }
}

# ==============================================================================
# STEP 4: INSTALL THE MSI
# ==============================================================================

function Install-ZMSEnforcer {
    <#
    .SYNOPSIS
        Installs the Zscaler Microsegmentation Enforcer MSI silently using msiexec,
        passing the provision_key file path as the PROVISIONKEY_FILE property.
    #>
    Write-Log "========================================" -Level INFO
    Write-Log "STEP 4: Installing ZMS Enforcer" -Level INFO
    Write-Log "========================================" -Level INFO

    if (-not (Test-Path -Path $INSTALLER_PATH)) {
        Write-Log "MSI installer not found at: $INSTALLER_PATH" -Level ERROR
        throw "MSI installer file missing. Cannot proceed with installation."
    }

    if (-not (Test-Path -Path $PROVISION_KEY)) {
        Write-Log "provision_key not found at: $PROVISION_KEY" -Level ERROR
        throw "provision_key file missing. Cannot proceed with installation."
    }

    $msiLogFile = Join-Path $TEMP_DIR "msiexec.log"

    # Build the msiexec arguments matching the reference install.ps1
    $Arguments = @(
        "/i"
        "`"$INSTALLER_PATH`""
        "/qn"
        "/l*v"
        "`"$msiLogFile`""
        "PROVISIONKEY_FILE=`"$PROVISION_KEY`""
    )

    Write-Log "MSI installer    : $INSTALLER_PATH"
    Write-Log "Provision key    : $PROVISION_KEY"
    Write-Log "MSI log          : $msiLogFile"
    Write-Log "Executing: msiexec.exe $($Arguments -join ' ')"

    try {
        $process = Start-Process -FilePath "msiexec.exe" `
                                 -ArgumentList $Arguments `
                                 -Wait `
                                 -PassThru `
                                 -NoNewWindow

        $exitCode = $process.ExitCode

        switch ($exitCode) {
            0 {
                Write-Log "MSI installation completed successfully (exit code: 0)." -Level SUCCESS
            }
            3010 {
                Write-Log "MSI installation completed successfully. A reboot is required (exit code: 3010)." -Level WARN
                Write-Log "Please schedule a system reboot at your earliest convenience." -Level WARN
            }
            1603 {
                Write-Log "MSI installation failed with a fatal error (exit code: 1603)." -Level ERROR
                Write-Log "Check the MSI log for details: $msiLogFile" -Level ERROR
                throw "MSI installation failed (exit code: 1603)."
            }
            1618 {
                Write-Log "Another installation is already in progress (exit code: 1618)." -Level ERROR
                Write-Log "Wait for the other installation to finish and retry." -Level ERROR
                throw "MSI installation failed - another install in progress (exit code: 1618)."
            }
            default {
                Write-Log "MSI installation finished with exit code: $exitCode" -Level WARN
                Write-Log "Check the MSI log for details: $msiLogFile" -Level WARN
                if ($exitCode -ne 0) {
                    throw "MSI installation returned non-zero exit code: $exitCode"
                }
            }
        }
    }
    catch [System.InvalidOperationException] {
        Write-Log "Failed to launch msiexec.exe: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ==============================================================================
# SUMMARY
# ==============================================================================

function Write-Summary {
    <#
    .SYNOPSIS
        Outputs a summary of the provisioning and installation to the log and console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedUrl
    )

    $summary = @"

================================================================================
  PROVISIONING & INSTALLATION SUMMARY
================================================================================
  Staging Directory : $TEMP_DIR
  Provision Key     : $PROVISION_KEY
  MSI Installer     : $INSTALLER_PATH
  MSI Log           : $(Join-Path $TEMP_DIR 'msiexec.log')
  Download Source    : $ResolvedUrl
  Script Log        : $LogPath
  Completed At      : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================
"@
    Write-Log $summary -Level SUCCESS
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

try {
    # Initialize logging first (creates staging directory if needed)
    Initialize-Logging

    Write-Log "============================================================" -Level INFO
    Write-Log "  Zscaler Microsegmentation Enforcer - Provisioning Starting" -Level INFO
    Write-Log "============================================================" -Level INFO

    # Prerequisites
    Assert-Administrator
    Assert-WindowsServer
    Assert-PowerShellVersion

    # Step 1: Get nonce and create provision_key
    Get-NonceValue
    Set-ProvisionKey

    # Step 2: Test connectivity to download endpoints (production -> beta fallback)
    $resolvedUrl = Resolve-DownloadEndpoint

    # Step 3: Download the MSI installer
    Get-ZMSInstaller -DownloadUrl $resolvedUrl

    # Step 4: Install the enforcer
    Install-ZMSEnforcer

    # Summary
    Write-Summary -ResolvedUrl $resolvedUrl

    Write-Log "Provisioning and installation completed successfully." -Level SUCCESS
    exit 0
}
catch {
    Write-Log "============================================================" -Level ERROR
    Write-Log "  PROVISIONING FAILED" -Level ERROR
    Write-Log "============================================================" -Level ERROR
    Write-Log "Error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR

    if (Test-Path -Path $LogPath) {
        Write-Log "Review the full log at: $LogPath" -Level ERROR
    }

    exit 1
}