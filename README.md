# proxmox-rdgateway

Build a Windows Server 2025 Remote Desktop Gateway on Proxmox VE, without clicking through
the wizard twice and without guessing at the WMI calls.

| File | Runs on | Does |
|---|---|---|
| [`windows-rdgw-vm.sh`](windows-rdgw-vm.sh) | Proxmox host, as root | Interactive VM builder: q35 + OVMF, Secure Boot, TPM 2.0, VirtIO SCSI. Optionally builds an unattend ISO so the whole thing installs itself |
| [`Setup-RDGateway.ps1`](Setup-RDGateway.ps1) | Inside the guest, elevated | Installs the RDS-Gateway role, binds a certificate, writes the CAP and RAP, opens the firewall |
| [`Configure-Guest.ps1`](Configure-Guest.ps1) | Inside the guest, as SYSTEM | Applies the security and housekeeping answers given during the build |
| [`Invoke-GatewaySetup.ps1`](Invoke-GatewaySetup.ps1) | Inside the guest, as SYSTEM | Drives the build from inside. Registers the first-boot task, then survives the role-install reboot |
| [`Invoke-CustomScripts.ps1`](Invoke-CustomScripts.ps1) | Inside the guest | Runs scripts of your own, in the four categories, at the right moment |
| [`Get-RDGWStatus.ps1`](Get-RDGWStatus.ps1) | Inside the guest, elevated | Read-only. Prints what the build was asked to do next to what the machine actually has |
| [`Invoke-WinAcme.ps1`](Invoke-WinAcme.ps1) | Inside the guest, as SYSTEM | Installs win-acme and, if you asked it to, gets the Let's Encrypt certificate |
| [`vps-relay-setup.sh`](vps-relay-setup.sh) | A small public VPS | *Optional.* Layer 4 front door so nothing has to be open at home |
| [`proxmox-relay-peer.sh`](proxmox-relay-peer.sh) | Proxmox host, as root | *Optional.* Home end of that relay: outbound WireGuard, forwarding, NAT |

On the Proxmox host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/proxmox-rdgateway/main/windows-rdgw-vm.sh)"
```

Or from a checkout, which is the better way to read it first:

```bash
DRY_RUN=1 bash windows-rdgw-vm.sh   # print every command, write nothing
bash windows-rdgw-vm.sh             # actually build it
```

That one script asks whether you want an unattended build. Say yes and it puts a short set
of questions to you (account name, password, lockout policy, external FQDN, which machines
to reach), then writes a third CD holding an answer file, the VirtIO drivers and the setup
scripts. Windows installs itself, a startup task installs the RD Gateway role and runs
`Setup-RDGateway.ps1`, and you come back to a working gateway after two or three reboots and
thirty to forty-five minutes.

Say no and you get a correctly configured VM shell with both ISOs attached, and you drive
Setup yourself. That path is documented below in full, and it is the one to fall back on
when something in the automated build misbehaves.

```powershell
# the manual path, inside the guest, in Windows PowerShell (not pwsh), elevated
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld `
                      -CertificateSource SelfSigned `
                      -TargetMachines 'DESKTOP-01','NAS01','192.168.1.60'
```

That is what `-TargetMachines` is for: one public hostname, many machines behind it. The
targets install nothing: they need Remote Desktop on, your account in their Remote Desktop
Users group, and a name the gateway can resolve. Windows Pro is fine as a target; only the
gateway itself has to be Server.

**Cloudflare Tunnel cannot carry this.** RD Gateway's transport uses the custom HTTP methods
`RDG_IN_DATA` and `RDG_OUT_DATA`, and Cloudflare's edge answers both with `501` before the
request reaches your origin, so a proxied hostname breaks the gateway outright. Grey-cloud
any DNS record pointing at it. [`RELAY.md`](RELAY.md) explains the failure, has the one-line
test to confirm it, and sets up a VPS relay as the alternative for people who don't want an
open port. Client devices install nothing either way.

MIT licensed. Built with Claude.

## Runbook

The rest of this file is the runbook: the decisions to make first, the manual install, the
certificate, and the DNS and port-forwarding work that has to happen around the scripts.

A VM, not an LXC. The gateway has to be Windows, and a Proxmox container shares the host
kernel, so Windows cannot live in one.

## Phase 0: decide two things before you touch anything

**The hostname clients will type.** Something like `rdg.yourdomain.tld`. It has to resolve from the public internet to wherever you terminate, which is your WAN address if you forward a port or a relay's address if you use the one in [`RELAY.md`](RELAY.md), and the certificate has to match it. If your ISP gives you a dynamic address, point it at a DDNS record. Pick this name now; it gets baked into the certificate and into every client profile.

**Where the certificate comes from.** This is what decides whether the thing is pleasant or annoying to use.

A real certificate from Let's Encrypt is free and every client trusts it silently. [win-acme](https://www.win-acme.com/) is the standard ACME client for Windows, it's open source (Apache 2.0), and it ships a script that binds the cert to the gateway and restarts the service on every renewal. If your domain is already on Cloudflare, the clean path is win-acme with the Cloudflare DNS-01 validation plugin: no inbound port 80, and it works even when the name points at a dynamic address. The build can install win-acme for you and can run it too, which is what Phase 4 covers.

A self-signed certificate works technically, but every client has to be told to trust it. On Windows that's an MMC import into Trusted Root; on Android it's fiddly and on iOS it needs a configuration profile plus a separate full-trust toggle buried in Settings. The build generates one regardless and exports the public half, so you can prove the gateway works end to end, but treat it as scaffolding rather than the destination.

One thing worth deciding now, because it is permanent: a certificate naming your gateway publishes that name to the Certificate Transparency logs, forever and publicly, and people scrape those logs for `rdg.`, `vpn.` and `remote.`. A wildcard costs nothing extra over DNS-01 validation and never names the host, so the build proposes one by default.

## Phase 1: build the VM

Copy `windows-rdgw-vm.sh` to the Proxmox host and run it as root:

```bash
bash windows-rdgw-vm.sh
```

Read-only first pass, if you want to see the `qm` commands without anything happening:

```bash
DRY_RUN=1 bash windows-rdgw-vm.sh
```

It asks default-or-advanced, then walks you through picking the Windows ISO, the VirtIO driver ISO, and the storage. It lists the Windows ISOs already sitting in your storages, so something like `en-us_windows_server_2025_updated_aug_2026_x64_dvd_b0833651.iso` on `local` shows up as a menu entry. If there's no `virtio-win.iso` in any storage it offers to download one (~700 MB from fedorapeople.org).

The defaults are 4 cores, 6 GiB RAM, 80 GiB disk, q35 + OVMF, Secure Boot with the Microsoft keys pre-enrolled, TPM 2.0, VirtIO SCSI single with writeback and discard, and a VirtIO NIC. Server 2025 doesn't *require* a TPM to install, which is a Windows 11 client requirement rather than a server one, but BitLocker and Credential Guard both want one and it costs 4 MiB, so it's on by default.

Every command it runs is printed before it runs, so you can follow along or lift them out and do it by hand.

### Running it from curl

The one-liner at the top works for both paths:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/proxmox-rdgateway/main/windows-rdgw-vm.sh)"
```

