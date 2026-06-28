# Windwos 11 - Custom Kernel Signers 

June -2026 - Custom tooling and script to enable teams to setup Hyper-V based images with Custom Signed Drivers for Deception based system, Kernel Research and other shenanigans.

# Custom Kernel Signers — Hyper-V Test Toolkit

A companion script set for [HyperSine/Windows10-CustomKernelSigners](https://github.com/HyperSine/Windows10-CustomKernelSigners) that extends the original workflow to **Windows 11** and replaces the VMware-specific steps with native **Hyper-V** equivalents.

---

## Do I Need to Fork the Original Repo?

**No.** Clone the original as-is. This toolkit sits alongside it — it does not modify any upstream code.

```
git clone https://github.com/HyperSine/Windows10-CustomKernelSigners.git
```

You only need two outputs from that repo:

| File | Where it comes from |
|---|---|
| `EnableCKS.exe` | Build `EnableCustomKernelSigners\` or grab from [Releases](https://github.com/HyperSine/Windows10-CustomKernelSigners/releases) |
| `ckspdrv.sys` | Build `CustomKernelSignersPersistent\` or grab from [Releases](https://github.com/HyperSine/Windows10-CustomKernelSigners/releases) |

If you are targeting **Windows 11 22H2 or later**, rebuild both from source with WDK 24H2 + Visual Studio 2022. The 2019 pre-built binaries may work on older builds but are untested against current kernel structures.

---

## What Is Custom Kernel Signers?

Windows requires kernel-mode drivers to be signed by a certificate trusted by Microsoft. Since Windows 10 1607, new drivers must go through the [Windows Hardware Compatibility Program (WHCP)](https://learn.microsoft.com/windows-hardware/design/compatibility/) portal. This is the right path for production drivers.

For **test and development** — drivers that cannot or should not be submitted publicly — Windows provides an escape hatch called **Custom Kernel Signers (CKS)**, a product policy named `CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners`. When enabled alongside a UEFI-locked `SiPolicy.p7b`, you can designate your own certificate as a trusted kernel signer on a specific machine. No TestSigning mode. No DSE bypass.

The key requirements are:

- The product policy must be active in the kernel's `ProductPolicy` variable
- Secure Boot must be **on**
- A `SiPolicy.p7b` signed by the machine's UEFI Platform Key (PK) must exist at `EFI\Microsoft\Boot\`
- The PK must be **your own** — you cannot sign against Microsoft's PK

This toolkit automates all of those steps for a Hyper-V virtual machine.

---

## Prerequisites

### Host machine

| Requirement | Notes |
|---|---|
| Windows 10/11 Pro, Enterprise, or Education | Hyper-V is not available on Home |
| Hyper-V enabled | `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All` |
| Windows SDK (for `signtool.exe`) | [Download](https://developer.microsoft.com/windows/downloads/windows-sdk/) — any recent version |
| PowerShell 5.1+ running as Administrator | All host scripts require elevation |

### Guest VM

| Requirement | Notes |
|---|---|
| Windows 11 **Enterprise or Education** | `New-CIPolicy` and `ConvertFrom-CIPolicy` are not available on Home or Pro |
| Windows SDK in the VM | Same as host — needed for `signtool.exe` inside the VM |
| `EnableCKS.exe` | From the original repo |
| `ckspdrv.sys` (unsigned) | From the original repo — this toolkit signs it |

> **Why Enterprise or Education?**  
> `ConvertFrom-CIPolicy` — the PowerShell cmdlet that compiles `SiPolicy.xml` to `SiPolicy.bin` — ships only with these editions. If you are stuck on Home or Pro, use `-SkipPolicyGeneration` with the [sample SiPolicy.xml](https://github.com/HyperSine/Windows10-CustomKernelSigners/blob/master/asset/SiPolicy.xml) from the repo.

---

## Scripts

All five scripts ship with full comment-based help. Run `Get-Help .\<script>.ps1 -Full` for parameter details.

| Script | Runs on | When |
|---|---|---|
| `01-New-CKS-VM.ps1` | Host | Once, before anything else |
| `02-New-CKS-PKI.ps1` | Host | After VM is created, before first guest boot for enrollment |
| `03-Set-UEFI-Keys.ps1` | **Guest** | After Windows install, while SecureBoot is still off |
| `04-Deploy-SiPolicy.ps1` | **Guest** | After SecureBoot is enabled and VM has rebooted |
| `05-Install-CKS-Driver.ps1` | **Guest** | Within ~10 minutes of the EnableCKS reboot |

---

## Full Walkthrough

### Step 1 — Create the VM

Run on the **host** as Administrator:

```powershell
.\01-New-CKS-VM.ps1 -ISOPath "D:\ISOs\Win11_Ent_24H2_x64.iso"
```

This creates a Generation 2 Hyper-V VM with:

- SecureBoot **off**, no SecureBoot template — the virtual UEFI starts with no keys enrolled (Setup Mode)
- Nested virtualisation **disabled** — prevents VBS/HVCI activating inside the guest, which would block `ckspdrv.sys`
- Fixed memory, checkpoints disabled

> **Do not start the VM yet.**

---

### Step 2 — Generate the PKI

Run on the **host** as Administrator:

```powershell
.\02-New-CKS-PKI.ps1 -OutputPath "C:\CKS-PKI"
```

This generates three certificates and exports them as `.der` (public) and `.pfx` (private key, password-protected):

| Cert | Purpose |
|---|---|
| `root-ca` | Self-signed root CA. Anchor for the chain. Pass to `signtool /ac`. |
| `pk` | Platform Key. Signs `SiPolicy.bin`. Enrolled in UEFI as the PK variable. |
| `km` | Kernel Mode signing cert. Signs `ckspdrv.sys` and your own drivers. Added to `SiPolicy.xml` as a kernel signer rule. |

It also builds three EFI Signature List (`.esl`) files for UEFI enrollment:

| File | UEFI variable | Contents |
|---|---|---|
| `pk.esl` | `PK` | PK cert |
| `kek.esl` | `KEK` | PK cert (reused — sufficient for test) |
| `db.esl` | `db` | Microsoft UEFI certs (extracted from host) + KM cert |

The Microsoft certs prepended to `db.esl` are extracted from the **host's** UEFI `db` variable. They are required so that `bootmgfw.efi` — which is signed by Microsoft — remains trusted after SecureBoot is enabled in the VM with your custom PK.

---

### Step 3 — Install Windows 11

Start the VM and install Windows 11 Enterprise or Education from the ISO. Standard installation, no special options required.

Once at the desktop, copy the `C:\CKS-PKI` folder from the host into the VM. Enhanced Session Mode (enabled by `01-New-CKS-VM.ps1`) allows clipboard sharing, or use a shared folder.

---

### Step 4 — Enroll UEFI Keys

Run **inside the VM** as Administrator, while SecureBoot is still off:

```powershell
.\03-Set-UEFI-Keys.ps1 -PKIPath "C:\CKS-PKI"
```

This uses `Set-SecureBootUEFI` to enroll `db`, `KEK`, and `PK` into the virtual UEFI. Enrollment works without a signed `.auth` file because the UEFI has no PK yet (Setup Mode). The order is fixed — `PK` must go last because enrolling it closes Setup Mode.

When the script completes, **shut down the VM** (not restart — shut down):

```powershell
# From the host
Stop-VM -Name "CKS-TestVM" -TurnOff
```

---

### Step 5 — Enable SecureBoot

Run on the **host**:

```powershell
Set-VMFirmware -VMName "CKS-TestVM" -EnableSecureBoot On
Start-VM -Name "CKS-TestVM"
```

Windows should boot normally. The `db` contains Microsoft's UEFI certs so `bootmgfw.efi` is trusted. SecureBoot is now enforcing with your custom PK.

---

### Step 6 — Deploy SiPolicy and Enable CKS

Run **inside the VM** as Administrator. You need `EnableCKS.exe` from the original repo:

```powershell
.\04-Deploy-SiPolicy.ps1 `
    -PKIPath      "C:\CKS-PKI" `
    -EnableCKSExe "C:\CKS\EnableCKS.exe"
```

This script:

1. Generates `SiPolicy.xml` by scanning `System32` — establishes a baseline of trusted Microsoft binaries
2. Adds the KM cert as a kernel signer rule via `Add-SignerRule`
3. Compiles to `SiPolicy.bin` via `ConvertFrom-CIPolicy`
4. Signs `SiPolicy.bin` with the PK cert using `signtool` — the UEFI validates this signature against the enrolled PK
5. Mounts the EFI System Partition and copies `SiPolicy.p7b` to `EFI\Microsoft\Boot\`
6. Writes `HKLM\SYSTEM\Setup\CmdLine` and `SetupType=2` to schedule `EnableCKS.exe` at the next boot

**Reboot when prompted.** The sequence is:

```
Reboot -> Setup Mode -> EnableCKS.exe runs -> CKS policies enabled -> Reboot -> Normal session
```

---

### Step 7 — Install the Persistence Driver

Run **inside the VM** as Administrator, **within ~10 minutes** of the second reboot:

```powershell
.\05-Install-CKS-Driver.ps1 `
    -PKIPath       "C:\CKS-PKI" `
    -CKSDriverPath "C:\CKS\ckspdrv.sys"
```

`sppsvc` (Software Protection Service) resets the CKS product policy to disabled within approximately 10 minutes — except on Windows 10 China Government Edition, which is not relevant here. The reset only takes effect on the next reboot, so there is a window.

`ckspdrv.sys` closes that window by calling `ExUpdateLicenseData` on a kernel timer, reapplying the policy continuously. Once it is registered as an auto-start service, CKS persists across reboots.

If `sc.exe start ckspdrv` succeeds, CKS is working. You can now sign and load your own drivers:

```batch
signtool sign /fd sha256 /ac root-ca.der /f km.pfx /p <password> ^
    /tr http://timestamp.digicert.com /td sha256 YourDriver.sys
```

---

## Windows 11 Changes from the Original README

The original repo targets Windows 10. These are the differences relevant for Windows 11:

### Timestamp server and hash flag

The Symantec timestamp server referenced in the original README is deprecated and unreliable. All signing commands in this toolkit use:

```
/tr http://timestamp.digicert.com /td sha256
```

The `/td sha256` flag is not in the original — it forces a SHA-256 timestamp hash. Without it, a SHA-256 file signature receives a SHA-1 timestamp, which Windows 11 may reject.

### HVCI / Memory Integrity

Windows 11 enables HVCI (Hypervisor-Protected Code Integrity) by default on certified hardware. `ckspdrv.sys` is not HVCI-compatible. Script `01-New-CKS-VM.ps1` disables nested virtualisation (`ExposeVirtualizationExtensions = false`), which prevents the Hyper-V guest from activating VBS and HVCI. On bare metal, disable HVCI via Group Policy or `bcdedit /set hypervisorlaunchtype off` before attempting to load the driver.

### `ConvertFrom-CIPolicy` on non-Enterprise editions

If the VM is not Enterprise or Education, run `04-Deploy-SiPolicy.ps1` with `-SkipPolicyGeneration` and supply the [sample SiPolicy.xml](https://github.com/HyperSine/Windows10-CustomKernelSigners/blob/master/asset/SiPolicy.xml) from the repo:

```powershell
# Copy the sample into the work directory the script expects
New-Item -ItemType Directory -Path "C:\CKS-PKI\sipolicy" -Force
Copy-Item "SiPolicy.xml" "C:\CKS-PKI\sipolicy\SiPolicy.xml"

.\04-Deploy-SiPolicy.ps1 `
    -PKIPath              "C:\CKS-PKI" `
    -EnableCKSExe         "C:\CKS\EnableCKS.exe" `
    -SkipPolicyGeneration
```

### New kernel trust policy (Windows 11 24H2, April 2026 update)

Microsoft began rolling out a new kernel trust policy that removes trust for the legacy cross-signed root program. This does not affect the CKS path — the `SiPolicy.p7b` signed against your UEFI PK is the explicitly supported mechanism for private/confidential driver scenarios. See the [Microsoft announcement](https://techcommunity.microsoft.com/blog/windows-itpro-blog/advancing-windows-driver-security-removing-trust-for-the-cross-signed-driver-pro/4504818) for details.

---

## Troubleshooting

### Windows fails to boot after enabling SecureBoot

`db.esl` is missing or incomplete. Disable SecureBoot on the host, boot the VM, and verify:

```powershell
# Inside VM
$db = Get-SecureBootUEFI -Name db
$db.Bytes.Length  # Should be > 2000 bytes if Microsoft certs are present
```

If `ms_db.esl` was not extracted (the host had no UEFI SecureBoot), re-run `02-New-CKS-PKI.ps1` on a UEFI host, or manually add the Microsoft UEFI CA 2011 cert to `db.esl` using `Set-SecureBootUEFI`.

### `Set-SecureBootUEFI` fails with "Authentication required"

The VM's UEFI already has keys enrolled — it is not in Setup Mode. This happens if the VM was started before `01-New-CKS-VM.ps1` set SecureBoot off, or if a SecureBoot template was applied.

Recovery: boot a UEFI shell (attach a UEFI Shell ISO) and use the shell's key management tools to clear `PK`, `KEK`, and `db`, then retry `03-Set-UEFI-Keys.ps1`.

### `EnableCKS.exe` causes a boot loop

The system re-enters Setup Mode on every boot rather than completing and restarting. This is a known issue logged at [HyperSine/Windows10-CustomKernelSigners #7](https://github.com/HyperSine/Windows10-CustomKernelSigners/issues/7). Recovery via Windows Recovery Environment:

```
Open Recovery > Command Prompt
reg load HKLM\TEMPSYSTEM C:\Windows\System32\config\SYSTEM
reg delete HKLM\TEMPSYSTEM\Setup /v CmdLine /f
reg add    HKLM\TEMPSYSTEM\Setup /v SetupType /t REG_DWORD /d 0 /f
reg unload HKLM\TEMPSYSTEM
```

### `sc.exe start ckspdrv` fails

Work through this checklist in order:

1. Did `EnableCKS.exe` print success messages during Setup Mode? If not, CKS is not active.
2. Is `SiPolicy.p7b` present at `X:\EFI\Microsoft\Boot\`? (`mountvol X: /s` to check)
3. Was `SiPolicy.p7b` signed with the PK cert that is enrolled in UEFI?
4. Was `ckspdrv.sys` signed with the KM cert referenced in `SiPolicy.xml`?
5. Has more than ~10 minutes elapsed since the EnableCKS reboot? Run EnableCKS.exe again and immediately retry.

### Signing fails with "The specified timestamp server either could not be reached"

The DigiCert timestamp server requires internet access from inside the VM. Either enable internet access in the VM, or use an offline timestamp if your build environment does not allow outbound connections.

---

## Repository Layout (Suggested)

```
your-project\
├── CKS-HyperV\                  ← This toolkit
│   ├── 01-New-CKS-VM.ps1
│   ├── 02-New-CKS-PKI.ps1
│   ├── 03-Set-UEFI-Keys.ps1
│   ├── 04-Deploy-SiPolicy.ps1
│   ├── 05-Install-CKS-Driver.ps1
│   └── README.md
│
└── Windows10-CustomKernelSigners\  ← Original repo (git clone, do not modify)
    ├── EnableCustomKernelSigners\
    ├── CustomKernelSignersPersistent\
    └── ...
```

The upstream repo is treated as a read-only dependency. Build `EnableCKS.exe` and `ckspdrv.sys` from it, copy the binaries into the VM, and feed their paths to scripts `04` and `05`.

---

## Reference

- [HyperSine/Windows10-CustomKernelSigners](https://github.com/HyperSine/Windows10-CustomKernelSigners) — upstream project
- [Geoff Chappell — Windows product policies](https://www.geoffchappell.com/notes/windows/license/install.htm) — background on the policy mechanism
- [Microsoft — Advancing Windows driver security (April 2026)](https://techcommunity.microsoft.com/blog/windows-itpro-blog/advancing-windows-driver-security-removing-trust-for-the-cross-signed-driver-pro/4504818) — new kernel trust policy context
- [UEFI Spec 2.10, §32.4](https://uefi.org/specifications) — EFI Signature List format used by `02-New-CKS-PKI.ps1`
- [Windows SDK Downloads](https://developer.microsoft.com/windows/downloads/windows-sdk/) — signtool.exe
- [WDK Downloads](https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk) — for rebuilding from source


#Original Work - References - README.md


# Windows10 - Custom Kernel Signers
Original Repo - Cloned - `https://github.com/HyperSine/Windows10-CustomKernelSigners`
[中文版README](README.zh-CN.md)

## 1. What is Custom Kernel Signers?

We know that Windows10 has strict requirements for kernel mode driver. One of the requirements is that drivers must be signed by a EV certificate that Microsoft trusts. What's more start from 1607, new drivers must be submitted to Windows Hardware Portal to get signed by Microsoft. For a driver signed by a self-signed certificate, without enabling TestSigning mode, Windows10 still refuses to load it even the self-signed certificate was installed into Windows Certificate Store(`certlm.msc` or `certmgr.msc`). That means Windows10 has a independent certificate store for kernel mode driver.

__Custom Kernel Signers(CKS)__ is a product policy supported by Windows10(may be from 1703). The full product policy name is `CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners`. It allows users to decide what certificates is trusted or denied in kernel. By the way, this policy may require another policy, `CodeIntegrity-AllowConfigurablePolicy`, enable.

Generally, __CKS__ is disabled by default on any edtions of Windows10 except __Windows10 China Government Edition__. 

If a Windows10 PC meets the following conditions:

1. The product policy `CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners` is enabled. 
  (May be `CodeIntegrity-AllowConfigurablePolicy` is also required.)

2. SecureBoot is enabled.

one can add a certificate to kernel certificate store if he owns the PC's UEFI Platform Key so that he can lanuch any drivers signed by the certificate on that PC.

If you are interested in looking for other product policies, you can see [this](https://www.geoffchappell.com/notes/windows/license/install.htm).

## 2. How to enable this feature?

### 2.1 Prerequisites

1. You must have administrator privilege.

2. You need a temporary environment whose OS is Windows10 Enterprise or Education.

   Why? Because you need it to execute `ConvertFrom-CIPolicy` in Powershell which cannot be done in other editions of Windows10.

3. You are able to set UEFI Platform Key.

### 2.2 Create certificates and set Platform Key(PK)

Please follow [this](asset/build-your-own-pki.md) to create certificates. After that you will get following files:

```
// self-signed root CA certificate
localhost-root-ca.der
localhost-root-ca.pfx

// kernel mode certificate issued by self-signed root CA
localhost-km.der
localhost-km.pfx

// UEFI Platform Key certificate issued by self-signed root CA
localhost-pk.der
localhost-pk.pfx
```

As for how to set PK in UEFI firmware, please do it yourself because different UEFI firmware has different methods. Here, I only tell you how to do it in VMware.

#### 2.2.1 Set PK in VMware

If your VMware virtual machine's name is `TestVM` and your vm has SecureBoot, there would be two files under your vm's folder: `TestVM.nvram` and `TestVM.vmx`. You can set PK by the following:

1. Close your vm.

2. Delete `TestVM.nvram`. This would reset your vm's UEFI settings next time your vm starts.

3. Open `TestVM.vmx` by a text editor and append the following two lines:

   ```
   uefi.allowAuthBypass = "TRUE"
   uefi.secureBoot.PKDefault.file0 = "localhost-pk.der"
   ```

   The first line allows you manage SecureBoot keys in UEFI firmware.

   The second line will make `localhost-pk.der` in vm's folder as default UEFI PK. If `localhost-pk.der` is not in vm's folder, please specify a full path.

Then start `TestVM` and your PK has been set.

### 2.3 Build kernel code-sign certificate rules

Run Powershell as administrator in Windows10 Enterprise/Education edition.

1. Use `New-CIPolicy` to create new CI (Code Integrity) policy. Please make sure that the OS is not affected with any malware.

   ```powershell
   New-CIPolicy -FilePath SiPolicy.xml -Level RootCertificate -ScanPath C:\windows\System32\
   ```

   It will scan the entire `System32` folder and take some time. If you do not want to scan, you can use [SiPolicy.xml](asset/SiPolicy.xml) I prepared.

2. Use `Add-SignerRule` to add our own kernel code-sign certificate to `SiPolicy.xml`.

   ```powershell
   Add-SignerRule -FilePath .\SiPolicy.xml -CertificatePath .\localhost-km.der -Kernel
   ```

3. Use `ConvertFrom-CIPolicy` to serialize `SiPolicy.xml` and get binary file `SiPolicy.bin`

   ```powershell
   ConvertFrom-CIPolicy -XmlFilePath .\SiPolicy.xml -BinaryFilePath .\SiPolicy.bin
   ```

Now our policy rules has been built. The newly-generated file can be applied to any editions of Windows10 once it is signed by PK certificate. From now on, we don't need Windows10 Enterprise/Education edition.

### 2.4 Sign policy rules and apply policy rules

1. For `SiPolicy.bin`, we should use PK certificate to sign it. If you have Windows SDK, you can sign it by `signtool`.

   ```
   signtool sign /fd sha256 /p7co 1.3.6.1.4.1.311.79.1 /p7 . /f .\localhost-pk.pfx /p <password of localhost-pk.pfx> SiPolicy.bin
   ```

   __Please fill `<password of localhost-pk.pfx>` with password of your `localhost-pk.pfx`.__

   Then you will get `SiPolicy.bin.p7` at current directory.

2. Rename `SiPolicy.bin.p7` to `SiPolicy.p7b` and copy `SiPolicy.p7b` to `EFI\Microsoft\Boot\`

   ```powershell
   # run powershell as administrator
   mv .\SiPolicy.bin.p7 .\SiPolicy.p7b
   mountvol x: /s
   cp .\SiPolicy.p7b X:\EFI\Microsoft\Boot\
   ```

### 2.5 Enable CustomKernelSigners

The variable that controls __CKS__ enable or not is stored in `ProductPolicy` value whose key path is `HKLM\SYSTEM\CurrentControlSet\Control\ProductOptions`.

Although administrators can modify this value, the value will be reset immediately once modified. This is because this value is just a mapping of a varialbe in kernel once kernel is initialized. The only way to modify the variable is to call `ExUpdateLicenseData`. However, this API could only be called in kernel mode or indirectly called by calling `NtQuerySystemInformation` with `SystemPolicyInformation`. Unfortunately, the latter way succeeds only when caller is a protected process.

So we could only modify it when kernel has not finished initialization. Do we have a chance? Yes, Windows Setup Mode can give us a chance.

I've built a program to help us enable __CKS__. The code in under `EnableCustomKernelSigners` folder and the binary executable file `EnableCKS.exe` can be downloaded on [release](https://github.com/HyperSine/Windows10-CustomKernelSigners/releases) page. Of course, you can build it with your own.

Double click `EnableCKS.exe` and you can see

```
[+] Succeeded to open "HKLM\SYSTEM\Setup".
[+] Succeeded to set "CmdLine" value.
[+] Succeeded to set "SetupType" value.

Reboot is required. Are you ready to reboot? [y/N]
```

Type `y` to reboot. Then system will enter Setup Mode. `EnableCKS.exe` will run automaticly and enable the following two policy

```
CodeIntegrity-AllowConfigurablePolicy
CodeIntegrity-AllowConfigurablePolicy-CustomKernelSigners
```

Finally, system will reboot again and go back to normal mode.

### 2.6 Persist CustomKernelSigners

Now you should be able to load drivers signed by `localhost-km.pfx`. But wait for a minute. Within 10 minutes, __CKS__ will be reset to disable by `sppsvc` except when you have Windows10 China Government Edition. Don't worry, it takes effect only next time system starts up.

So we have to load a driver to call `ExUpdateLicenseData` continuously to persist __CKS__. I've built a driver named `ckspdrv.sys` which can be downloaded on [release](https://github.com/HyperSine/Windows10-CustomKernelSigners/releases) page. The code is in `CustomKernelSignersPersistent` folder.

`ckspdrv.sys` is not signed. You must sign it with `localhost-km.pfx` so that it can be loaded into kernel.

```
signtool sign /fd sha256 /ac .\localhost-root-ca.der /f .\localhost-km.pfx /p <password of localhost-km.pfx> /tr http://sha256timestamp.ws.symantec.com/sha256/timestamp ckspdrv.sys
```

__Please fill `<password of localhost-km.pfx>` with password of your `localhost-km.pfx`.__

Then move `ckspdrv.sys` to `c:\windows\system32\drivers` and run `cmd` as administrator:

```
sc create ckspdrv binpath=%windir%\system32\drivers\ckspdrv.sys type=kernel start=auto error=normal
sc start ckspdrv
```

If nothing wrong, `ckspdrv.sys` will be loaded successfully, which also confirms that our policy rules have take effect.

Now you can load any driver signed by `localhost-km.pfx`. Have fun and enjoy~

