#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Generates SiPolicy, signs it with the PK cert, deploys it to the EFI
    partition, and schedules EnableCKS.exe to run via Setup Mode on next boot.

.DESCRIPTION
    RUN THIS INSIDE THE VIRTUAL MACHINE after SecureBoot has been enabled.

    Steps performed:

      1. Generate SiPolicy.xml using New-CIPolicy (scans System32).
         Requires Windows 11 Enterprise or Education. On other editions,
         use -SkipPolicyGeneration and supply a pre-existing SiPolicy.xml.
         The repo ships one at: asset/SiPolicy.xml

      2. Add the KM certificate as a kernel signer rule via Add-SignerRule.

      3. Compile to binary SiPolicy.bin via ConvertFrom-CIPolicy.

      4. Sign SiPolicy.bin with the PK certificate using signtool.
         The UEFI firmware validates this signature against the enrolled PK
         before honouring the policy.
         Produces SiPolicy.bin.p7, renamed to SiPolicy.p7b.

      5. Mount the EFI System Partition and copy SiPolicy.p7b to
         EFI\Microsoft\Boot\

      6. Write HKLM\SYSTEM\Setup CmdLine and SetupType to schedule
         EnableCKS.exe to run during the next Setup Mode boot.
         EnableCKS.exe enables the two product policies:
           CodeIntegrity-AllowConfigurablePolicy
           CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners

    After running this script, reboot. The system enters Setup Mode, EnableCKS
    runs, enables CKS, then reboots again into normal mode. CKS is now active.

    Run 05-Install-CKS-Driver.ps1 immediately after the second reboot to
    install ckspdrv.sys before sppsvc (~10 minutes) resets CKS.

.PARAMETER PKIPath
    Path (inside the VM) to the CKS-PKI folder.

.PARAMETER PFXPassword
    SecureString password for pk.pfx. Prompted interactively if not supplied.

.PARAMETER EnableCKSExe
    Path to EnableCKS.exe. Build from source (EnableCustomKernelSigners folder)
    or download from: https://github.com/HyperSine/Windows10-CustomKernelSigners/releases

.PARAMETER SkipPolicyGeneration
    Skip New-CIPolicy and use an existing SiPolicy.xml in the work directory.
    Required on non-Enterprise/Education editions.

.PARAMETER WorkDir
    Working directory for intermediate files. Default: <PKIPath>\sipolicy

.EXAMPLE
    .\04-Deploy-SiPolicy.ps1 -PKIPath "C:\CKS-PKI" -EnableCKSExe "C:\CKS\EnableCKS.exe"

.EXAMPLE
    # On Windows 11 Home/Pro -- use the repo's sample SiPolicy.xml
    Copy-Item "SiPolicy.xml" "C:\CKS-PKI\sipolicy\SiPolicy.xml"
    .\04-Deploy-SiPolicy.ps1 -PKIPath "C:\CKS-PKI" -EnableCKSExe "C:\CKS\EnableCKS.exe" -SkipPolicyGeneration
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$PKIPath,

    [SecureString]$PFXPassword,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$EnableCKSExe,

    [switch]$SkipPolicyGeneration,

    [string]$WorkDir = ""
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
    $PFXPassword = Read-Host "Enter PFX password for pk.pfx" -AsSecureString
}

# Convert to plain text for signtool /p (unavoidable -- signtool has no SecureString API)
$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PFXPassword)
$pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
if (-not $WorkDir) { $WorkDir = Join-Path $PKIPath "sipolicy" }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$pkPfxPath   = Join-Path $PKIPath "pk.pfx"
$kmDerPath   = Join-Path $PKIPath "km.der"
$siPolicyXml = Join-Path $WorkDir "SiPolicy.xml"
$siPolicyBin = Join-Path $WorkDir "SiPolicy.bin"
$siPolicyP7  = Join-Path $WorkDir "SiPolicy.bin.p7"
$siPolicyP7b = Join-Path $WorkDir "SiPolicy.p7b"

