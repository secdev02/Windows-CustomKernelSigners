#Requires -RunAsAdministrator
#Requires -Module Hyper-V

<#
.SYNOPSIS
    Creates a Hyper-V Gen 2 test VM for Custom Kernel Signers (CKS) development.

.DESCRIPTION
    Part of the CKS Hyper-V toolkit in tools\hyper-v\. Run from the repo root
    or from tools\hyper-v\ -- the script has no repo-relative dependencies itself.

    Creates a Generation 2 VM configured for CKS testing:

      SecureBoot OFF, no template
        A fresh Gen 2 VM with SecureBoot disabled and no SecureBootTemplate has
        no UEFI keys pre-populated. This leaves the virtual UEFI in Setup Mode,
        which is required so that 03-Set-UEFI-Keys.ps1 can enroll a custom
        Platform Key without needing a signed authenticated variable update.

      Nested virtualisation DISABLED
        Exposing virtualisation extensions to the guest enables VBS/HVCI inside
        the VM. ckspdrv.sys is not HVCI-compatible, so this must remain off.

      Fixed memory, checkpoints disabled
        Kernel development benefits from a stable memory layout and clean state.

    Expected workflow after this script:
      1.  Start-VM and install Windows 11 Enterprise or Education.
          (ConvertFrom-CIPolicy is not available on Home or Pro.)
      2.  HOST:  .\02-New-CKS-PKI.ps1
      3.          Copy tools\hyper-v\pki\ into the VM.
      4.  GUEST: .\03-Set-UEFI-Keys.ps1
                  Shut down the VM.
      5.  HOST:  Set-VMFirmware -VMName <name> -EnableSecureBoot On
                  Start-VM -Name <name>
      6.  GUEST: .\04-Deploy-SiPolicy.ps1
                  Reboot when prompted.
      7.  GUEST: .\05-Install-CKS-Driver.ps1  (within ~10 min of reboot)

.PARAMETER VMName
    Name for the new virtual machine. Default: CKS-TestVM

.PARAMETER VMPath
    Parent directory for VM storage files. Default: C:\HyperV\VMs

.PARAMETER VHDSizeGB
    Virtual disk size in gigabytes. Default: 80

.PARAMETER MemoryGB
    Fixed startup RAM in gigabytes. Default: 4

.PARAMETER CPUCount
    Number of virtual processors. Default: 4

.PARAMETER ISOPath
    Full path to a Windows 11 Enterprise or Education ISO. Mandatory.

.EXAMPLE
    .\01-New-CKS-VM.ps1 -ISOPath "D:\ISOs\Win11_Ent_24H2_x64.iso"

.EXAMPLE
    .\01-New-CKS-VM.ps1 -VMName "CKS-Dev" -VHDSizeGB 120 -ISOPath "D:\ISOs\Win11_Ent_24H2_x64.iso"
#>

[CmdletBinding()]
param(
    [string]$VMName  = "CKS-TestVM",
    [string]$VMPath  = "C:\HyperV\VMs",
    [int]$VHDSizeGB  = 80,
    [int]$MemoryGB   = 4,
    [int]$CPUCount   = 4,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ISOPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan  }