The unattended path needs six more files to put on the ISO it builds: `Setup-RDGateway.ps1`, `Configure-Guest.ps1`, `Invoke-GatewaySetup.ps1`, `Invoke-CustomScripts.ps1`, `Get-RDGWStatus.ps1` and `Invoke-WinAcme.ps1`. Each is resolved on its own: a local copy always wins, and only the ones actually missing are fetched. From a checkout nothing is downloaded and your edits are used. Every URL is printed before it is touched.

Those files are copied to the unattend CD and run *inside the guest*. They are never executed on the Proxmox host, and neither is anything you add through the custom-scripts menu.

Pin a branch or tag if you don't want to track `main`:

```bash
REPO_REF=v1.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/proxmox-rdgateway/v1.0/windows-rdgw-vm.sh)"
```

`REPO_RAW` overrides the base URL outright, for a fork or an internal mirror.

### The unattended questions

Say yes to "unattended install" and it asks the following. Nothing here has a safe default it can guess for you, so it asks in both default and advanced mode.

| Question | Default | Notes |
|---|---|---|
| Local administrator account name | `rdgadmin` | Deliberately not `admin`. Type whatever you want. |
| Password | none | Asked twice. Leave it empty for a blank password; it will confirm that you meant it. |
| External FQDN | `rdg.example.com` | Passed straight to `Setup-RDGateway.ps1 -ExternalFqdn`. |
| Certificate | Install win-acme, leave one command | Three answers, covered below. A self-signed certificate is generated either way. |
| Windows time zone ID | `Eastern Standard Time` | The Windows name, not the IANA one. `tzutil /l` lists them. |
| What clients may reach | Any machine the gateway can reach | Three options. "Only machines I name" then asks for a space separated list. See [what the two policies mean](#what-the-two-policies-mean). |
| Edition | Standard (Desktop Experience) | Picks the image name and the matching GVLK together so they can't drift apart. There are Evaluation entries, which correctly send no key at all. |
| Product key | the edition's generic key | Standard and Datacenter also offer a real retail or MAK key here. The generic volume key only selects the edition and expects a KMS host; a real key activates outright. It rides the answer file in clear text like the password, and the ISO is deleted on success. |
| Lockout threshold | `10` | `0` disables lockout entirely. |
| Lockout window | `15` minutes | Used for both the window and the duration. |
| Disable UAC | no | |
| Disable Defender | no | |
| Disable Core Isolation | no | |
| Disable IPv6 | no | See below. |
| Require Ctrl+Alt+Del | no | The one that defaults to the *less* strict answer, because sending Ctrl+Alt+Del to a Proxmox console is a menu trip rather than a keystroke. |
| Housekeeping settings | yes | 8.3 names off, fast startup off, long paths on, WPBT off, no Windows Update auto-reboot, system sounds off, NumLock on, and Explorer/taskbar/theme defaults suited to RDP. |
| IP addressing | DHCP | A gateway behind a port-forward wants a fixed address. Choose static to set the address, prefix, gateway and DNS; it is applied in the first-boot pass and falls back to DHCP if anything about it is wrong. Reserving a DHCP lease on your router is the alternative. |
| OpenSSH server | no | Installs the OpenSSH server and makes PowerShell the default shell, so you can administer the box with `ssh rdgadmin@<ip>` instead of the Proxmox console. Opens TCP 22 on the LAN. |
| Custom scripts | no | Opens a menu: write scripts of your own here, or import files you already have. |

The four security toggles all default to leaving Windows exactly as it ships. They are there so you can loosen them deliberately; each prompt states what it costs, and then does what you picked without arguing further.

IPv6 is the odd one out, because the reason to keep it is this project's rather than Windows'. Most ISPs hand out a routable v6 prefix even when v4 is carrier-graded, so an AAAA record and a firewall rule reach the gateway with no relay, no port forward and no spend. Turning v6 off gives that up, and Microsoft advises against turning it off anyway. It defaults to on.

**Check your media before you pick an edition.** The image name has to match the ISO exactly, and Evaluation media names its images differently:

```bash
# on any machine with the ISO mounted
dism /Get-WimInfo /WimFile:<mount>\sources\install.wim
```

A retail or volume-licence ISO reports `Windows Server 2025 Standard (Desktop Experience)`. The free Evaluation ISO reports `Windows Server 2025 Standard Evaluation (Desktop Experience)`, and a GVLK cannot activate it: evaluation has to be converted with `DISM /online /Set-Edition` first. Pick the matching entry from the menu, or the "type the image name myself" option.

### Custom scripts

Say yes and you get a small menu that stays open until you are done:

```
Custom scripts (2 so far)

  write    Write a new script here
  import   Import a file or a directory from this host
  review   Review what will be included, or remove one
  done     Finished
```

`write` asks two questions and then opens an editor. First *when* it should run, then *what kind* it is:

| Phase | When it runs | As whom |
|---|---|---|
| `System` | During the specialize pass, before any profile, desktop or logon exists | SYSTEM |
| `DefaultUser` | Also in specialize, with `C:\Users\Default\NTUSER.DAT` mounted | SYSTEM |
| `FirstLogon` | The first interactive logon | That user, elevated |
| `UserOnce` | Each new user's first logon | That user |

| Kind | Extension | Run with |
|---|---|---|
| PowerShell | `.ps1` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` |
| Batch | `.cmd` | `cmd.exe /c` |
| Registry | `.reg` | `reg.exe import` |

It suggests a filename numbered in tens: `010-script.ps1`, then `020-`, then `030-`, leaving room to slot something in between later. The number comes from the highest one already in that phase rather than a count, so removing a script does not hand you a name that is still in use, and it is zero padded because the guest sorts on that number. Spaces become hyphens on the way in.

Then it opens the first of `$VISUAL`, `$EDITOR`, `nano`, `vim` or `vi` that it finds, on a file already seeded with a header saying where the script will run and what will run it:

```powershell
# FirstLogon script for this RD Gateway build.
#
# Runs at:     the first interactive logon, elevated
# Started as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File
#
# Output and the exit code go to C:\Windows\Setup\Scripts\rdgw-setup.log.
# A non-zero exit is logged and skipped rather than stopping the build, and
# anything still running after fifteen minutes is killed.
```

Save with nothing added and it tells you so and throws the file away. If the box has no editor at all it falls back to reading the script off the terminal until you type `EOF` on a line by itself.

`import` takes a file or a whole directory. A single file asks which phase it belongs to. A directory is read from subdirectories named for the phases, and anything sitting loose at the top level is offered separately as `System` scripts:

```
/root/rdgw-scripts/
  System/10-import-cert.ps1
  System/20-install-tools.cmd
  DefaultUser/10-explorer.reg
  UserOnce/10-map-drives.ps1
```

`review` lists everything staged so far and lets you drop one.

Both routes end in the same place, so you can write one script by hand, import a directory of others, and ship them together. Within a phase they run in order of that leading number, so `020-` follows `010-` and `100-` comes last; anything unnumbered runs after everything that is numbered. `.ps1`, `.cmd`, `.bat` and `.reg` are recognised; anything else is ignored.

`System` runs long before the gateway role is installed, so a script there can put something in place that the gateway later uses. Importing a real certificate into `LocalMachine\My`, for instance, saves you the self-signed one. Specialize is early enough that the NIC driver is loaded but DHCP may not have finished, so put anything that needs the internet in `FirstLogon` instead. A script that fails, or that runs longer than fifteen minutes, is logged and skipped rather than stopping the build; everything lands in the same `rdgw-setup.log`, prefixed `custom/<category>`.

A `.reg` file in `DefaultUser` is rewritten before import: the bracketed key headers naming `HKEY_CURRENT_USER` are retargeted at the mounted hive, because there is no current user at that point. Write it as though you were the logged-on user and it will land in every profile created afterwards.

A `.ps1` or `.cmd` in `DefaultUser` gets no such rewrite, and it matters more than it sounds: with nobody logged on, `HKCU:` is SYSTEM's own profile, so a write there succeeds, logs `ok`, and reaches nothing. The mounted hive is in `$env:RDGW_HIVE_PATH`, and the seeded header says so.

The answer file logs the new account on automatically, exactly once, and that profile is created from the Default User hive. `FirstLogon` catches that first automatic logon reliably because the answer file registers it during the specialize pass, ahead of any logon. `UserOnce` is registered in the Default User hive and may not reach that very first profile, so put anything the first account must have in `FirstLogon`.

### What lands on the unattend CD

Five things, and `DRY_RUN=1` prints the generated answer file in full so you can read it before anything is written:

- `autounattend.xml`. Windows Setup finds this by itself. It scans the root of every removable drive looking for exactly that filename, so no boot-order change is needed.
- `$WinPEDriver$\`, holding `vioscsi`, `viostor` and `NetKVM` from `2k25\amd64`. Windows Server scans every drive letter from C upward for a directory with this name during the windowsPE pass and stages every INF underneath it. That is what removes the **Load driver** step.
- `rdgw\*.ps1`, copied to `C:\Windows\Setup\Scripts` during the specialize pass.
- `rdgw\rdgw-config.psd1`, every answer you gave, as plain data.
- `rdgw\custom\`, your own scripts if you supplied any. Carried across by the same copy step, so no extra answer-file command is needed to place them.

[`sample-autounattend.xml`](sample-autounattend.xml) is a committed copy of what a default run produces, so the shape is reviewable without running anything.

The CD is attached on `sata0`, because q35 gives you only `ide0` and `ide2` and both are already holding the Windows and VirtIO ISOs. It is written mode 600 because the answer file carries the account password in clear text. Base64 in an answer file is obfuscation rather than encryption, so nothing here pretends otherwise: a build that finishes deletes the ISO itself, and [Undo](#undo) covers the cases where it could not.

## Phase 2: install Windows

### If you chose the unattended path

Nothing to do. It is here so you know what is happening and where to look if it stalls.

1. The script answers the DVD's "Press any key to boot from CD or DVD" prompt from the host with `qm sendkey`, watching the DVD's byte counter to know when the prompt is actually on screen. See [the boot prompt](#the-boot-prompt) for why the prompt is answered rather than removed.
2. Windows Setup finds `autounattend.xml` on the unattend CD and stages the VirtIO drivers from `$WinPEDriver$`.
3. It wipes disk 0, the only disk this VM has, and partitions it EFI 300 MiB, MSR 16 MiB, then NTFS for the rest. There is deliberately no explicit recovery partition: Windows creates the WinRE partition itself on an NTFS boot volume by shrinking the OS volume on first boot.
4. It installs the edition you chose.
5. The specialize pass copies the scripts to `C:\Windows\Setup\Scripts`, applies your answers, writes the Default User hive, runs any `System` scripts of yours, and registers a startup task called `RDGW-FirstBoot`.
6. That task installs the VirtIO guest tools, removes the Defender feature if you asked for that and takes the reboot it needs, installs the RD Gateway role, then runs `Setup-RDGateway.ps1` and checks that the `TSGateway` service came up.
7. Last, it does whatever you chose for the certificate. That step is last because it needs the role to exist, and because the self-signed certificate is bound by then, so nothing it does can leave you without a working gateway.

Expect two or three reboots and roughly thirty to forty-five minutes. Everything is timestamped in:

```
C:\Windows\Setup\Scripts\rdgw-setup.log
```

It's finished when that log ends with `First-boot setup finished.` Windows Setup's own log, for failures before any of the above runs, is `C:\Windows\Panther\setupact.log`.

You do not have to go and read that log yourself while it builds, though. The script follows the build instead of returning as soon as the VM starts: first by watching the DVD and disk byte counters, then, once the QEMU guest agent is up, by reading `rdgw-setup.log` out of the guest and printing each new line as it appears. It exits non-zero if the log reports an error. `NO_WAIT=1` turns that off and returns at `qm start`; `FOLLOW_SECONDS` caps how long it waits, at 90 minutes by default. Expect the first stretch to show only disk counters: the guest agent that makes the log readable arrives at first boot, so a quiet quarter of an hour there is normal. Running out of time is not treated as success. The CDs stay attached and the script prints the commands to remove them once the log says the build finished.

When the log says the gateway is finished, the script detaches all three CDs, sets the boot order to the disk, and deletes the unattend ISO, since that ISO holds the account password in clear text. `KEEP_MEDIA=1` leaves all of it in place. A build that *failed* also keeps its media, deliberately: the first-boot task stays registered, so a reboot retries, and the retry needs the VirtIO CD to install the guest tools from.

One thing not to do while any of this is running: type into the guest's console. Setup reboots two or three times, the DVD is still first in the boot order at every one of them, and the only thing stopping the machine reinstalling itself is that boot prompt timing out unanswered. A single stray Enter at the wrong moment answers it, and `WillWipeDisk` does what it says to the build you were waiting on. Read the log from the host and leave the console alone until it's done.

That role-install reboot is why `Invoke-GatewaySetup.ps1` exists. `Setup-RDGateway.ps1` stops and asks you to reboot and re-run with `-SkipRoleInstall` when `Install-WindowsFeature` reports `RestartNeeded`, and `SetupComplete.cmd` is not allowed to reboot and resume. So the work is split across boots and the task keeps the place in a small state file. It stops after five boots rather than looping, leaves itself registered, and writes why to the log, so a plain reboot retries.

Then skip to Phase 4. Phase 3 lists what the automated path already did.

### The boot prompt

The Windows DVD's EFI loader prints "Press any key to boot from CD or DVD" and gives up after about five seconds. On an unattended build nobody is there to answer it, the firmware falls through to an empty disk, and the VM stops at the UEFI shell. That is the first thing that will go wrong if you build this by hand.

The prompt has to stay, though. Setup reboots two or three times before it finishes, the DVD is still first in the boot order each time, and the prompt timing out is exactly what lets those reboots fall through to the disk instead of restarting the install. Rebuilding the media around `efisys_noprompt.bin`, which does ship on the ISO next to `efisys.bin`, would fix the first boot and buy an endless reinstall loop in exchange.

So the prompt stays and the host answers it once, with [`qm sendkey`](https://pve.proxmox.com/pve-docs/qm.1.html):

```bash
qm sendkey 9000 ret
```

Knowing *when* to send it is the whole difficulty, and guessing does not work in either direction. Sending Enter on a fixed schedule for a fixed minute reaches Windows Setup, which shows a Cancel button that takes focus, so the surplus keypresses open and close its confirmation dialog for the rest of the minute. Shortening the window to twenty seconds instead expires before OVMF has finished measuring the TPM and looked at the DVD at all, so the prompt appears to an audience of nobody. Both were tried on real builds.

What the VM will tell you is how many bytes it has read off the DVD:

```bash
qm status 9000 --verbose | sed -n '/^blockstat:/,/^[a-z]/p'
```

```
blockstat:
        ide0:
                rd_bytes: 3405824      <- the Windows DVD
                rd_operations: 1663
        ide2:
                rd_bytes: 163840       <- the VirtIO CD
```

Zero means the firmware has not opened the disc yet, so there is nothing to answer. A number that has stopped climbing means the firmware read a loader and is now waiting for somebody, which is the prompt. A number still climbing means Setup is streaming `boot.wim` and no key of yours is wanted. The script polls that counter once a second and sends Enter only in the middle case, which is why it can afford to wait a patient three minutes without ever touching Cancel. `BOOT_KEY_SECONDS` sets that ceiling. If the counter cannot be read at all the script says so and falls back to pressing blind, on a deliberately short leash, because blind is the mode that cannot tell a boot prompt from a Cancel button.

Use `qm status`, not `qm monitor`. The monitor looks like the natural home for this and it is a trap: `printf 'info blockstats\n' | qm monitor 9000` prints nothing at all, never exits, and leaves its own `qm>` prompt sitting in your terminal. Piped that way it took the build script down with it twice.

This happens on the unattended path only. Without an answer file, Windows Setup is a live wizard within the first minute, and a stray Enter would click through the language screen, **Install now**, the edition list and the EULA before you had looked at the console. So the shell-only path leaves the prompt to you.

### If you chose the shell-only path

Open the console from the Proxmox web UI. Two things trip people up:

**Press a key for the boot prompt.** You have about five seconds. Miss it and you land in the UEFI shell: type `exit`, choose Boot Manager, pick the DVD drive. The unattended path answers this prompt from the host; this one deliberately does not, because with no answer file driving Setup a keystroke every two seconds would walk through the screens you came here to drive.

**Windows Setup will show you no disks.** That is expected, not a failure. Windows has no idea what a VirtIO SCSI controller is. Click **Load driver** → **Browse** → the second CD drive → `vioscsi\2k25\amd64` → Next. Your 80 GiB disk appears. While you're in there, load `NetKVM\2k25\amd64` too so the NIC works on first boot.

Pick a **(Desktop Experience)** edition unless you genuinely want to run this from Server Core.

## Phase 3: post-install housekeeping

The unattended path has already done items 1, 3, 5 and 6 below, plus the housekeeping settings if you accepted them. What it cannot do for you is item 2, pinning the address, and item 4, Windows Update. Do those, then go to Phase 4.

On an unattended build, the fastest way to find out whether everything took is the status script, which is on the CD and gets copied in with the rest:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Get-RDGWStatus.ps1
```

It is read-only. It checks that the CD's files arrived, that the first-boot task was created and ran, how far it got, and then, for each setting you chose during the build, whether the machine is actually in that state. A mismatch there with a healthy log above it means the setting was applied and something undid it.

The one thing worth reading by eye is the `UserGroupNames` readback, because it is the likeliest thing in this repo to be wrong. `Invoke-GatewaySetup.ps1` prints it into the log for exactly that reason.

```powershell
Get-CimInstance -Namespace root/cimv2/TerminalServices `
  -ClassName Win32_TSGatewayConnectionAuthorizationPolicy | Select-Object UserGroupNames
```

On the shell-only path, inside Windows, before you configure anything:

1. **Run `virtio-win-guest-tools.exe`** from the VirtIO CD. That installs the balloon driver, the QEMU guest agent, and the rest of the VirtIO stack in one go. Proxmox will start reporting the guest's IP once the agent is running.
2. **Pin the IP.** Either a static address in Windows or a DHCP reservation in UniFi. A gateway whose address moves is a gateway you can't port-forward to.
3. **Rename the machine** to something you'll recognise, and reboot. `Setup-RDGateway.ps1` reads whatever name you pick, but the sample `.rdp` file in Phase 7 hard-codes `RDGW01`, so change that line to match.
4. **Windows Update** until it stops finding things.
5. **Detach the ISOs** from the Proxmox host so it stops trying to boot the DVD:
   ```bash
   qm set <VMID> --ide0 none --ide2 none --sata0 none --boot order=scsi0
   ```
6. **Set a serious password** on whatever account you'll use. You are about to put an authentication endpoint on the public internet. Also worth setting a lockout policy: `secpol.msc` → Account Policies → Account Lockout Policy, 10 attempts / 15 minutes is a reasonable floor.

## Phase 4: the certificate

The build asked you this in Phase 1 and has already acted on it. What follows is what each
answer left you with.

Whichever you picked, `Setup-RDGateway.ps1` generated a self-signed certificate and bound it,
because `TSGateway` will not listen on 443 without one. Everything below replaces that. The
ordering is deliberate: an ACME run that fails for any reason leaves you a working gateway
holding a certificate nobody trusts, rather than a gateway that is down.

### If you chose "self-signed only"

Every client has to be told to trust it. The public half is exported to
`C:\Users\Public\Documents\<your-fqdn>.cer`. To trust it on a Windows client without copying
files around, pull it off the live endpoint and check it against the thumbprint the build
logged, from an **elevated** PowerShell:

```powershell
$fqdn = 'rdg.yourdomain.tld'
$tcp  = [Net.Sockets.TcpClient]::new($fqdn, 443)
$ssl  = [Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient($fqdn)
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
$ssl.Dispose(); $tcp.Dispose()

$cert.Thumbprint     # compare against the thumbprint in rdgw-setup.log
Export-Certificate -Cert $cert -FilePath "$env:TEMP\rdgw.cer" | Out-Null
Import-Certificate -FilePath "$env:TEMP\rdgw.cer" -CertStoreLocation Cert:\LocalMachine\Root
```

Check the thumbprint before you import. Trusting whatever an endpoint hands you is
trust-on-first-use, and this is the one machine on your network that faces the internet.

### If you chose "win-acme installed, one command left" (the default)

win-acme is in `C:\win-acme`, the Cloudflare DNS plugin is beside it, and
`request-certificate.cmd` is written with your hostname, your email and the RD Gateway
install script already filled in. One command, from an elevated prompt on the gateway:

```
C:\win-acme\request-certificate.cmd <your-cloudflare-api-token>
```

The token needs `Zone:DNS:Edit` on the zone holding that hostname, and nothing else. It is
passed as an argument rather than stored in the file, so this repo never writes it to disk.
win-acme keeps its own copy afterwards so it can renew unattended.

That one command requests the certificate over DNS-01, binds it through
`ImportRDGateway.ps1`, restarts `TSGateway`, and registers a scheduled task that renews and
re-binds from then on. Nothing further to do, on this or any other device.

### If you chose "Let's Encrypt during the build"

It already ran. `rdgw-setup.log` has the outcome, and `Get-RDGWStatus.ps1` section 7 reports
the issuer of whatever is actually bound, so a self-signed certificate still sitting there
shows up as `[ NO ]` rather than passing quietly. If it failed, the log says why and the same
`request-certificate.cmd` is there to re-run once you have fixed the cause.

Two failure modes are worth knowing in advance. The token has to carry `Zone:DNS:Edit` on a
zone that actually covers the hostname you asked for. And Let's Encrypt allows **5 duplicate
certificates per week**, so rebuilding this VM repeatedly with issuance in the build path
will eventually fail on a rate limit rather than on anything you did wrong. That is the
reason the staged option is the default.

### Doing it by hand instead

Download win-acme, unzip it to `C:\win-acme`, run `wacs.exe` as admin, choose the full
options menu, pick a manual certificate for your FQDN, and choose **DNS-01** validation with
the Cloudflare plugin. At the installation step there is no "RD Gateway" plugin; win-acme
ships two, **IIS bindings** and **Script**. Choose **Script**:

```
Script:     C:\win-acme\Scripts\ImportRDGateway.ps1
Arguments:  {CertThumbprint}
```

Take the **pluggable** build, not the trimmed one. The trimmed build cannot load external
plugins and every DNS provider is an external plugin, so `--validation cloudflare` will not
resolve. The Cloudflare plugin is a separate download from the same release.

That script copies the certificate into `LocalMachine\My` if it isn't there, sets
`RDS:\GatewayServer\SSLCertificate\Thumbprint`, and restarts `TSGateway`, which is the same
binding call `Setup-RDGateway.ps1` makes. win-acme registers a scheduled task that runs
**daily** and renews whenever the certificate falls inside its renewal window (55 days after
issue, by default), re-running the script each time.

Then run the setup script with `-CertificateSource Existing -Thumbprint <the thumbprint>`, or
skip the certificate entirely, since win-acme will already have bound it.

## Phase 5: configure the gateway

Copy `Setup-RDGateway.ps1` into the VM. Run it from an **elevated Windows PowerShell** prompt (not `pwsh`, because the WMI fallback path wants Windows PowerShell 5.1, which is what ships in the box).

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

The **RAP** (resource authorization policy) answers *what they may reach through it*. This is the one you care about, because it is what buys you one public hostname with many machines behind it.

List the machines you want to reach and the script builds the policy around them:

```powershell
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld `
                      -CertificateSource Existing -Thumbprint A1B2C3... `
                      -TargetMachines 'DESKTOP-01','NAS01','192.168.1.60'
```

The gateway box itself is always included, so you keep a way in even when the machine you were actually after is powered off. For each name you give it, the script also resolves and adds the FQDN and IP, because the RAP matches on the exact string the client asks for. It warns you about anything that didn't resolve, since the gateway has to resolve the target again at connect time or you get event 301.

Three scopes are available, and the unattended build asks which one you want. `AnyResource` skips the list entirely and permits anything the gateway can reach; it is what the unattended path offers first, because it is what most people mean by "a gateway for my LAN". `Listed` is this server plus the machines you name, and `-TargetMachines` selects it automatically. `ThisServerOnly` is the default when you run `Setup-RDGateway.ps1` by hand with no arguments.

`AnyResource` is a jump host: a credential that passes the CAP reaches your whole LAN rather than a chosen handful. Nothing about it bypasses the far end, though. Each target still has to have Remote Desktop switched on, your account in its own local Remote Desktop Users group, and its firewall permitting 3389 from the gateway. The RAP decides where you may tunnel, not what you may log into.

To restrict by user instead, create a dedicated local group and pass it in:

```powershell
New-LocalGroup -Name 'RDG Users'
Add-LocalGroupMember -Group 'RDG Users' -Member 'rob'
.\Setup-RDGateway.ps1 -ExternalFqdn rdg.yourdomain.tld `
                      -AllowedGroups "RDG Users@$env:COMPUTERNAME"
```

Note the `@` suffix convention: built-in groups are `Administrators@BUILTIN`, groups you create are `GroupName@COMPUTERNAME`, domain groups are `GroupName@DOMAIN`.

### What the other machines need

Nothing installed: no gateway role, no certificate, no agent. Each target needs only:

- Remote Desktop enabled
- your account in its local **Remote Desktop Users** group
- its firewall permitting 3389 from the gateway
- a name the gateway can resolve, which can be a DHCP reservation, a DNS record, or just listing it by IP

Windows **Pro** editions work fine as targets; only the gateway itself has to be Server. Home editions can't accept RDP at all. In the client you change one field, **Computer**, to switch machines; the gateway name stays the same for all of them.

To add a machine later, re-run the script with the full list. It removes and recreates its own CAP and RAP, so re-running is safe and the result is the same as if you'd listed them all the first time.

The script uses the documented `Win32_TSGateway*` WMI classes rather than the `RDS:` PowerShell provider for the policies, because the WMI method signatures spell out what each flag means. The certificate binding is the exception. That goes through `RDS:\GatewayServer\SSLCertificate\Thumbprint`, which is the well-trodden path, with a WMI fallback and, failing both, instructions for doing it in `tsgateway.msc`.

## Phase 6: getting to it from outside

Two ways. Pick one.

### Option A: forward the port

On your router, forward to the VM's LAN address:

- **TCP 443**, required. This is the HTTPS tunnel the whole thing rides on.
- **UDP 3391**, optional but worth it. RD Gateway uses it for the graphics stream, and it makes a high-latency link feel dramatically better.

**Do not forward 3389.** Keeping raw RDP off the internet is what you built the gateway for.

Point `rdg.yourdomain.tld` at your WAN address. If that name is on Cloudflare, it has to be **DNS only (grey cloud)**, per the note below.

Costs nothing and works today. The trade is one open port, so spend ten minutes on the hardening below.

#### Hardening the open port

**Restrict the source.** In UniFi, scope the WAN-in rule for 443 to the countries or address ranges you actually connect from. Anything you cut here never reaches Windows at all, which makes this the cheapest lever on the list.

**Put the gateway on its own VLAN.** Restricting the source narrows who can reach the gateway; this narrows what the gateway can reach if it falls. It is by design a machine that accepts connections from the internet and then reaches into your LAN, so assume for a moment that someone is on it and ask what that buys them. In UniFi, give it its own network and write firewall rules that let it reach only 3389 on the specific machines you pass to `-TargetMachines`, and not the NAS, your other VMs, or the Proxmox management interface. This one applies whichever of the two options you pick, because it concerns the gateway itself rather than how traffic gets to it.

**Lock accounts out.** `secpol.msc` → Account Policies → Account Lockout Policy. Ten attempts per fifteen minutes is a reasonable floor.

**Don't use obvious account names,** and give whatever you do use a long password. An authentication endpoint on the public internet is the whole threat model here.

**Keep the hostname out of Certificate Transparency logs.** Every certificate a public CA issues is published to CT logs, permanently and publicly, so `rdg.yourdomain.tld` becomes a searchable fact the moment win-acme first runs, and people scrape those logs for exactly the names you would guess: `rdg.`, `vpn.`, `remote.`. Phase 4 already validates over DNS-01, so ask win-acme for a wildcard (`*.yourdomain.tld`) instead and the specific name never appears. Be clear about what this does and doesn't buy: it hides nothing from anyone sweeping IPv4 for an open 443, and it substitutes for none of the rest of this list. It only stops you being handed to people hunting gateways by name. It applies to the relay too, where what gets found is the VPS.

**Watch for guessing.** Event 4625 in the Security log, and the gateway's own operational log:

```powershell
Get-WinEvent -LogName Microsoft-Windows-TerminalServices-Gateway/Operational -MaxEvents 30 |
    Where-Object Id -in 200,300,301,302 | Format-Table TimeCreated, Id, Message -AutoSize
```

**Keep it patched.** RD Gateway has had pre-auth RCEs before (CVE-2020-0609/0610). Windows Update is not optional on this box.

One thing *not* to bother with: moving the gateway off 443. It's possible, via `HttpsPort` under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\TerminalServerGateway\Config\Core`, but it requires disabling the UDP transport, and clients need `RDGClientTransport` set in `HKCU\Software\Microsoft\Terminal Server Client` before they'll connect to a non-standard port. A registry edit on every device is exactly what a gateway is supposed to spare you.

### Option B: a public relay, nothing open at home

If you'd rather not have an open port, or you're behind CGNAT and can't forward one anyway, [`RELAY.md`](RELAY.md) sets up a small VPS as a layer 4 front door with a WireGuard link back to your Proxmox host. TLS still terminates on the Windows box, so the certificate work in Phase 4 is unchanged, and **client devices install nothing**. They see a normal hostname on 443.

Two scripts: `vps-relay-setup.sh` on the VPS, then `proxmox-relay-peer.sh` on the Proxmox host.

**This does not have to cost anything.** Oracle Cloud's Always Free tier includes two `VM.Standard.E2.1.Micro` instances, each with a public IPv4 and 50 Mbps, plus 10 TB/month of egress, and the resources don't expire. The relay scripts run on one unmodified. The catch, stated in Oracle's own documentation: idle Always Free instances get reclaimed when CPU *and* network sit below 20% across a seven-day window, and a relay you use a few times a week is idle by definition. Plenty of people run one anyway and just rebuild it if it disappears; decide whether that's a tolerable failure mode for the thing you use to get back into your house.

Most of the hardening under Option A still applies here. The relay changes which address is listed and narrows what faces the internet to a layer 4 proxy. It does not make the gateway any harder to authenticate against, so the lockout policy, the account naming, the patching and especially the VLAN isolation are all still yours to do. What you can drop is the WAN-in source restriction, since there is no longer a WAN rule to scope; the equivalent lives in the relay's own firewall.

### Cloudflare Tunnel is not an option here, and it's worth knowing why

RD Gateway's transport uses two custom HTTP methods, `RDG_IN_DATA` and `RDG_OUT_DATA`. Cloudflare's edge runs a method allowlist and answers both with `501` before the request reaches your origin, so a proxied (orange-cloud) hostname breaks the gateway outright, whether the traffic arrives over a tunnel or a port-forward. Grey-cloud any DNS record pointing at this service. `RELAY.md` has the test you can run to confirm it for yourself.

### Then test it properly

Confirm the name resolves and connects **from cellular data, not from inside your LAN.** A lot of consumer routers don't hairpin, so an inside test can fail while the outside one works fine. It can also go the other way, which is worse, because that one looks like success.

## Phase 7: connect

**From Windows**, the built-in `mstsc.exe` is the reliable client. Advanced tab → *Connect from anywhere* → Settings → "Use these RD Gateway server settings", server name `rdg.yourdomain.tld`, logon method "Ask for password (NTLM)", and tick **"Use my RD Gateway credentials for the remote computer"**. Then on the General tab, the computer is the server's own name (`RDGW01`), not the gateway name.

An `.rdp` file saves the fiddling and works across clients. Save this as `rdgw01.rdp` and double-click it:

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

### Reaching your other machines

The gateway's whole point is the machines *behind* it, and connecting to one is the file above with two changes plus one idea that trips everyone up the first time.

A gateway connection has two separate logins, and they do not have to be the same account:

- **To the gateway**, with an account the gateway knows and that passes its policies. That is the account you set up on the gateway itself.
- **To the target machine**, with an account *that machine* knows. The gateway neither has nor needs this account; the target checks it at the far end.

So to reach `win11-dev-777` as its local user `robp`, when the gateway account is `RDGW01\rdgadmin`:

```
full address:s:win11-dev-777
gatewayhostname:s:rdg.yourdomain.tld
gatewayusagemethod:i:1
gatewaycredentialssource:i:0
gatewayprofileusagemethod:i:1
promptcredentialonce:i:0
username:s:win11-dev-777\robp
authentication level:i:2
```

The two changes are `full address` (the target) and `username` (an account on the target). The one that matters is `promptcredentialonce:i:0`: it tells the client the gateway and the target use *different* credentials, so it asks for each. You get two prompts and that is correct, the target first (`win11-dev-777\robp`) then the gateway (`RDGW01\rdgadmin`). Use `1` only when one account works for both, as when you connect to the gateway box itself.

The target needs what the RAP section above lists: Remote Desktop on, your account in *its* Remote Desktop Users group, its firewall allowing 3389 from the gateway, and a name the gateway can resolve (a plain LAN hostname usually does; if not, put the target's IP in `full address`). One extra trap on workgroup machines: **the target account must have a real password.** Windows refuses a network logon for a blank-password account, and a gateway connection is a network logon, so a passwordless account that logs in fine at the keyboard fails here.

The quick check: if you can RDP straight to the target from another machine on the LAN, without the gateway, the gateway path will work too. The gateway only adds the `rdgadmin` hop in front.

**On Android**, the Windows App is the current client, and it inherits the Gateways screen from the old Remote Desktop app. Add the gateway there first, then attach it to the PC connection. Note that the Windows App **cannot import `.rdp` files**; that capability was dropped, so connections have to be recreated by hand on each device. Microsoft documents the Windows App's gateway settings for macOS and iOS/iPadOS explicitly; Android isn't covered in that article, so if the Gateways screen isn't where you expect it, that's the thing to go looking for.

### Watching it work

On the gateway:

```powershell
Get-WinEvent -LogName Microsoft-Windows-TerminalServices-Gateway/Operational -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

Event **200** means the client reached the gateway. **300** means the RAP authorized the target. **302** means traffic is flowing through to it. **301** with error **23002** means the RAP refused the target, and the usual cause is not the resource list at all: the connecting account is a local account whose network token has had `Administrators` filtered out by UAC, so the RAP does not count it as a member. The script fixes this by adding the account to the gateway's own Remote Desktop Users group; if you built by hand, make sure it is there. A genuine name mismatch shows the same 23002, so if the account is in Remote Desktop Users and it still fails, check the name you put in "Computer" against the resource group the script built.

## Things worth knowing

Windows Server allows two concurrent administrative RDP sessions with no RDS licensing and no license server. That's the mode you're in. Going beyond two means the RD Session Host role and paid RDS CALs.

On licensing, honestly: Microsoft's terms call for an RDS CAL for connections made *through* an RD Gateway, even in the two-admin-session case. There is no technical enforcement, because the 120-day grace period timer belongs to RD Session Host rather than RD Gateway, so nothing will stop working. It's a compliance question rather than a functional one, and for a personal home lab you can weigh it accordingly. I'm not a lawyer and this isn't legal advice.

You are putting an auth endpoint on the internet. RD Gateway is a mature, well-audited piece of software, but it has had remote code execution bugs before (CVE-2020-0609/0610 were pre-auth). Keep the VM patched, keep passwords strong, keep the RAP scoped to this server, and watch event 4625 in the Security log for credential stuffing. If you want a second factor, the supported route is installing the NPS Extension for Microsoft Entra MFA on this box and pointing the CAP at a central NPS store. That's a bigger project and it drags you into Entra.

The FOSS alternative, stated once: everything above is for people who want a real RD Gateway, with stock clients and nothing installed on the far end. If the goal is only "reach my Windows box from anywhere", WireGuard or Tailscale on the Proxmox host gets you there with no roles, no certificates, no ports open to the world and no CAL question, and you'd RDP to the LAN address once you're on the tunnel. Worth keeping in your back pocket if the gateway turns into a maintenance burden.

## Undo

```bash
qm stop <VMID> && qm destroy <VMID> --destroy-unreferenced-disks 1 --purge
```

A build that ran to completion has already deleted its unattend ISO and detached the CDs, as
soon as the gateway reported itself finished. You only need the command below if the build
failed part way, if you set `KEEP_MEDIA=1`, or if you are tearing down a VM built before
that was the behaviour. It matters because destroying the VM does not remove the ISO, which
lives in ISO storage and holds the account password in clear text:

```bash
rm /var/lib/vz/template/iso/unattend-<VMID>.iso
```

## Sources

- [Windows 2025 guest best practices, Proxmox VE wiki](https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices)
- [qm(1), Proxmox VE](https://pve.proxmox.com/pve-docs/qm.1.html)
- [Hardware requirements for Windows Server, Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/get-started/hardware-requirements)
- [Remote Desktop Services, access from anywhere](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-plan-access-from-anywhere)
- [Win32_TSGatewayConnectionAuthorizationPolicy.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayconnectionauthorizationpolicy)
- [Win32_TSGatewayResourceAuthorizationPolicy.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayresourceauthorizationpolicy)
- [Win32_TSGatewayResourceGroup.Create](https://learn.microsoft.com/windows/win32/termserv/create-win32-tsgatewayresourcegroup)
- [License Remote Desktop Services with CALs](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-client-access-license)
- [Remote Desktop client, supported configuration](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-supported-config)
- [Supported RDP properties](https://learn.microsoft.com/azure/virtual-desktop/rdp-properties)
- [Integrate RD Gateway with the NPS extension and Microsoft Entra ID](https://learn.microsoft.com/entra/identity/authentication/howto-mfa-nps-extension-rdg)
- [Audit mode overview](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/audit-mode-overview), which is why an installer bundle runs at first boot rather than in specialize
- [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE/tree/main/vm), the script style this follows
- [win-acme](https://www.win-acme.com/), its [installation plugins](https://www.win-acme.com/reference/plugins/installation/) and [ImportRDGateway.ps1](https://github.com/win-acme/win-acme/blob/master/dist/Scripts/ImportRDGateway.ps1)
- [Win32_TSGatewayServerSettings.Configure](https://learn.microsoft.com/windows/win32/termserv/configure-win32-tsgatewayserversettings)
