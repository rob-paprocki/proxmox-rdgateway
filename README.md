# proxmox-rdgateway

Build a Windows Server 2025 Remote Desktop Gateway on Proxmox VE, without clicking through
the wizard twice and without guessing at the WMI calls.

| File | Runs on | Does |
|---|---|---|
| [`windows-rdgw-vm.sh`](windows-rdgw-vm.sh) | Proxmox host, as root | Interactive VM builder — q35 + OVMF, Secure Boot, TPM 2.0, VirtIO SCSI, both ISOs attached |
| [`Setup-RDGateway.ps1`](Setup-RDGateway.ps1) | Inside the guest, elevated | Installs the RDS-Gateway role, binds a certificate, writes the CAP and RAP, opens the firewall |

```bash
# on the Proxmox host
DRY_RUN=1 bash windows-rdgw-vm.sh   # show the qm commands, run nothing
bash windows-rdgw-vm.sh             # actually build it
```

```powershell
# inside the guest, in Windows PowerShell (not pwsh), elevated
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld -CertificateSource SelfSigned
```

Neither script installs Windows — there is no cloud image for it. The builder stops at a
correctly configured VM shell with the boot order set; you run Setup from the console.

The rest of this file is the runbook: the decisions to make first, the manual install, the
certificate, and the DNS and port-forwarding work that has to happen around the scripts.

MIT licensed. Built with Claude.

---

## Runbook

A VM, not an LXC. The gateway has to be Windows, and a Proxmox container shares the host kernel — Windows can't live in one.

---

## Phase 0 — Decide two things before you touch anything

**The hostname clients will type.** Something like `rdg.yourdomain.tld`. It has to resolve from the public internet to your WAN address, and the certificate has to match it. If your ISP gives you a dynamic address, point it at a DDNS record. Pick this name now; it gets baked into the certificate and into every client profile.

**Where the certificate comes from.** This is the one decision that determines whether the thing is pleasant or annoying to use.

A real certificate from Let's Encrypt is free and every client trusts it silently. [win-acme](https://www.win-acme.com/) is the standard ACME client for Windows, it's open source (Apache 2.0), and it ships a script that binds the cert to the gateway and restarts the service on every renewal (Phase 4 has the wiring). Since you already run domains on Cloudflare, the clean path is win-acme with the Cloudflare DNS-01 validation plugin — no inbound port 80 needed, and it works even when the name points at a dynamic address.

A self-signed certificate works technically, but every client has to be told to trust it. On Windows that's an MMC import into Trusted Root; on Android it's fiddly and on iOS it involves a profile. The script will generate one and export the public half so you can test end to end, but treat it as scaffolding.

---

## Phase 1 — Build the VM

Copy `windows-rdgw-vm.sh` to the Proxmox host and run it as root:

```bash
bash windows-rdgw-vm.sh
```

Read-only first pass, if you want to see the `qm` commands without anything happening:

```bash
DRY_RUN=1 bash windows-rdgw-vm.sh
```

It asks default-or-advanced, then walks you through picking the Windows ISO, the VirtIO driver ISO, and the storage. It will find your `en-us_windows_server_2025_updated_aug_2026_x64_dvd_b0833651.iso` on `local`. If there's no `virtio-win.iso` in any storage it offers to download one (~700 MB from fedorapeople.org).

The defaults are 4 cores, 6 GiB RAM, 80 GiB disk, q35 + OVMF, Secure Boot with the Microsoft keys pre-enrolled, TPM 2.0, VirtIO SCSI single with writeback and discard, and a VirtIO NIC. Server 2025 doesn't *require* a TPM to install — that's a Windows 11 client thing — but BitLocker and Credential Guard do, and it costs 4 MiB, so it's on by default.

Every command it runs is printed before it runs, so you can follow along or lift them out and do it by hand.

---

## Phase 2 — Install Windows

Open the console from the Proxmox web UI. Two things trip people up:

**Press a key fast.** "Press any key to boot from CD or DVD" times out in about five seconds. Miss it and you land in the UEFI shell — type `exit`, choose Boot Manager, pick the DVD drive.

**Windows Setup will show you no disks.** That is expected, not a failure. Windows has no idea what a VirtIO SCSI controller is. Click **Load driver** → **Browse** → the second CD drive → `vioscsi\2k25\amd64` → Next. Your 80 GiB disk appears. While you're in there, load `NetKVM\2k25\amd64` too so the NIC works on first boot.

Pick a **(Desktop Experience)** edition unless you genuinely want to run this from Server Core.

---

## Phase 3 — Post-install housekeeping

Inside Windows, before you configure anything:

