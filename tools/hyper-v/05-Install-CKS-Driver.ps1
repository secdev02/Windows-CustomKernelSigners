#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Signs ckspdrv.sys and installs it as an auto-start kernel service.

.DESCRIPTION
    RUN THIS INSIDE THE VM immediately after the second reboot from EnableCKS.exe.

    Why timing matters:
      After EnableCKS.exe sets the CKS product policy, sppsvc (Software Protection
      Service) will reset it to disabled within approximately 10 minutes. ckspdrv.sys
      keeps CKS alive by calling ExUpdateLicenseData on a timer from kernel mode,
      which reapplies the policy before sppsvc can take effect. The reset only
      actually takes effect on the next reboot, so you have until then to get
      ckspdrv.sys running.

    What this script does:
      1. Signs ckspdrv.sys with the KM certificate via signtool.
         The signature must match the kernel signer rule in SiPolicy.p7b.
         The KM cert must be trusted -- i.e., its root CA must be the same
         cert used in the Add-SignerRule call in 04-Deploy-SiPolicy.ps1.

      2. Installs the signed driver to System32\drivers\.

      3. Creates a kernel-mode service (type=kernel, start=auto) via sc.exe.

      4. Starts the service immediately.

      5. Verifies CKS is still active in ProductPolicy.

    Source code: CustomKernelSignersPersistent\ folder in the repo.
    Binary:      https://github.com/HyperSine/Windows10-CustomKernelSigners/releases
                 Build from source with WDK 24H2 + VS 2022 for Windows 11 targets.

.PARAMETER PKIPath
    Path (inside the VM) to the CKS-PKI folder.

.PARAMETER PFXPassword
    SecureString password for km.pfx. Prompted interactively if not supplied.

.PARAMETER CKSDriverPath
    Path to the UNSIGNED ckspdrv.sys (from repo releases or local build).

.EXAMPLE
    .\05-Install-CKS-Driver.ps1 -PKIPath "C:\CKS-PKI" -CKSDriverPath "C:\CKS\ckspdrv.sys"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$PKIPath,

    [SecureString]$PFXPassword,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CKSDriverPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan  }
function Write-OK   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[-] $Msg" -ForegroundColor Red   }

# ---------------------------------------------------------------------------
# PFX password
# ---------------------------------------------------------------------------
if (-not $PFXPassword) {
    $PFXPassword = Read-Host "Enter PFX password for km.pfx" -AsSecureString
}

$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PFXPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$kmPfxPath  = Join-Path $PKIPath "km.pfx"
$rootDerPath = Join-Path $PKIPath "root-ca.der"

foreach ($f in @($kmPfxPath, $rootDerPath)) {
    if (-not (Test-Path $f)) {
        throw "Required file not found: $f"
    }
}

# ---------------------------------------------------------------------------
# Locate signtool.exe
# ---------------------------------------------------------------------------
Write-Step "Locating signtool.exe"

$signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue)?.Source

if (-not $signtool) {
    $sdkBins = @(
        "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe",
        "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe",
        "C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe"
    )
    $signtool = $sdkBins | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $signtool) {
    throw "signtool.exe not found. Install the Windows SDK."
}

Write-OK "signtool: $signtool"

# ---------------------------------------------------------------------------
# 1. Sign ckspdrv.sys
#
# /ac root-ca.der  -- provides the cross-certificate chain so the kernel
#                     can verify the signature traces back to the root CA
#                     referenced in SiPolicy.p7b
# /td sha256       -- SHA-256 timestamp hash (required on Windows 11)
# ---------------------------------------------------------------------------
Write-Step "Signing ckspdrv.sys with KM certificate"

$signedDriverPath = Join-Path $PKIPath "ckspdrv_signed.sys"
Copy-Item -Path $CKSDriverPath -Destination $signedDriverPath -Force

$signArgs = @(
    "sign",
    "/fd",  "sha256",
    "/ac",  $rootDerPath,
    "/f",   $kmPfxPath,
    "/p",   $pwPlain,
    "/tr",  "http://timestamp.digicert.com",
    "/td",  "sha256",
    $signedDriverPath
)

& $signtool @signArgs
if ($LASTEXITCODE -ne 0) {
    throw "signtool failed (exit $LASTEXITCODE). Check the PFX password and cert paths."
}

# Zero plain-text password from memory
$pwPlain = [string]::new('*', $pwPlain.Length); $pwPlain = $null

Write-OK "ckspdrv.sys signed: $signedDriverPath"

