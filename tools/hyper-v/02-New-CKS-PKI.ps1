#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Generates the PKI chain and EFI Signature List files needed for CKS.

.DESCRIPTION
    Run this on the HOST (before copying anything into the VM).

    Creates three certificates using New-SelfSignedCertificate:

      root-ca  -- Self-signed root CA. Anchors the chain.
                  Used with signtool /ac to provide cross-certification.

      pk       -- Platform Key, issued by root-ca.
                  Used to sign SiPolicy.bin (the WDAC policy bundle).
                  Enrolled in the VM's UEFI as the PK variable.

      km       -- Kernel Mode signing cert, issued by root-ca.
                  Used to sign ckspdrv.sys and any other custom drivers.
                  Added as a kernel signer rule in SiPolicy.xml.

    Each certificate is exported as:
      .der   DER-encoded binary -- for signtool /ac and UEFI ESL construction
      .pfx   PKCS#12 with private key -- for signtool /f

    EFI Signature List (.esl) files are also created. These are the binary
    format that Set-SecureBootUEFI consumes to enroll keys into the VM UEFI:

      pk.esl   -- PK variable payload  (pk cert)
      kek.esl  -- KEK variable payload (pk cert reused -- sufficient for test)
      db.esl   -- db variable payload  (Microsoft UEFI certs from host + km cert)

    Microsoft's certs are extracted from the HOST's UEFI db variable and
    prepended to db.esl. This is required so that Windows Boot Manager
    (bootmgfw.efi), which is signed by Microsoft, remains trusted after
    SecureBoot is enabled in the VM with our custom PK.

.PARAMETER OutputPath
    Directory where all generated files are written. Created if it does not exist.

.PARAMETER PFXPassword
    SecureString password for all exported .pfx files.
    You will be prompted interactively if this is not supplied.

.PARAMETER ValidYears
    Certificate validity period in years. Default: 10

.EXAMPLE
    .\02-New-CKS-PKI.ps1 -OutputPath "C:\CKS-PKI"

.EXAMPLE
    $pw = Read-Host "Password" -AsSecureString
    .\02-New-CKS-PKI.ps1 -OutputPath "C:\CKS-PKI" -PFXPassword $pw -ValidYears 5
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\CKS-PKI",
    [SecureString]$PFXPassword,
    [int]$ValidYears = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan  }
function Write-OK   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Prompt for PFX password if not supplied
# ---------------------------------------------------------------------------
if (-not $PFXPassword) {
    $PFXPassword = Read-Host "Enter PFX export password" -AsSecureString
}

# ---------------------------------------------------------------------------
# Create output directory
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-OK "Output directory: $OutputPath"

# ---------------------------------------------------------------------------
# Helper: SecureString -> plain string (needed for X509Certificate2.Export)
# The plain text is zeroed immediately after use.
# ---------------------------------------------------------------------------
function Unprotect-SecureString {
    param([SecureString]$SecStr)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecStr)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ---------------------------------------------------------------------------
# Helper: Export a certificate to DER and PFX
# ---------------------------------------------------------------------------
function Export-Cert {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [string]$BaseName
    )

    $derPath = Join-Path $OutputPath "$BaseName.der"
    $pfxPath = Join-Path $OutputPath "$BaseName.pfx"

    # DER -- raw public cert, no private key
    [System.IO.File]::WriteAllBytes($derPath, $Cert.RawData)

    # PFX -- full cert + private key, password-protected
    $pwPlain = Unprotect-SecureString $PFXPassword
    try {
        $pfxBytes = $Cert.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
            $pwPlain
        )
        [System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)
    } finally {
        # Zero the plain-text password from memory as soon as possible
        $pwPlain = [string]::new('*', $pwPlain.Length)
        $pwPlain = $null
    }

    Write-OK ("  {0,-16} {1}" -f "$BaseName.der", $derPath)
    Write-OK ("  {0,-16} {1}" -f "$BaseName.pfx", $pfxPath)
}