function Write-OK   { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Guard: Hyper-V module must be present
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Hyper-V PowerShell module not found.`n" +
          "Enable it: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
}

# ---------------------------------------------------------------------------
# Guard: VM name must not already exist
# ---------------------------------------------------------------------------
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "A VM named '$VMName' already exists. Choose a different name or remove it first."
}

$vhdPath = Join-Path $VMPath "$VMName\$VMName.vhdx"

Write-Step "Creating VM '$VMName'"
Write-Host "    Path   : $VMPath"
Write-Host "    VHD    : $vhdPath ($VHDSizeGB GB)"
Write-Host "    Memory : $MemoryGB GB (fixed)"
Write-Host "    CPU    : $CPUCount vCPU"
Write-Host "    ISO    : $ISOPath"
Write-Host ""

# ---------------------------------------------------------------------------
# Create the VM
# ---------------------------------------------------------------------------
New-VM `
    -Name             $VMName `
    -Path             $VMPath `
    -Generation       2 `
    -MemoryStartupBytes ([long]$MemoryGB * 1GB) `
    -NewVHDPath       $vhdPath `
    -NewVHDSizeBytes  ([long]$VHDSizeGB * 1GB) | Out-Null

Write-OK "VM created (Generation 2 / UEFI)"

Set-VM -Name $VMName `
    -ProcessorCount              $CPUCount `
    -AutomaticCheckpointsEnabled $false `
    -CheckpointType              Disabled

# -DynamicMemory is a switch parameter on Set-VM -- passing $false to a switch
# causes "positional parameter not found". Set-VMMemory has a proper bool parameter.
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

Write-OK "CPU ($CPUCount vCPU) and memory ($MemoryGB GB fixed) configured"

# ---------------------------------------------------------------------------
# Disable nested virtualisation
# Prevents VBS/HVCI from activating inside the guest. ckspdrv.sys is not
# HVCI-compatible -- if the guest activates HVCI it will block the driver
# regardless of CKS being enabled.
# ---------------------------------------------------------------------------
Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions:$false
Write-OK "Nested virtualisation disabled (VBS/HVCI will not activate in guest)"

# ---------------------------------------------------------------------------
# SecureBoot OFF, no template
#
# New-VM -Generation 2 defaults to SecureBoot On with the MicrosoftWindows
# template. Setting -EnableSecureBoot Off before the VM is ever started
# prevents any keys from being written to the virtual UEFI NVRAM, leaving
# the UEFI in Setup Mode -- required for 03-Set-UEFI-Keys.ps1.
#
# If the VM is started before running 03-Set-UEFI-Keys.ps1, the UEFI will
# have been initialised and may have keys enrolled. In that case, boot a
# UEFI Shell ISO to clear the keys before re-running the enrollment script.
# ---------------------------------------------------------------------------
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Write-OK "SecureBoot disabled (no template = UEFI Setup Mode for custom PK enrollment)"

# ---------------------------------------------------------------------------
# Attach ISO and set boot order
# ---------------------------------------------------------------------------
$dvd = Add-VMDvdDrive -VMName $VMName -Path $ISOPath -Passthru
$hdd = Get-VMHardDiskDrive -VMName $VMName

Set-VMFirmware -VMName $VMName -BootOrder $dvd, $hdd
Write-OK "ISO attached, boot order: DVD -> VHDX"

# ---------------------------------------------------------------------------
# Enhanced Session for clipboard / drive sharing between host and guest
# ---------------------------------------------------------------------------
Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction SilentlyContinue
Set-VM    -VMName $VMName -EnhancedSessionTransportType HvSocket -ErrorAction SilentlyContinue
Write-OK "Enhanced Session Mode enabled"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-OK "VM '$VMName' is ready."
Write-Host ""
Write-Note "NEXT STEPS -- follow this order:"
Write-Host ""
Write-Host "  [HOST]  Start-VM -Name '$VMName'"
Write-Host "          Install Windows 11 Enterprise or Education"
Write-Host ""
Write-Host "  [HOST]  .\02-New-CKS-PKI.ps1"
Write-Host "          Copy the generated tools\hyper-v\pki\ folder into the VM"
Write-Host ""
Write-Host "  [GUEST] .\03-Set-UEFI-Keys.ps1"
Write-Host "          Then SHUT DOWN the VM (not restart)"
Write-Host ""
Write-Host "  [HOST]  Set-VMFirmware -VMName '$VMName' -EnableSecureBoot On"
Write-Host "          Start-VM -Name '$VMName'"
Write-Host ""
Write-Host "  [GUEST] .\04-Deploy-SiPolicy.ps1"
Write-Host "          Reboot when prompted"
Write-Host ""
Write-Host "  [GUEST] .\05-Install-CKS-Driver.ps1  (within ~10 min of reboot)"