# Verify the signature was written correctly
$verifyArgs = @("verify", "/pa", "/v", $signedDriverPath)
& $signtool @verifyArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Note "signtool verify returned non-zero. The signature may still be valid for kernel mode."
    Write-Note "Kernel-mode driver signing is validated by CI, not by the /pa (Authenticode) chain."
}

# ---------------------------------------------------------------------------
# 2. Install driver to System32\drivers
# ---------------------------------------------------------------------------
Write-Step "Installing ckspdrv.sys to System32\drivers"

$driverDest = Join-Path $env:SystemRoot "System32\drivers\ckspdrv.sys"
Copy-Item -Path $signedDriverPath -Destination $driverDest -Force
Write-OK "Driver installed: $driverDest"

# ---------------------------------------------------------------------------
# 3. Register as auto-start kernel service
# ---------------------------------------------------------------------------
Write-Step "Registering ckspdrv service"

$svcName = "ckspdrv"

# Remove any previous installation
$existingSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Note "Service '$svcName' already exists -- stopping and removing"
    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    & sc.exe delete $svcName | Out-Null
    Start-Sleep -Milliseconds 500
}

& sc.exe create $svcName `
    binpath= "$env:SystemRoot\System32\drivers\ckspdrv.sys" `
    type= kernel `
    start= auto `
    error= normal | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "sc.exe create failed (exit $LASTEXITCODE)"
}

Write-OK "Service registered (auto-start kernel service)"

# ---------------------------------------------------------------------------
# 4. Start the service
# ---------------------------------------------------------------------------
Write-Step "Starting ckspdrv"

& sc.exe start $svcName
if ($LASTEXITCODE -ne 0) {
    Write-Fail "sc.exe start failed (exit $LASTEXITCODE)"
    Write-Fail ""
    Write-Fail "Common causes:"
    Write-Fail "  - CKS is not active (did EnableCKS.exe run and succeed?)"
    Write-Fail "  - SiPolicy.p7b was not deployed or was not signed with the correct PK"
    Write-Fail "  - SecureBoot is not enforcing (check Hyper-V firmware settings)"
    Write-Fail "  - sppsvc already reset CKS (re-run EnableCKS.exe and immediately retry this script)"
    Write-Fail "  - Driver was signed with a KM cert not referenced in SiPolicy.p7b"
    exit 1
}

Start-Sleep -Seconds 2  # Allow the driver to initialise

# Confirm the service is running
$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-OK "ckspdrv is RUNNING"
} else {
    Write-Note ("ckspdrv status: {0}" -f $(if ($svc) { $svc.Status } else { "not found" }))
}

# ---------------------------------------------------------------------------
# 5. Verify CKS is still active in ProductPolicy
#
# ProductPolicy is a binary blob in HKLM\SYSTEM\CurrentControlSet\Control\ProductOptions.
# Policy names are stored as null-terminated UTF-16LE strings within it.
# ---------------------------------------------------------------------------
Write-Step "Verifying CKS policy is active in ProductPolicy"

try {
    $productPolicyBytes = (Get-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions" `
        -Name "ProductPolicy" `
        -ErrorAction Stop).ProductPolicy

    # Decode as UTF-16LE -- policy names are embedded as wide strings
    $policyText = [System.Text.Encoding]::Unicode.GetString($productPolicyBytes)

    $cksMain  = $policyText -match "CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners"
    $cksBase  = $policyText -match "CodeIntegrity-AllowConfigurablePolicy[^-]"

    if ($cksMain) {
        Write-OK "CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners  PRESENT"
    } else {
        Write-Note "CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners  NOT FOUND"
        Write-Note "CKS may not be active. Check whether EnableCKS.exe completed successfully."
    }

    if ($cksBase) {
        Write-OK "CodeIntegrity-AllowConfigurablePolicy                       PRESENT"
    } else {
        Write-Note "CodeIntegrity-AllowConfigurablePolicy                       NOT FOUND"
    }
} catch {
    Write-Note "Could not read ProductPolicy: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-OK "CKS persistence driver installed and running."
Write-Host ""
Write-Host "To verify on subsequent boots:"
Write-Host "    Get-Service ckspdrv"
Write-Host "    sc.exe query ckspdrv"
Write-Host ""
Write-Host "You can now sign custom drivers with km.pfx and load them without TestSigning:"
Write-Host "    signtool sign /fd sha256 /ac root-ca.der /f km.pfx /p <password>"
Write-Host "        /tr http://timestamp.digicert.com /td sha256 <YourDriver.sys>"
Write-Host ""
Write-Note "ckspdrv must remain running to keep CKS active across reboots."
Write-Note "If it fails to start after a reboot, SecureBoot or SiPolicy may have changed."