1. **Run `virtio-win-guest-tools.exe`** from the VirtIO CD. That installs the balloon driver, the QEMU guest agent, and the rest of the VirtIO stack in one go. Proxmox will start reporting the guest's IP once the agent is running.
2. **Pin the IP.** Either a static address in Windows or a DHCP reservation in UniFi. A gateway whose address moves is a gateway you can't port-forward to.
3. **Rename the machine** to something you'll recognise, and reboot. `Setup-RDGateway.ps1` reads whatever name you pick, but the sample `.rdp` file in Phase 7 hard-codes `RDGW01`, so change that line to match.
4. **Windows Update** until it stops finding things.
5. **Detach the ISOs** from the Proxmox host so it stops trying to boot the DVD:
   ```bash
   qm set <VMID> --ide0 none --ide2 none --boot order=scsi0
   ```
6. **Set a serious password** on whatever account you'll use. You are about to put an authentication endpoint on the public internet. Also worth setting a lockout policy: `secpol.msc` → Account Policies → Account Lockout Policy, 10 attempts / 15 minutes is a reasonable floor.

---

## Phase 4 — Certificate

If you're going the Let's Encrypt route, do it before running the setup script so the script can just bind the result.

Download win-acme, unzip it somewhere permanent like `C:\win-acme`, and run `wacs.exe` as admin. Choose the full options menu, pick a manual certificate for your FQDN, and choose **DNS-01** validation with the Cloudflare plugin (it will ask for an API token scoped to `Zone:DNS:Edit` on that zone).

At the installation step there is no "RD Gateway" plugin — win-acme only ships two, **IIS bindings** and **Script**. Choose **Script**, and point it at the one win-acme bundles for exactly this job:

```
Script:     C:\win-acme\Scripts\ImportRDGateway.ps1
Arguments:  {CertThumbprint}
```

That script copies the certificate into `LocalMachine\My` if it isn't there, sets `RDS:\GatewayServer\SSLCertificate\Thumbprint`, and restarts `TSGateway` — the same binding call `Setup-RDGateway.ps1` makes. win-acme registers a scheduled task that runs **daily** and renews whenever the certificate falls inside its renewal window (55 days after issue, by default), re-running the script each time.

Then run the setup script with `-CertificateSource Existing -Thumbprint <the thumbprint win-acme reported>`, or just skip the certificate entirely — win-acme will already have bound it.

If you're testing first, let the script make a self-signed one and import the exported `.cer` into **Trusted Root Certification Authorities** on your client machine.

---

## Phase 5 — Configure the gateway

Copy `Setup-RDGateway.ps1` into the VM. Run it from an **elevated Windows PowerShell** prompt (not `pwsh` — the WMI fallback path wants Windows PowerShell 5.1, which is what ships in the box).

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld -CertificateSource SelfSigned
```

or, with a real certificate already installed:

```powershell
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld `
                      -CertificateSource Existing `
                      -Thumbprint A1B2C3D4E5F6...
```

Installing the role pulls in IIS and Network Policy Server and takes a few minutes. If Windows asks for a reboot, reboot and re-run with `-SkipRoleInstall`.

### What the two policies mean

RD Gateway has two gates and a connection has to pass both.

The **CAP** (connection authorization policy) answers *who may use this gateway at all*. The script creates one allowing the local `Administrators` and `Remote Desktop Users` groups, with password authentication.

The **RAP** (resource authorization policy) answers *what they may reach through it*. This is the one that matters for security. By default the script scopes it to this server only — it builds a resource group containing the machine's own name, FQDN, `localhost` and its IP addresses. The alternative, `-ResourceScope AnyResource`, lets anyone who passes the CAP RDP to **any machine the gateway can reach**, which turns this box into a jump host into your whole LAN. That's sometimes exactly what you want, but it should be a decision rather than a default.

To restrict by user instead, create a dedicated local group and pass it in:

```powershell
New-LocalGroup -Name 'RDG Users'
Add-LocalGroupMember -Group 'RDG Users' -Member 'rob'
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld `
                      -AllowedGroups "RDG Users@$env:COMPUTERNAME"
```

Note the `@` suffix convention: built-in groups are `Administrators@BUILTIN`, groups you create are `GroupName@COMPUTERNAME`, domain groups are `GroupName@DOMAIN`.

The script uses the documented `Win32_TSGateway*` WMI classes rather than the `RDS:` PowerShell provider for the policies, because the WMI method signatures spell out what each flag means. The certificate binding is the exception — that goes through `RDS:\GatewayServer\SSLCertificate\Thumbprint`, which is the well-trodden path, with a WMI fallback and, failing both, instructions for doing it in `tsgateway.msc`.

---

## Phase 6 — DNS and the router

On your router, forward to the VM's LAN address:

- **TCP 443** — required. This is the HTTPS tunnel the whole thing rides on.
- **UDP 3391** — optional but worth it. RD Gateway uses it for the graphics stream, and it makes a high-latency link feel dramatically better.

**Do not forward 3389.** The entire point of the gateway is that raw RDP never faces the internet.

Then confirm `rdg.yourdomain.tld` resolves to your WAN address from outside your network. Test from cellular data, not from inside the LAN — a lot of consumer routers don't hairpin, so an inside test can fail while the outside one works fine.

---

## Phase 7 — Connect