# ---------------------------------------------------------------------------
# Helper: Build an EFI Signature List (ESL) from a single DER certificate.
#
# Structure (UEFI spec 2.10, section 32.4.1):
#
#   EFI_SIGNATURE_LIST
#   +-----------------+----+
#   | SignatureType   | 16 |  GUID -- EFI_CERT_X509_GUID for X.509
#   | SignatureListSz |  4 |  Total bytes of this EFI_SIGNATURE_LIST
#   | SigHeaderSize   |  4 |  0 for X.509 type
#   | SignatureSize   |  4 |  16 (owner GUID) + len(certDER)
#   +------+----------+----+
#   | EFI_SIGNATURE_DATA[0]
#   |   SignatureOwner | 16 |  Any GUID identifying the owner
#   |   SignatureData  | N  |  Raw DER-encoded certificate
#   +-------------------+--+
#
# SignatureListSize = 28 (header) + 16 (owner GUID) + len(certDER)
#                  = 44 + len(certDER)
# ---------------------------------------------------------------------------
function ConvertTo-EFISignatureList {
    param(
        [byte[]]$CertDer,
        [System.Guid]$OwnerGuid = [System.Guid]::NewGuid()
    )

    # EFI_CERT_X509_GUID = {a5c059a1-94e4-4aa7-87b5-ab155c2bf072}
    $x509TypeGuid = [System.Guid]::new("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")

    $sigDataSize = 16 + $CertDer.Length  # owner GUID + cert bytes
    $sigListSize = 28 + $sigDataSize     # header (28) + one EFI_SIGNATURE_DATA entry

    $esl    = [byte[]]::new($sigListSize)
    $offset = 0

    # SignatureType GUID
    # .NET Guid.ToByteArray() returns mixed-endian matching the UEFI GUID layout:
    #   Data1 (4 bytes LE), Data2 (2 bytes LE), Data3 (2 bytes LE), Data4 (8 bytes BE)
    $x509TypeGuid.ToByteArray().CopyTo($esl, $offset); $offset += 16

    # SignatureListSize (UINT32, little-endian)
    [System.BitConverter]::GetBytes([uint32]$sigListSize).CopyTo($esl, $offset); $offset += 4

    # SignatureHeaderSize (UINT32, little-endian) -- 0 for X.509
    [System.BitConverter]::GetBytes([uint32]0).CopyTo($esl, $offset); $offset += 4

    # SignatureSize (UINT32, little-endian) -- size of each EFI_SIGNATURE_DATA entry
    [System.BitConverter]::GetBytes([uint32]$sigDataSize).CopyTo($esl, $offset); $offset += 4

    # EFI_SIGNATURE_DATA.SignatureOwner (GUID)
    $OwnerGuid.ToByteArray().CopyTo($esl, $offset); $offset += 16

    # EFI_SIGNATURE_DATA.SignatureData (raw DER)
    $CertDer.CopyTo($esl, $offset)

    return $esl
}

# Use a fixed owner GUID for all our CKS certs (makes them identifiable in UEFI)
$cksOwnerGuid = [System.Guid]::new("caf3b501-dead-beef-1337-000000000001")
$notAfter     = (Get-Date).AddYears($ValidYears)

# ---------------------------------------------------------------------------
# 1. Root CA
# ---------------------------------------------------------------------------
Write-Step "Generating Root CA"

$rootCA = New-SelfSignedCertificate `
    -Subject           "CN=CKS-RootCA, O=CKS-TestEnv" `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -KeyUsage          CertSign, CRLSign `
    -KeyExportPolicy   Exportable `
    -NotAfter          $notAfter `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -TextExtension     @("2.5.29.19={critical}{text}ca=1&pathlength=1")

Export-Cert -Cert $rootCA -BaseName "root-ca"

# ---------------------------------------------------------------------------
# 2. Platform Key (PK) certificate
# Used to sign SiPolicy.bin and enrolled as the UEFI PK variable.
# ---------------------------------------------------------------------------
Write-Step "Generating PK (Platform Key) certificate"

$pkCert = New-SelfSignedCertificate `
    -Subject           "CN=CKS-PlatformKey, O=CKS-TestEnv" `
    -Signer            $rootCA `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -KeyUsage          DigitalSignature `
    -KeyExportPolicy   Exportable `
    -NotAfter          $notAfter `
    -CertStoreLocation "Cert:\LocalMachine\My"

Export-Cert -Cert $pkCert -BaseName "pk"

# ---------------------------------------------------------------------------
# 3. Kernel Mode (KM) signing certificate
# Used to sign ckspdrv.sys and any other custom drivers.
# Added as a kernel signer rule in SiPolicy.xml by 04-Deploy-SiPolicy.ps1.
# ---------------------------------------------------------------------------
Write-Step "Generating KM (Kernel Mode) signing certificate"

$kmCert = New-SelfSignedCertificate `
    -Subject           "CN=CKS-KernelMode, O=CKS-TestEnv" `
    -Signer            $rootCA `
    -KeyAlgorithm      RSA `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -KeyUsage          DigitalSignature `
    -KeyExportPolicy   Exportable `
    -NotAfter          $notAfter `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -TextExtension     @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")  # EKU: Code Signing

Export-Cert -Cert $kmCert -BaseName "km"

# ---------------------------------------------------------------------------
# 4. Build EFI Signature List files
# ---------------------------------------------------------------------------
Write-Step "Building EFI Signature List (.esl) files"

$pkDerBytes  = [System.IO.File]::ReadAllBytes((Join-Path $OutputPath "pk.der"))
$kmDerBytes  = [System.IO.File]::ReadAllBytes((Join-Path $OutputPath "km.der"))

# pk.esl -- the PK UEFI variable payload
$pkEsl = ConvertTo-EFISignatureList -CertDer $pkDerBytes -OwnerGuid $cksOwnerGuid
[System.IO.File]::WriteAllBytes((Join-Path $OutputPath "pk.esl"), $pkEsl)
Write-OK ("  pk.esl   {0} bytes" -f $pkEsl.Length)