foreach ($f in @($pkPfxPath, $kmDerPath)) {
    if (-not (Test-Path $f)) {
        throw "Required file not found: $f -- copy the CKS-PKI folder into the VM first."
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
    throw "signtool.exe not found.`n" +
          "Install the Windows SDK: https://developer.microsoft.com/windows/downloads/windows-sdk/`n" +
          "Or copy signtool.exe from the host into the VM."
}

Write-OK "signtool: $signtool"

# ---------------------------------------------------------------------------
# Guard: SecureBoot must be ON before deploying SiPolicy
# The UEFI firmware only reads SiPolicy.p7b when SecureBoot is enforcing.
# ---------------------------------------------------------------------------
Write-Step "Checking SecureBoot status"

try {
    $sbState = Confirm-SecureBootUEFI -ErrorAction Stop
    if ($sbState -ne $true) {
        throw "SecureBoot returned: $sbState"
    }
    Write-OK "SecureBoot is ON"
} catch {
    if ($_.Exception.Message -notmatch "Secure Boot") {
        Write-Note "Could not confirm SecureBoot state: $($_.Exception.Message)"
        Write-Note "Proceeding -- ensure SecureBoot is enabled in Hyper-V firmware settings."
    } else {
        throw "SecureBoot does not appear to be enabled.`n" +
              "On the HOST: Set-VMFirmware -VMName <name> -EnableSecureBoot On`n" +
              "Restart the VM and run this script again."
    }
}

# ---------------------------------------------------------------------------
# 1. Generate SiPolicy.xml
# ---------------------------------------------------------------------------
if ($SkipPolicyGeneration) {
    if (-not (Test-Path $siPolicyXml)) {
        throw "-SkipPolicyGeneration was set but SiPolicy.xml not found at: $siPolicyXml`n" +
              "Download the sample from:`n" +
              "  https://github.com/HyperSine/Windows10-CustomKernelSigners/blob/master/asset/SiPolicy.xml`n" +
              "and copy it to $WorkDir"
    }
    Write-OK "Using existing SiPolicy.xml: $siPolicyXml"
} else {
    Write-Step "Generating SiPolicy.xml via New-CIPolicy (scanning System32 -- ~2-3 minutes)"

    if (-not (Get-Command New-CIPolicy -ErrorAction SilentlyContinue)) {
        Write-Fail "New-CIPolicy is not available on this Windows edition."
        Write-Fail "Required: Windows 11 Enterprise or Education."
        Write-Fail "Alternative: use -SkipPolicyGeneration with the repo's sample SiPolicy.xml"
        exit 1
    }

    New-CIPolicy `
        -FilePath  $siPolicyXml `
        -Level     RootCertificate `
        -ScanPath  "$env:windir\System32"

    Write-OK "SiPolicy.xml generated: $siPolicyXml"
}

# ---------------------------------------------------------------------------
# 2. Add KM cert as a kernel signer rule
# ---------------------------------------------------------------------------
Write-Step "Adding KM cert as kernel signer rule"
Add-SignerRule -FilePath $siPolicyXml -CertificatePath $kmDerPath -Kernel
Write-OK "Kernel signer rule added for: $kmDerPath"

# ---------------------------------------------------------------------------
# 3. Compile to SiPolicy.bin
# ---------------------------------------------------------------------------
Write-Step "Compiling SiPolicy.xml -> SiPolicy.bin"
ConvertFrom-CIPolicy -XmlFilePath $siPolicyXml -BinaryFilePath $siPolicyBin
Write-OK ("SiPolicy.bin: {0} bytes" -f (Get-Item $siPolicyBin).Length)

# ---------------------------------------------------------------------------
# 4. Sign SiPolicy.bin with the PK certificate
#
# OID 1.3.6.1.4.1.311.79.1 is the Microsoft-defined OID for WDAC policies.
# signtool embeds the signature as a PKCS#7 detached file (.p7).
# The timestamp server is mandatory for Windows 11 -- omitting it causes
# the signature to be considered expired.
# /td sha256 forces a SHA-256 timestamp hash (required on Windows 11).
# ---------------------------------------------------------------------------
Write-Step "Signing SiPolicy.bin with PK cert"

$signArgs = @(
    "sign",
    "/fd",   "sha256",
    "/p7co", "1.3.6.1.4.1.311.79.1",
    "/p7",   $WorkDir,
    "/f",    $pkPfxPath,
    "/p",    $pwPlain,
    "/tr",   "http://timestamp.digicert.com",
    "/td",   "sha256",
    $siPolicyBin
)

& $signtool @signArgs
if ($LASTEXITCODE -ne 0) {
    throw "signtool failed (exit $LASTEXITCODE). Check the PFX password and cert chain."
}

# Rename .bin.p7 -> .p7b (required filename for EFI\Microsoft\Boot\)
if (Test-Path $siPolicyP7b) { Remove-Item $siPolicyP7b -Force }
Rename-Item -Path $siPolicyP7 -NewName "SiPolicy.p7b"
Write-OK "SiPolicy.p7b signed: $siPolicyP7b"

# Zero plain-text password from memory
$pwPlain = [string]::new('*', $pwPlain.Length); $pwPlain = $null

# ---------------------------------------------------------------------------
# 5. Deploy SiPolicy.p7b to EFI\Microsoft\Boot\
# ---------------------------------------------------------------------------
Write-Step "Deploying SiPolicy.p7b to EFI System Partition"

# Find a free drive letter for the ESP
$usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
$efiLetter   = [char[]](67..90) |          # C..Z
    ForEach-Object { [string]$_ } |
    Where-Object { $_ -notin $usedLetters } |
    Select-Object -First 1

if (-not $efiLetter) {
    throw "No free drive letters available to mount the EFI System Partition."
}

try {
    & mountvol "$efiLetter`:" /s
    if ($LASTEXITCODE -ne 0) {
        throw "mountvol returned exit code $LASTEXITCODE"
    }

    $efiBootDir = "$efiLetter`:\EFI\Microsoft\Boot"
    if (-not (Test-Path $efiBootDir)) {
        throw "EFI\Microsoft\Boot not found on the mounted partition ($efiLetter:). " +
              "The EFI System Partition may not be the active one, or Windows is not installed yet."
    }

    Copy-Item -Path $siPolicyP7b -Destination "$efiBootDir\SiPolicy.p7b" -Force
    Write-OK "SiPolicy.p7b -> $efiBootDir\SiPolicy.p7b"
} finally {
    & mountvol "$efiLetter`:" /d | Out-Null
}

# ---------------------------------------------------------------------------
# 6. Configure registry for Setup Mode boot (to run EnableCKS.exe)
#
# Windows checks HKLM\SYSTEM\Setup\SetupType at boot. If it is non-zero,
# the kernel runs HKLM\SYSTEM\Setup\CmdLine before the normal user session.
# This happens at a stage when kernel initialisation is not yet complete,
# so ExUpdateLicenseData can be called to modify the ProductPolicy variable
# before sppsvc locks it.
# ---------------------------------------------------------------------------
Write-Step "Scheduling EnableCKS.exe via Setup Mode registry"

# Copy EnableCKS.exe to System32 so it is accessible from the minimal boot env
$enableCksTarget = Join-Path $env:SystemRoot "System32\EnableCKS.exe"
Copy-Item -Path $EnableCKSExe -Destination $enableCksTarget -Force
Write-OK "EnableCKS.exe -> $enableCksTarget"

$setupKey = "HKLM:\SYSTEM\Setup"
Set-ItemProperty -Path $setupKey -Name "CmdLine"   -Value "$enableCksTarget -setupmode" -Type String
Set-ItemProperty -Path $setupKey -Name "SetupType" -Value 2 -Type DWord
Write-OK "Registry keys set (CmdLine + SetupType = 2)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-OK "SiPolicy deployed and Setup Mode scheduled."
Write-Note "REBOOT NOW. The boot sequence will be:"
Write-Host "  1. Boot -> Setup Mode -> EnableCKS.exe runs -> CKS enabled"
Write-Host "  2. Automatic reboot -> normal Windows session"
Write-Host ""
Write-Note "IMMEDIATELY after the second reboot (before ~10 minutes elapse), run:"
Write-Host "  .\05-Install-CKS-Driver.ps1 -PKIPath '$PKIPath' -CKSDriverPath <path\ckspdrv.sys>"
Write-Host ""
Write-Host "ckspdrv.sys keeps CKS active by calling ExUpdateLicenseData continuously."
Write-Host "Without it, sppsvc resets the policy within ~10 minutes."