**From Windows**, the built-in `mstsc.exe` is the reliable client. Advanced tab → *Connect from anywhere* → Settings → "Use these RD Gateway server settings", server name `rdg.yourdomain.tld`, logon method "Ask for password (NTLM)", and tick **"Use my RD Gateway credentials for the remote computer"**. Then on the General tab, the computer is the server's own name (`RDGW01`), not the gateway name.

**An `.rdp` file** saves the fiddling and works across clients — save this as `rdgw01.rdp` and double-click it:

```
full address:s:RDGW01
gatewayhostname:s:rdg.yourdomain.tld
gatewayusagemethod:i:1
gatewaycredentialssource:i:0
gatewayprofileusagemethod:i:1
promptcredentialonce:i:1
authentication level:i:2
```

`gatewayusagemethod:i:1` means always use the gateway; `gatewayprofileusagemethod:i:1` means use these explicit settings rather than any admin-pushed profile; `promptcredentialonce:i:1` reuses the gateway credentials for the target so you only type them once.

**On Android**, the Windows App is the current client, and it inherits the Gateways screen from the old Remote Desktop app — add the gateway there first, then attach it to the PC connection. Note that the Windows App **cannot import `.rdp` files**; that capability was dropped, so connections have to be recreated by hand on each device. Microsoft documents the Windows App's gateway settings for macOS and iOS/iPadOS explicitly; Android isn't covered in that article, so if the Gateways screen isn't where you expect it, that's the thing to go looking for.

### Watching it work

On the gateway:

```powershell
Get-WinEvent -LogName Microsoft-Windows-TerminalServices-Gateway/Operational -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

Event **200** means the client reached the gateway. **300** means the RAP authorized the target. **302** means traffic is flowing through to it. If you see 200 but never 300, your RAP doesn't list the name the client asked for — check what name you put in "Computer" against the resource group the script built.

---

## Things worth knowing

**Sessions.** Windows Server allows two concurrent administrative RDP sessions with no RDS licensing and no license server. That's the mode you're in. Going beyond two means the RD Session Host role and paid RDS CALs.

**Licensing, honestly.** Microsoft's terms call for an RDS CAL for connections made *through* an RD Gateway, even in the two-admin-session case. There is no technical enforcement — the 120-day grace period timer belongs to RD Session Host, not RD Gateway, so nothing will stop working. It's a compliance question, not a functional one, and for a personal home lab you can weigh it accordingly. I'm not a lawyer and this isn't legal advice.

**You are putting an auth endpoint on the internet.** RD Gateway is a mature, well-audited piece of software, but it has had remote code execution bugs before (CVE-2020-0609/0610 were pre-auth). Keep the VM patched, keep passwords strong, keep the RAP scoped to this server, and watch event 4625 in the Security log for credential stuffing. If you want a second factor, the supported route is installing the NPS Extension for Microsoft Entra MFA on this box and pointing the CAP at a central NPS store — that's a bigger project and it drags you into Entra.

**The FOSS alternative, stated once.** Everything above exists because you asked for a real RD Gateway. If the goal is just "reach my Windows box from anywhere", WireGuard or Tailscale on the Proxmox host gets you there with no roles, no certificates, no ports open to the world, and no CAL question — and you'd RDP to the LAN address once you're on the tunnel. Worth keeping in your back pocket if the gateway turns into a maintenance burden.

---

## Undo

```bash
qm stop <VMID> && qm destroy <VMID> --destroy-unreferenced-disks 1 --purge
```

---

## Sources

- [Windows 2025 guest best practices — Proxmox VE wiki](https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices)
- [qm(1) — Proxmox VE](https://pve.proxmox.com/pve-docs/qm.1.html)
- [Hardware requirements for Windows Server — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/get-started/hardware-requirements)
- [Remote Desktop Services — Access from anywhere](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-plan-access-from-anywhere)
- [Win32_TSGatewayConnectionAuthorizationPolicy.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayconnectionauthorizationpolicy)
- [Win32_TSGatewayResourceAuthorizationPolicy.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayresourceauthorizationpolicy)
- [Win32_TSGatewayResourceGroup.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayresourcegroup)
- [License Remote Desktop Services with CALs](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-client-access-license)
- [Remote Desktop client — supported configuration](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-supported-config)
- [Supported RDP properties](https://learn.microsoft.com/azure/virtual-desktop/rdp-properties)
- [Integrate RD Gateway with the NPS extension and Microsoft Entra ID](https://learn.microsoft.com/entra/identity/authentication/howto-mfa-nps-extension-rdg)
- [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE/tree/main/vm) — the script style this follows
- [win-acme](https://www.win-acme.com/), its [installation plugins](https://www.win-acme.com/reference/plugins/installation/) and [ImportRDGateway.ps1](https://github.com/win-acme/win-acme/blob/master/dist/Scripts/ImportRDGateway.ps1)
- [Win32_TSGatewayServerSettings.Configure](https://learn.microsoft.com/windows/win32/termserv/configure-win32-tsgatewayserversettings)