# kek.esl -- reuse the PK cert as KEK (sufficient for a test environment;
#            the KEK is only needed to authorise future db/dbx updates)
$kekEsl = ConvertTo-EFISignatureList -CertDer $pkDerBytes -OwnerGuid $cksOwnerGuid
[System.IO.File]::WriteAllBytes((Join-Path $OutputPath "kek.esl"), $kekEsl)
Write-OK ("  kek.esl  {0} bytes" -f $kekEsl.Length)

# db.esl -- Microsoft UEFI certs from HOST (so bootmgfw.efi stays trusted)
#           concatenated with our KM cert ESL
Write-Step "Extracting Microsoft UEFI db certs from host (required to boot Windows)"

$msDbEsl = $null
try {
    $hostDb  = Get-SecureBootUEFI -Name db -ErrorAction Stop
    $msDbEsl = $hostDb.Bytes
    [System.IO.File]::WriteAllBytes((Join-Path $OutputPath "ms_db.esl"), $msDbEsl)
    Write-OK ("  ms_db.esl extracted from host ({0} bytes)" -f $msDbEsl.Length)
} catch {
    Write-Note "Could not read host UEFI db -- host may not have SecureBoot or script is not on a UEFI system."
    Write-Note "db.esl will contain ONLY the KM cert. After enabling SecureBoot in the VM, Windows may"
    Write-Note "fail to boot because bootmgfw.efi is not trusted. In that case, add the Microsoft UEFI"
    Write-Note "CA 2011 cert to db manually via Set-SecureBootUEFI inside the VM."
}

# km cert as an ESL entry
$kmEsl = ConvertTo-EFISignatureList -CertDer $kmDerBytes -OwnerGuid $cksOwnerGuid

# Concatenate: Microsoft entries (if available) come first so they are parsed first
$dbEsl = if ($msDbEsl) { $msDbEsl + $kmEsl } else { $kmEsl }
[System.IO.File]::WriteAllBytes((Join-Path $OutputPath "db.esl"), $dbEsl)
Write-OK ("  db.esl   {0} bytes (MS certs {1}, KM cert {2})" -f `
    $dbEsl.Length,
    $(if ($msDbEsl) { "$($msDbEsl.Length) bytes" } else { "NOT included" }),
    "$($kmEsl.Length) bytes"
)

# ---------------------------------------------------------------------------
# 5. Write a README with all signing commands
# ---------------------------------------------------------------------------
Write-Step "Writing README.txt"

$readme = @"
CKS PKI Package
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
====================================================================

FILES
-----
  Certificates (DER = public only, PFX = public + private key)

    root-ca.der / root-ca.pfx   Self-signed Root CA
    pk.der      / pk.pfx        Platform Key  (signs SiPolicy.bin)
    km.der      / km.pfx        Kernel Mode signing cert (signs drivers)

  UEFI Enrollment (EFI Signature List format)

    pk.esl       PK variable  -- enroll via Set-SecureBootUEFI -Name PK
    kek.esl      KEK variable -- enroll via Set-SecureBootUEFI -Name KEK
    db.esl       db variable  -- enroll via Set-SecureBootUEFI -Name db
    ms_db.esl    Microsoft certs extracted from host (informational)

SIGNING COMMANDS
----------------
  Replace <PFX_PASSWORD> with the password used when running this script.

  Sign SiPolicy.bin with the PK cert (produces SiPolicy.bin.p7):
    signtool sign /fd sha256 /p7co 1.3.6.1.4.1.311.79.1 /p7 . ^
        /f pk.pfx /p <PFX_PASSWORD> ^
        /tr http://timestamp.digicert.com /td sha256 SiPolicy.bin

  Sign a driver with the KM cert:
    signtool sign /fd sha256 /ac root-ca.der /f km.pfx /p <PFX_PASSWORD> ^
        /tr http://timestamp.digicert.com /td sha256 ckspdrv.sys

  Key differences from the original README (Windows 10):
    - /tr http://timestamp.digicert.com  (Symantec server deprecated)
    - /td sha256  (forces SHA-256 timestamp hash -- required on Windows 11)

CERT THUMBPRINTS
----------------
"@

foreach ($name in @("root-ca","pk","km")) {
    $derPath = Join-Path $OutputPath "$name.der"
    $cert    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($derPath)
    $readme += "  $($name.PadRight(12)) $($cert.Thumbprint)  (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))`n"
}

$readme | Set-Content (Join-Path $OutputPath "README.txt") -Encoding UTF8
Write-OK "  README.txt"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-OK "PKI package written to: $OutputPath"
Write-Note "Copy this entire folder into the VM, then run 03-Set-UEFI-Keys.ps1 inside it."
Write-Host ""
Write-Host "Certificates installed in Cert:\LocalMachine\My (host):"
Get-ChildItem "Cert:\LocalMachine\My" |
    Where-Object { $_.Subject -like "*CKS-*" } |
    Format-Table Subject, Thumbprint, NotAfter -AutoSize
