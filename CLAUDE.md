# CLAUDE.md

Context for working on this repo. Read before proposing architecture changes — several
obvious-looking approaches were tested and ruled out, with evidence, and re-deriving them
wastes a session.

## What this is

Scripts and a runbook for standing up a Windows Server 2025 Remote Desktop Gateway on a
home Proxmox VE host, so that several machines on the LAN are reachable from the internet
behind one public hostname, using stock RD clients.

| File | Runs on | Status |
|---|---|---|
| `windows-rdgw-vm.sh` | Proxmox host, root | **Run for real repeatedly.** Boots and installs, see below |
| `Setup-RDGateway.ps1` | The Windows guest, elevated | **Run for real.** Installed the role and wrote the policies; the CAP readback was correct |
| `Configure-Guest.ps1` | The Windows guest, SYSTEM | **Run for real** in both phases. The guest-tools step is the one that has failed |
| `Invoke-GatewaySetup.ps1` | The Windows guest, SYSTEM | **Run for real.** Registers in specialize, drives the first boot to the end |
| `Invoke-CustomScripts.ps1` | The Windows guest | **Executed for real** on Windows PowerShell 5.1, see below |
| `Get-RDGWStatus.ps1` | The Windows guest, elevated | Read-only. Reports what the build actually did against what it was asked to do |
| `sample-autounattend.xml` | — | Committed sample of generated output. Not read by anything |
| `vps-relay-setup.sh` | A public VPS | Optional path. Written, dry-run verified, **never run for real** |
| `proxmox-relay-peer.sh` | Proxmox host, root | Optional path. Written, dry-run verified, **never run for real** |
| `README.md` | — | Repo intro plus the full runbook |
| `RELAY.md` | — | The optional relay: architecture, steps, caveats |

`windows-rdgw-vm.sh` has been run for real on the operator's Proxmox VE 9.2.20
host three times, and the DVD boot prompt defeated the first two. On 2026-09-19
nobody was there to answer it. On 2026-09-20 the script was there and still
failed, twice, for two different reasons - a twenty-second window that closed
before OVMF reached the DVD, and then a `qm monitor` call that hung forever on
piped input and froze the script mid-loop. Both are in "Ruled out" and in the
`press_a_key` convention below, because each one looked correct right up until
it met hardware.

The third run, watched live over the Proxmox console on 2026-09-20, worked:
one keypress, answered at the right moment, and Windows Setup installed
unattended. The lesson worth keeping is not any of the three bugs. It is that
this repo was written for months against documentation, and the defect that
actually mattered was invisible to `bash -n`, to shellcheck, to nine dry-run
scenarios and to two adversarial review passes, because all of them stub `qm`.
When something here is uncertain, get on the host and look.

`windows-rdgw-vm.sh` offers two paths. The **shell-only** path is the original behaviour: a
configured VM with both ISOs attached, Windows installed by hand. The **unattended** path
additionally builds a third CD (`autounattend.xml`, `$WinPEDriver$` with the 2k25 VirtIO
drivers, and the three PowerShell files) and attaches it on `sata0`, so the box installs
itself and configures the gateway with nobody at the console. Both are supported; the
shell-only path is the documented fallback when the automated one misbehaves.

## The operator's constraints

These are hard. Solutions that violate them have already been rejected in conversation.

- **No spend.** Not a few dollars a month. Free tier or nothing.
- **Stock RD clients only.** Nothing may be installed on client devices — no WARP, no
  WireGuard, no cloudflared, no browser client. He has devices he cannot install software on.
  This is the constraint that kills most of the obvious answers.
- **Multiple target machines**, not just the gateway box. This is the entire reason for
  using RD Gateway rather than a single port-forward.
- **Browser-rendered RDP was tried and disliked.** Don't re-suggest it.
- Prefers FOSS and self-hostable tooling where there's a choice.

## Ruled out, with evidence — do not re-propose

**Cloudflare Tunnel *public hostname* routing, Workers, any orange-clouded hostname.**
RD Gateway's HTTP transport uses the custom methods `RDG_IN_DATA` and `RDG_OUT_DATA`
(MS-TSGU). Cloudflare's edge runs an HTTP method allowlist and returns `501` for both,
generated at the edge — the request never reaches the origin, and never reaches a Worker.
Verified empirically, and re-verified 2026-09-18:

```bash
# 501 on three zones with three different origins, and on four live workers.dev endpoints
curl -s -o /dev/null -X RDG_IN_DATA -w '%{http_code}\n' https://developers.cloudflare.com/
curl -s -o /dev/null -X PROPFIND    -w '%{http_code}\n' https://developers.cloudflare.com/
```

`PROPFIND` passes through and gets an origin-specific answer; the `RDG_*` verbs return `501`
in ~0.15s with a `cf-ray` but **no `cf-cache-status`**, which is how you know it was the edge.
Controls not behind Cloudflare (`httpbin.org`, `google.com`) return `405`, proving the method
survives the network path intact. No tunnel setting reaches this — `disableChunkedEncoding`
and the body-buffering controls are real and genuinely needed by RD Gateway behind a reverse
proxy, but they all sit downstream of where the request already died. Cloudflare Tunnel also
carries no UDP on public hostnames, so port 3391 was never going to work either.

**Cloudflare Tunnel *private network* routing (CIDR routes, now branded Cloudflare Mesh).**
Different thing, different reason, and the one most likely to look like a solution on a fresh
read of the docs — because technically it *is* one. Private network routing never touches the
HTTP edge, and carries arbitrary TCP, UDP and ICMP, so RDP rides it happily. The blocker is
the client side. Cloudflare's own wording: every enrolled device receives a private Mesh IP
and can reach any other participant over TCP, UDP or ICMP, where "client devices are laptops
and phones running the Cloudflare One Client" — the product previously called WARP. That is
an agent on every device, which is the constraint that rules it out. Keep this reason
separate from the `501` above: one is a technical impossibility, this one is a constraint
violation, and collapsing them into a single "Cloudflare doesn't work" line is what sends the
next reader back to the documentation to correctly discover that it does.

**Workers VPC.** Points the wrong way. It gives a Worker outbound reach *into* a private
network (HTTP via `fetch()`, raw TCP via `connect()`); it does not give external clients
inbound reach to a private service. The client still has to arrive at the Worker over
ordinary HTTP, which is the leg that already fails — `RDG_IN_DATA` is refused at the edge
before any Worker code runs. It is also the wrong shape: RD Gateway holds two long-lived
bidirectional streams open for the life of a session, and Workers are request/response with
duration limits.

**Fronting the relay with `cloudflared`.** The relay already publishes a public hostname on
its own — the VPS has a public IPv4, and a grey-clouded A record points at it. Adding
`cloudflared` or an orange cloud re-inserts the HTTP edge at the *front* of the path, which
is upstream of the relay; the relay therefore never sees the request and cannot rescue it.
Cloudflare's RDP documentation lists exactly three methods — browser-rendered, Cloudflare One
Client, and client-side `cloudflared` — and each one either puts software on the client or is
the browser path already rejected. There is no stock-client entry.

**Cloudflare Spectrum.** The only Cloudflare product that proxies arbitrary TCP. Business
plan and up, roughly $200/month.

**Disabling Defender by writing `Start=4` over the WinDefend service keys.** This is
what every snippet on the internet does and it does not work here. Tamper Protection
is on by default on Server 2025 and denies those writes even to SYSTEM, and Microsoft
documents against the approach directly: *"Don't disable, stop, or modify any of the
associated services that are used by Microsoft Defender Antivirus... Manually modifying
these services can cause severe instability on your devices and can make your network
vulnerable."* The repo did this for a while, failed silently on all six keys, and then
printed a success line regardless. On Windows **Server** Defender is an installable
feature and the documented route is `Uninstall-WindowsFeature Windows-Defender` plus a
reboot, which is what `Configure-Guest.ps1` does now. That reboot is taken by
`Invoke-GatewaySetup.ps1` before the role install, because handing a pending reboot to
`Install-WindowsFeature` is how you get "a system reboot is required" instead of a
gateway. Source: [Microsoft Defender Antivirus compatibility](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility).

**Rebuilding the Windows ISO around `efisys_noprompt.bin` to kill the boot prompt.**
The no-prompt boot image really does ship on the media, next to `efisys.bin`, and
re-mastering with xorriso really would stop the DVD asking for a keypress. It also
breaks the install. Windows Setup reboots two or three times before it finishes, the
DVD is still first in the boot order each time, and the prompt timing out is exactly
what lets those reboots fall through to the disk instead of starting the install
over. Remove the prompt and you get an endless reinstall loop unless something also
changes the boot order mid-install, which nothing does. `press_a_key` answers it once
from the host instead, which leaves the timeout behaviour intact for every later boot.

**`qm monitor` for reading anything programmatically.** It is the obvious home for
`info blockstats`, and `qm(1)` documents it, so the next reader will reach for it.
Measured on the operator's PVE 9.2.20 host against a running VM:

```bash
printf 'info blockstats\n' | qm monitor 200     # exit 124 under timeout 10, no output
```

It does not merely fail to answer. It never exits, and it prints its own `qm>` prompt
into the caller's terminal. `press_a_key` called it in a command substitution, so
`qm_bytes_read` never returned, the loop hung forever, and the VM sat on an unanswered
boot prompt until OVMF gave up with "No bootable option or device was found". That is
the true cause of the second and third failed builds - not the timing, which had already
been fixed. `qm monitor` wants a terminal and a pipe does not satisfy it. Use
`qm status <vmid> --verbose`, which needs no terminal, exits by itself, and carries the
same counters under `blockstat:` as one indented stanza per device (`ide0:`, `ide2:`,
`efidisk0:`, each with `rd_bytes:`). Every call still goes through `timeout`, because
nothing in that loop may be allowed to block forever again.

**A `RunSynchronousCommand` `<Path>` longer than 259 characters.** This is the real one,
and it cost two builds plus a wrong diagnosis. Windows never mentions length. The file
deserializes fine (`hrDeserialized = 0x0`), fails schema validation (`hrValidated = 0x1`),
and Setup reports only "Windows could not parse or process unattend answer file",
`0x80220005`, at a dialog saying "The computer restarted unexpectedly". The one line in
`setupact.log` that actually identifies it:

```
CSI  80220005 [Error,Facility=FACILITY_STATE_MANAGEMENT,Code=5] from CWcmScalarInstanceCore::Put
[setup.exe] SMI data results dump: Source = Name: Microsoft-Windows-Deployment
[setup.exe] SMI data results dump: Description = Value is invalid.
```

"Value is invalid" on a scalar means **too long**. Measured: our two `reg.exe` RunOnce
commands were 273 and 266 characters. Corroboration - every one of the 49 `<Path>` values
in the operator's known-good schneegans file is **at or under 255**, and that generator
builds `X:\pe.cmd` by appending 44 separate tiny `cmd.exe /c >>X:\pe.cmd (...)` fragments
rather than writing one long command. That is not a style choice, it is this limit.
`build_unattend_iso` now refuses to ship any `<Path>` over 255, regression-tested against
the exact file that failed (273 -> refused) and the one that replaced it (157 -> accepted).
**Do not add long commands to the answer file.** If the guest needs to do something, teach
`Invoke-GatewaySetup.ps1 -Register` to register it - that already runs in specialize, is a
PowerShell script with no length limit, and logs what it did.

**XML comments below `<component>`: suspected, then disproved.** Worth recording because
a whole build was spent on it. A comment between `<Description>` and `<Path>` was the first
suspect for the `0x80220005` above; removing it changed nothing, and the next build failed
identically. The cause was the `<Path>` length, every time. Comments below `<component>`
may well be harmless. The generator still emits none - prose about the answer file belongs
in `windows-rdgw-vm.sh`, where it costs nothing - and the guard stays as cheap insurance,
but do not repeat the claim that Windows rejects them, because that was never demonstrated.
The genuine lesson is the diagnostic one: **`hrDeserialized` versus `hrValidated` in
`setupact.log` tells you whether it is an XML problem or a schema problem, and reading that
first would have skipped the wrong fix entirely.**

**Two red herrings in that same log. Do not chase them.** A dozen
`BFSVC: BfspCopyFile ... bootmgfw_EX.efi` errors and three
`CApplyDrivers::CopyToDriverStore ... 0x80070002` appear right before the real failure and
look far more alarming than it does. Both are innocent: the ESP was mounted afterwards and
is fully populated with `bootmgfw.efi`, `bootmgr.efi` and `bootx64.efi`, and the
`$WinPEDriver$` payload on the ISO is complete - all 17 files across vioscsi, viostor and
NetKVM, including `netkvmco.exe`. Go straight to `UnattendDumpSetting` and the
`SMI data results dump` lines instead.

**`xmllint` is not installed on Proxmox VE 9**, which nearly made all of the above
unenforceable. The answer-file validation had always been written as
`command -v xmllint || skip`, so on the operator's host it silently did nothing, and had
never once run where it mattered. Proxmox does guarantee `perl` with `XML::LibXML`
(pve-manager depends on it) and ships `python3`, so the check now tries xmllint, then
perl, then python3, and **says which one ran** - or warns loudly that none did. Verified
on the host across all three cases: a nested comment returns 1, a comment directly under
`<component>` returns 0, malformed XML is caught. Do not write
another `command -v X || silently skip` check in this repo; a check nobody can see fail is
not a check.

**Running an installer bundle - specifically `virtio-win-guest-tools.exe` - during the
specialize pass.** The operator asked for the VirtIO guest tools to go in first, so that
the QEMU guest agent arrives early and `follow_build` starts printing real log lines
instead of a byte counter. The reasoning was sound and the ordering worked; the install
does not. Measured on the build of 2026-09-21: the bundle starts, paints its
"Installing Windows Virtio-Win Drivers" progress bar on the console, and then

```
5:=== VirtIO guest tools ===
6:    [fail] F:\virtio-win-guest-tools.exe exited 1603
```

1603 is `ERROR_INSTALL_FAILURE`. `C:\Windows\Temp` afterwards holds the bundle log, four
MSI logs and **three rollback logs**, so the MSIs ran and were backed out. On the booted
machine, `sc.exe query qemu-ga` and `sc.exe query vioserial` both return "The specified
service does not exist as an installed service", and `qm agent 200 ping` on the host
answers "QEMU guest agent is not running" with the VM config reading
`agent: enabled=1` - so the Proxmox side was never the problem. `follow_build` spent that
entire build blind. Note that `return value 3` does **not** appear in the main MSI log, so
this is not a custom action failing; the install is refused earlier than that.
Microsoft's [Audit mode overview](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/audit-mode-overview)
puts application installs in audit mode precisely because they are changes "that require
the Windows installation to be running", which specialize is not. This is the boundary of
the specialize architecture below: registry writes, file copies, hive loading and task
registration all belong there; **an installer does not.** The tools now go in at the top of
`-Phase FirstBoot`, the earliest point they work, and specialize logs a `[skip]` saying so
rather than staying silent about a step that moved.

**WARP / Cloudflare One client, Tailscale, any client-side agent.** Violates the
no-install-on-clients constraint.

**GCP Always Free e2-micro as a relay host.** Official docs: **1 GB of egress per month.**
An RDP session exceeds that in under an hour.

**Moving RD Gateway off port 443.** Technically possible (`HttpsPort` under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\TerminalServerGateway\Config\Core`) but it
requires disabling the UDP transport *and* setting `RDGClientTransport` in
`HKCU\Software\Microsoft\Terminal Server Client` on **every client** — a per-device registry
edit, which is exactly what the constraints forbid.

## The open question that decides the architecture

**Is he behind CGNAT?** Unresolved as of the last exchange.

- **Not CGNAT** → forward TCP 443 (and optionally UDP 3391) to the gateway VM, grey-cloud the
  Cloudflare DNS record, done. Free, no extra infrastructure. `README.md` Phase 6 Option A,
  including the hardening that path needs.
- **CGNAT** → he needs something with a public IP. The relay scripts work unmodified on
  Oracle Cloud Always Free (2× `VM.Standard.E2.1.Micro`, public IPv4, 10 TB/month egress,
  doesn't expire) — with the documented caveat that idle Always Free instances get reclaimed
  when CPU *and* network sit under 20% for seven days, and a relay is idle by nature.
  IPv6 is the other free angle: most ISPs hand out a routable v6 prefix even when v4 is
  CGNAT'd, so an AAAA record plus a firewall rule needs no relay at all — but only works from
  v6-capable clients, which mobile networks generally are and hotel/corporate Wi-Fi often isn't.

Check: `curl -s https://api.ipify.org` against the UniFi WAN address. A WAN address in
`100.64.0.0/10`, or any mismatch, means CGNAT.

## Verified vs assumed

Be honest about this with the operator. Everything below the line is where the first real
bug will surface.

**Verified in this session:**

- All three shell scripts: `bash -n` and `shellcheck -S warning` clean; exercised end to end
  with `DRY_RUN=1` against stubbed `qm` / `pvesm` / `pvesh` / `whiptail` / `mount` / `xorriso`,
  covering the default path, the advanced path, the virtio-download path, and both the
  unattended and shell-only branches.
- The generated nginx stream config passes `nginx -t` against a real nginx with the stream
  module loaded.
- Every `iptables` rule parses under `iptables-translate`.
- `Setup-RDGateway.ps1`, `Configure-Guest.ps1` and `Invoke-GatewaySetup.ps1` all parse;
  PSScriptAnalyzer reports nothing beyond `Write-Host` and `ShouldProcess` style notes; all
  three are deliberately **pure ASCII** because Windows PowerShell 5.1 reads a BOM-less file
  as Windows-1252 and would mangle anything else.
- The generated `autounattend.xml` is well-formed XML, and the generated `rdgw-config.psd1`
  round-trips through `Import-PowerShellDataFile` with the right types (`Boolean` for the
  toggles, `Int32` for the lockout numbers, `Object[]` for `TargetMachines`) both empty and
  populated.
- `Invoke-CustomScripts.ps1` was **run for real** under `powershell.exe` 5.1 on the
  operator's Windows box, not just parsed. Verified: dispatch by extension, filename
  ordering, a non-zero exit code reported rather than swallowed, a hung script killed
  at the timeout with the next one still running, and a `.reg` file rewritten from
  `HKEY_CURRENT_USER` to `HKEY_USERS\<sid>` and imported into a genuinely mounted hive.
  That last test pointed `-HiveRoot` at the tester's own live hive so the rewrite and
  the import were both real rather than mocked. It found one real bug: `Start-Process
  -PassThru` hands back an object whose `ExitCode` reads back empty once the child is
  gone, so every script looked like it had failed. Reading `$proc.Handle` right after
  starting keeps the handle open and fixes it - do not remove that line.
- The RAP scope is wired end to end and all three values were dry-run to a config file
  that round-trips: `AnyResource`, `Listed` with a machine list, `ThisServerOnly`.
  `ResourceGroupType = 'ALL'` is confirmed against Microsoft's `Create` reference for
  `Win32_TSGatewayResourceAuthorizationPolicy`, which documents exactly three values -
  `RG`, `CG`, `ALL` - and gives `ALL` as "All resources". What `ResourceGroupName`
  should be alongside `ALL` is *not* documented; the empty string is convention.
- `qm sendkey <vmid> <key>` is confirmed **on the real host**, not just against the
  manual page: a VM parked on "Press any key to enter the Boot Manager Menu" was sent
  `qm sendkey 200 ret` and the menu opened. Key injection was never the broken part.
- The byte counter is read with `qm status <vmid> --verbose`, and its output format is
  confirmed on the real host: `blockstat:` followed by one tab-indented stanza per
  device, `ide0:` being the Windows DVD. Observed mid-boot with the prompt on screen:
  `ide0: rd_bytes: 3405824, rd_operations: 1663`, which is the firmware having read a
  loader and stopped - exactly the state `press_a_key` presses in. The parser is unit
  tested against a transcription of that output, including a device legitimately
  reading `0` (must return `"0"`, not empty) and a stopped VM (must return empty).
- **An adversarial review pass ran over this branch** (six independent finders, one
  triage, two refuters per finding, opus tiebreak on disagreement). It produced 22 raw
  findings, 20 unique, all 20 read back against the source and confirmed. Every one is
  fixed. The three worth remembering, because they were all invisible to the dry-run
  suite: the missing XML escaping, the six bare msgboxes, and `Start-Process` dropping
  everything after a space. The suite passed throughout, which is the point - it stubs
  whiptail, so it never pressed Esc, and it never typed an ampersand.
- Fixes verified empirically rather than by argument: `Start-Process` quoting and the
  numeric sort were reproduced and then re-run green with spaces in both the directory
  and the filename; the anchored `.reg` rewrite was proved to retarget a key header
  while leaving the literal string `HKEY_CURRENT_USER` inside quoted value data intact;
  `xml_escape` and `psd1_quote` were driven with `Tr0ub4dor&3<evil>` and `R&D O'Brien`
  end to end, producing an `autounattend.xml` that parses and a `rdgw-config.psd1` whose
  `AccountName` round-trips byte-identical through `Import-PowerShellDataFile`.
- The custom-script TUI is dry-run covered in six scenarios: importing a directory laid
  out by category, importing a directory of loose files, writing a `.ps1` and a `.reg`
  through a stubbed editor, writing a `FirstLogon` script and confirming the extra
  `RunSynchronousCommand` appears in the answer file, an editor that saves nothing and
  the file being discarded, and adding two scripts then removing one in review. The
  generated `autounattend.xml` parses in every case.
- Every element of the generated answer file was checked against the Unattended Windows Setup
  Reference on Microsoft Learn: component names, valid configuration passes, child elements.
  The load-bearing one is `Microsoft-Windows-Deployment\RunSynchronous\RunSynchronousCommand`
  (`Order`, `Description`, `Path`) in `specialize`, which the docs confirm runs in the
  system context - that is what copies the scripts off the CD and registers the task. Also
  confirmed: `Primary` / `EFI` / `MSR` are valid `CreatePartition` types and an MSR partition
  correctly takes no `Format`; `WillWipeDisk` is what Microsoft recommends to avoid ending up
  with two ESPs; `HideLocalAccountScreen` is Server-only and is what stops OOBE asking for an
  Administrator password; `Administrators` is the correct language-neutral `Group` name.

**Checked and deliberately NOT added to the answer file** - don't re-derive these:

- `OOBE\NetworkLocation` - deprecated in Windows 10, documented for reference only.
- `OOBE\VMModeOptimizations` - requires `sysprep /mode:vm`, which this flow never runs, so
  the settings would be inert.
- Anything enabling Remote Desktop. `Setup-RDGateway.ps1` already sets `fDenyTSConnections=0`
  and `UserAuthentication=1` (NLA) and opens the firewall group at lines 259-267.
  `Configure-Guest.ps1` must not duplicate it.
- The three WMI `Create` signatures were checked against Microsoft's documentation and match
  in both count and order: CAP takes **18** parameters (an earlier 13-parameter version was a
  real bug — the trailing `IdleTimeout`, `SessionTimeout`, `SessionTimeoutAction`,
  `AllowOnlySDRServers`, `CookieAuthentication` are required), RAP takes 8, resource group 3.
- Scope auto-selection and the target-identity expansion are unit-tested.

**Assumed, never executed:**

- Everything about the **relay** path. `vps-relay-setup.sh` and `proxmox-relay-peer.sh`
  are dry-run verified and have never touched a VPS.
- `--efidisk0 <storage>:1,efitype=4m` and `--tpmstate0 <storage>:1,version=v2.0` came from
  docs and forum usage rather than a run here, and have since built a VM that boots UEFI
  with a TPM several times. They work; nothing about them is still assumed.
- The WMI calls **have** now run against a real RD Gateway, and the one that was wrong is
  the `BUILTIN\` entry below. The rest - the 18-parameter CAP `Create`, the 8-parameter RAP,
  the resource group - went in and read back. Certificate binding
  (`Set-Item RDS:\GatewayServer\SSLCertificate\Thumbprint`) is still untested, because no
  real certificate has been installed yet.
- **Settled on real hardware, and the guess was wrong.** `Administrators@BUILTIN` /
  `Remote Desktop Users@BUILTIN` came from a published workgroup example, and the gateway
  refuses it: `Win32_TSGatewayConnectionAuthorizationPolicy.Create returned 2147943732`,
  which is `0x80070534`, **ERROR_NONE_MAPPED**. The provider resolves names through
  `LookupAccountName`, which takes `DOMAIN\Name` or a bare `Name`, but not the UPN-style
  `Name@Domain` unless it is a real domain principal. Measured: `Administrators@BUILTIN`
  fails to translate, `BUILTIN\Administrators` gives `S-1-5-32-544`,
  `BUILTIN\Remote Desktop Users` gives `S-1-5-32-555`. Microsoft's class reference
  documented `Domain\UserGroupName` the whole time - an example someone got working is not
  a specification. The default is now the `BUILTIN\` form, and `Setup-RDGateway.ps1`
  translates every group to a SID **before** calling `Create`, so a name that cannot
  resolve is reported by name instead of as a bare WMI number. The readback below is still
  worth running:
  ```powershell
  Get-CimInstance -Namespace root/cimv2/TerminalServices `
    -ClassName Win32_TSGatewayConnectionAuthorizationPolicy | Select-Object UserGroupNames
  ```
- `Set-Item RDS:\GatewayServer\SSLCertificate\Thumbprint` matches what win-acme's
  `ImportRDGateway.ps1` does, but hasn't been run here. There's a WMI fallback
  (`SetCertificate` then `Configure`, both instance methods on the singleton) and, failing
  both, the script tells the operator to do it in `tsgateway.msc`.
- **The custom-script categories have not been watched on a real build.** The runner
  itself has (above), but the four registration points have not: the `FirstLogon`
  `RunOnce` value written by a specialize `RunSynchronousCommand`, and the `UserOnce`
  `RunOnce` value written into the mounted Default User hive. The known interaction is
  that `AutoLogon` with `LogonCount 1` creates the first profile at roughly the moment
  `Configure-Guest.ps1` is writing that hive, so `UserOnce` may miss the first account.
  `FirstLogon` is registered in specialize precisely so it cannot lose that race, and
  the README says to put anything the first account needs there.
- **The unattended path now boots and installs, watched on the real host on 2026-09-20.**
  `press_a_key` answered the DVD prompt with exactly one keypress and stopped, Windows
  Setup ran unattended with no wizard, and the install reached "Installing Windows Server"
  with a progress bar. That single observation retires three of the four riskiest
  assumptions at once, because Setup could not have got that far otherwise: the
  `/IMAGE/NAME` value **did** match this retail/VL media, the `$WinPEDriver$` scan **did**
  load `vioscsi` (or Setup would have stopped with no disks to install to), and the
  `CreatePartition` layout **did** apply to a real disk. Do not re-list these as unverified.
  What happens after the last Setup reboot has now been watched too. It failed the first
  time - the `RDGW-FirstBoot` task was never registered, because of the `$PSScriptRoot` bug
  above - and then, with that fixed, **a complete build ran end to end**: the log finished
  on `First-boot setup finished.`, the CAP read back
  `BUILTIN\Administrators;BUILTIN\Remote Desktop Users`, the TSGateway service was running
  and the task unregistered itself. The measured budget after first boot was 21m27s:
  Defender 10m33s, the RDS-Gateway role 5m55s, the operator's own custom script 2m35s, the
  rest seconds. So the chain works. What is **still** unobserved is narrower than it was:
  the four custom-script registration points have each been seen firing at least once, but
  not all four on one build, and `UserOnce` in particular has never been confirmed to reach
  the auto-logon account rather than only later profiles. When any of it fails it stays
  visible and recoverable: the task logs every step to
  `C:\Windows\Setup\Scripts\rdgw-setup.log` and stays registered so a reboot retries.
- **Patterns borrowed from [cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator),
  which had already solved things this repo learned the hard way.** The operator pointed at
  it early and was right to. Four of its decisions are now ours, and the reasons are worth
  keeping because each one maps to a bug that cost a real build:
  1. **Absolute paths, always.** `const string folder = @"C:\Windows\Setup\Scripts"`, and
     every invocation is `-File "C:\Windows\Setup\Scripts\unattend-NN.ps1"`. `$PSScriptRoot`
     appears **zero times** in his entire repository. The bug that cost three builds here is
     structurally impossible there.
  2. **No parameters passed to scripts.** He bakes configuration into the generated script
     text, so parameter binding cannot fail. Ours died *during* parameter binding.
  3. **Hive load, run, unload as three separate answer-file commands**, so a script that
     throws cannot skip the unload. We run inside one script, so `try/finally` buys the same
     guarantee - and it is not optional: `reg.exe` holds `NTUSER.DAT` open while loaded, and
     a locked Default User profile poisons every profile created afterwards.
  4. **Per-user settings go in twice, and Explorer gets restarted.** See the Default User
     hive entry below. His `RestartExplorer.ps1` kills only the current session's Explorer,
     which is what `Restart-ExplorerHere` does here.

  Not adopted: the generator itself. It is a C#/.NET application, so using it on a Proxmox
  host means installing .NET or calling the hosted form at schneegans.de - and the answer
  file carries the Administrator password in clear text, so the hosted route would hand
  that to a third party. It also only produces `autounattend.xml`; it does not build the VM,
  assemble the ISO with the VirtIO drivers, or know anything about RD Gateway. A
  bring-your-own-answer-file path, where the operator generates the XML themselves and this
  script injects only `rdgw/` and `$WinPEDriver$`, is a reasonable future option and has
  been discussed but not built.
- **The VirtIO guest tools are installed by `Configure-Guest.ps1`, above the `ApplyTweaks`
  gate, at the top of the first-boot pass.** That gate answers a prompt describing itself
  as cosmetic and not security relevant; the QEMU guest agent is neither. Without it
  Proxmox cannot read the VM's IP, cannot shut it down gracefully and cannot quiesce the
  filesystem for a backup, so a gateway built with housekeeping declined would quietly be
  the worse machine. It scans D: to Z: for `virtio-win-guest-tools.exe` and runs it
  `/passive /norestart`, which works because the VirtIO CD is still on ide2 at first boot -
  before the runbook tells the operator to detach the CDs. Exit code 3010 counts as
  success; it means "restart required", and a restart is coming anyway. Missing tools are a
  `[skip]`, not a failure: the drivers themselves came from `$WinPEDriver$`, so the box
  still boots, networks and uses its disk. The **shell-only** path still tells the operator
  to run it by hand, correctly, because `Configure-Guest.ps1` never runs there.
  It runs **first** within `-Phase FirstBoot`, ahead of the Defender removal, because it
  takes about a minute and brings up the agent that `follow_build` needs, while Defender
  takes ten and produces nothing anyone can watch. It does **not** run in specialize -
  see the 1603 entry under "Ruled out".
- **Edge first-run is suppressed by machine-wide policy, deliberately.**
  `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience = 1`, plus
  `StartupBoostEnabled` and `BackgroundModeEnabled` off under `...\Edge\Recommended`, all
  in `Configure-Guest.ps1`'s housekeeping section. Machine-wide is the point: unlike the
  shell settings these do not live in HKCU, so they cannot lose the race against the
  profile `AutoLogon` creates and need no per-user second pass. Same three keys
  cschneegans/unattend-generator writes in its specialize phase. Do not "consolidate" them
  into the Default User hive.
- **The builder follows the build to the end and does not claim success before it.** It
  used to print "VM is built and will install itself" and exit, with thirty to forty
  minutes of install and configuration still ahead and nobody watching. Every failure this
  project has had happened *after* that cheerful summary - a boot prompt nobody answered,
  an answer file Windows refused, a gateway policy that returned ERROR_NONE_MAPPED - and in
  each case the script had already reported success. `follow_build` waits on the disk
  counters until the guest agent answers, then reads `rdgw-setup.log` through
  `qm guest exec` and prints each new line as it appears, exiting non-zero on an `[error]`
  line. `NO_WAIT=1` restores the old behaviour, `FOLLOW_SECONDS` caps the wait. Do not make
  this opt-in: a script that reports success it has not verified is worse than one that
  says nothing.

  Its first phase used to print `installing - read N MiB from the DVD, written N MiB to
  disk`, and the operator watched it say that for twenty-five minutes while Windows sat at
  a finished desktop running the first-boot task - because the guest tools had failed and
  the agent was never coming. The counters are the only thing that phase knows, so it now
  says `waiting for the guest agent` and nothing more, and past twenty-five minutes it says
  once that the agent is not coming, where to read the log by hand, and not to type in that
  console. Do not restore a word like "installing" to a branch that cannot tell.

  The same phase now also notices the install **restarting**. Setup reads the image off
  the DVD and the counter then goes flat for the rest of the build, so a counter that wakes
  up after five quiet minutes and reads another 256 MiB means the machine booted the media
  again and the new Setup has already wiped the disk. That is not hypothetical: the trace
  from 2026-09-21 is flat at 8053 MiB for eighteen minutes, then 8691, 9673, and on to
  16104 - the disc read exactly twice - while the heartbeat said "installing" throughout
  and the operator had no way to know the build they were waiting on no longer existed.
  The detector is regression-tested against that transcribed trace, with a normal
  single-pass install as the control so it cannot fire on one.
- **Do not send keystrokes to the guest console while a build is running.** Learned by
  destroying one. The build reboots several times - after the Defender feature removal,
  among others - the DVD is still first in the boot order at every one of them, and the
  only thing that stops the machine reinstalling itself is the "Press any key to boot from
  CD or DVD" prompt timing out unanswered. A single `Return`, sent to complete a filename
  while reading a log on that console, landed on that prompt during the post-Defender
  reboot; Windows Setup booted from the media, `WillWipeDisk` did what it says, and a build
  that was eleven minutes from finishing became "Installing Windows Server, 16% complete".
  This is the same fact `press_a_key` is built around, seen from the other end. The boot
  order cannot simply be changed to disk-first either - see the `efisys_noprompt.bin` entry
  under "Ruled out" for why those mid-install reboots need the DVD to stay bootable. Read
  the guest's log through `qm guest exec` from the host; use the console read-only, and if
  something must be typed there, do it when the build is finished.
- **As much as possible happens in specialize, and that is a deliberate architecture, not
  an optimisation.** The operator watched a build and objected that the desktop appeared
  fully formed roughly twenty minutes before the machine was actually finished, and that
  a script they had filed under the **System** category "only kicked in during the first
  login". Both were true. `Invoke-CustomScripts.ps1` documented System as running "before
  anyone logs on"; measured, it ran at 22:18:21 from the startup task, eleven minutes
  *after* the desktop was up. The phase name was a lie. cschneegans/unattend-generator
  runs its System phase in specialize, which is what makes the name honest.
  `Configure-Guest.ps1` now takes `-Phase`:
  - **Specialize** - Default User hive, every machine setting and the operator's System
    scripts. Driven from `Invoke-GatewaySetup.ps1 -Register`, which already runs in that
    pass, so no new answer-file command and no new `<Path>` to bust the 259-character
    limit.
  - **FirstBoot** - the VirtIO guest tools, then removing the Defender feature. Both are
    here because they cannot be anywhere else. Defender is a CBS servicing operation that
    needs a reboot and must not run beside Setup's own servicing, and it is the single
    slowest step in the build at 10m33s measured. The guest tools are an installer bundle,
    and an installer bundle exits 1603 in specialize - the whole story is under "Ruled
    out". They go first of the two so the agent arrives while Defender is still grinding.
  - **All** - both, for running the script by hand.

  Do not move work back to the first-boot task for convenience. The measured budget after
  first boot was 21m27s, of which Defender was 10m33s and the RDS-Gateway role install
  5m55s; everything else is seconds. Anything that is only registry writes belongs in
  specialize. The line is **registry writes, file copies, hive loading and task
  registration go in specialize; anything that runs an installer does not.**
- **The Default User hive is written during specialize, not by the first-boot task.** That
  is the only moment when it is unambiguously correct - no profile exists yet, so what goes
  in is genuinely inherited by the first account. `Invoke-GatewaySetup.ps1 -Register` calls
  `Configure-Guest.ps1 -DefaultUserOnly`, which drops a `rdgw-defaultuser.done` marker so
  the first-boot task skips it rather than running the operator's DefaultUser scripts a
  second time. The task keeps the code as a fallback for a specialize call that did not
  happen.
- **The Default User hive cannot reach the auto-logon account, so the shell settings go in
  twice.** Everything under `ApplyTweaks` - taskbar left, dark theme, Explorer defaults,
  desktop icons - is written into `C:\Users\Default\NTUSER.DAT` so new profiles inherit it.
  `AutoLogon` creates the first profile from that hive at roughly the same moment, and on
  the observed build the profile won: `rdgadmin` came up with a centred taskbar and the
  light theme, having been asked for neither. `Set-ShellSetting` therefore takes a registry
  root and is called twice - once against the mounted hive, once against `HKCU:` by
  `Configure-Guest.ps1 -ShellForCurrentUser`, which the answer file registers in **HKLM**
  `RunOnce` (Order 3) so it fires at the first interactive logon whoever that is. Neither
  call is redundant: the hive reaches future profiles, the HKCU pass reaches the account
  the operator is actually looking at. Explorer is restarted afterwards, because it reads
  these once at startup and a logged-on user sees nothing until it does. Do not "simplify"
  this back to one call.
- `DiskID 0` in the answer file assumes the VirtIO SCSI disk is the only disk. True for a VM
  this script builds; add a second disk before install and it stops being true.
- **RDP-over-UDP through nginx stream is the least certain thing in the repo.** Note that
  `proxy_responses 0` was removed from that block deliberately: `nginx -t` accepts it silently
  but it caps how many datagrams come back and would break the session at runtime. If UDP
  misbehaves, delete the whole second `server` block — TCP 443 alone is complete.

## Next steps

1. Settle the CGNAT question. It decides everything downstream.
2. Check the Windows media before building:
   `dism /Get-WimInfo /WimFile:<mount>\sources\install.wim`. The edition menu's image names
   are for retail/VL media; Evaluation ISOs name their images differently and cannot be
   activated with a GVLK.
3. Run `windows-rdgw-vm.sh` on the Proxmox host again, now that the boot prompt is
   answered. Start with `DRY_RUN=1`, which prints the whole generated answer file.
4. Unattended path: watch `C:\Windows\Setup\Scripts\rdgw-setup.log` and check the
   `UserGroupNames` readback it prints. Shell-only path: install Windows from the console
   (Setup shows **no disks** until `vioscsi\2k25\amd64` is loaded from the second CD, which
   is expected), then run `Setup-RDGateway.ps1` with `-TargetMachines` listing every machine
   he wants to reach and check the same readback.
5. Delete the unattend ISO from Proxmox storage afterwards. It holds the account password in
   clear text, and `qm destroy` does not remove it.
6. Each target machine needs only: RDP enabled, his account in its local Remote Desktop Users
   group, firewall allowing 3389 from the gateway, and a name the gateway can resolve.
   Windows Pro is fine as a target; only the gateway has to be Server.

## Conventions used here

- Shell scripts print every command before running it and honour `DRY_RUN=1`. Keep that —
  the operator explicitly wants to follow along rather than be handed a black box.
- `windows-rdgw-vm.sh` must keep working when piped into bash, community-scripts style:
  `bash -c "$(curl -fsSL .../windows-rdgw-vm.sh)"`. That means **never** dereference
  `${BASH_SOURCE[0]}` unguarded — under `set -u` it is unbound in that form and the script
  dies on line one. It falls back to `$PWD`. The three PowerShell files are resolved by
  `resolve_support_files`: local copies always win, and only the piped form reaches the
  network. Print every URL before fetching, and keep `REPO_REF` / `REPO_RAW` overridable so
  a branch, tag or fork can be pinned.
- Generated config files are echoed in dry-run mode too, including the whole
  `autounattend.xml`. That is what `write_file` is for; it is duplicated in
  `windows-rdgw-vm.sh` and `vps-relay-setup.sh` on purpose, because each script has to stay
  runnable on its own.
- `press_a_key` runs after `qm start` on both paths and is not optional decoration. The
  first real run died without it. Keep the DVD prompt itself; answer it from the host.
- The unattended path's resource-scope menu defaults to **any machine on the LAN**,
  which is the widest of the three. That was the operator's explicit expectation of what
  an RD Gateway is for, stated after the narrow default surprised them. The consequence
  is stated once in a msgbox and once in `Setup-RDGateway.ps1`'s own run-time warning.
  `Setup-RDGateway.ps1`'s own parameter default stays `ThisServerOnly`, because a bare
  invocation with no arguments should not quietly open the LAN.
- The custom-script category names (`System`, `DefaultUser`, `FirstLogon`, `UserOnce`)
  are deliberately the schneegans.de generator's names, with the same timing and the
  same accepted extensions. The operator asked for it in those terms. Do not rename them
  to something tidier.
- Custom scripts can be written in the TUI or imported from disk, and both routes feed
  one staging tree (`CUSTOM_STAGE`, a `mktemp -d` the exit trap removes) laid out as
  `<category>/<filename>`. Everything downstream - the count in the menu title, the
  decision to register `FirstLogon`, the ISO staging, the closing summary - reads that
  tree rather than asking where a file came from. Keep it that way; it is what let the
  editor route be added without touching any of them.
- **Every guest-side script writes to `rdgw-setup.log` itself. Do not go back to
  piping a child into `Tee-Object`.** `Configure-Guest.ps1` prints with `Write-Host`,
  which goes to the information stream, and the caller captured it with
  `& Configure-Guest.ps1 2>&1 | Tee-Object`. `2>&1` merges the *error* stream into
  success; it does not carry stream 6. So for the whole life of that file, not one of
  its `[ ok ]` / `[fail]` lines ever reached the log - the operator got "Applying guest
  configuration", "Guest configuration applied", and no record of whether a single
  setting took. That is what "I'm not really sure the customizations are being applied"
  looked like from their side. Verified empirically: with `2>&1` only the `Write-Output`
  line survives the pipe; `*>&1` carries all of it.
- **Never let `$PSScriptRoot` be the only way a guest script finds itself.** On a real
  Server 2025 build it came back **empty**, and that one empty string is what actually
  broke three builds. `Join-Path` throws on an empty `-Path`, so
  `Invoke-GatewaySetup.ps1 -Register` died on its next line: no scheduled task, no
  `Configure-Guest.ps1`, no custom scripts, no RD Gateway role, and - because it died
  before the log existed - not one word written down. From the console it looked
  identical to "the customizations silently didn't apply", which is why it survived two
  rounds of fixing the wrong thing. Observed directly: `schtasks /query /tn
  rdgw-firstboot` returned "cannot find the path specified", `C:\Windows\Setup\Scripts`
  held all six files but no `rdgw-setup.log`, running the command by hand reproduced
  `Cannot bind argument to parameter 'Path' because it is an empty string`, and adding
  `-ScriptRoot` made that same command print `SUCCESS: The scheduled task
  "RDGW-FirstBoot" has successfully been created`. Windows Setup's own
  `Panther\UnattendGC\setupact.log` confirms both RunSynchronous commands were found and
  processed, so the answer file was never at fault. **Why** the variable is empty there is
  still unexplained: it is populated on Windows 11 PowerShell 5.1 for absolute and
  relative `-File`, with LF and CRLF endings, all tested. Do not spend a session trying to
  reproduce it - just never depend on it. Every guest script now falls back to
  `Split-Path -Parent $MyInvocation.MyCommand.Definition` and then to a literal
  `C:\Windows\Setup\Scripts`, the answer file passes `-ScriptRoot` explicitly, and
  **no param default may call `Join-Path`** - a default that throws kills the script
  during parameter binding, before its first statement, where no catch can help.
- **Registration must read the task back.** `-Register` used to create the task, trust
  `schtasks`, and exit silently. It now logs before and after and re-queries the task,
  because "schtasks exited 0" and "the task exists" are different questions, and the
  answer to the second one is what the whole build depends on.
- **Silence is not an acceptable answer to "did my script run".**
  `Invoke-CustomScripts.ps1` used to `exit 0` without logging when a category directory
  was missing or matched no files, which is indistinguishable from never being called.
  It now logs in all three cases: nothing supplied, directory empty, and directory
  holding only files it will not run (naming them).
- **Anything that came from a prompt and lands in a generated file goes through
  `xml_escape` or `psd1_quote` first.** Both files are built by string interpolation
  and neither format forgives a stray character: `Tr0ub4dor&3` is an ordinary Windows
  password that makes `autounattend.xml` malformed, and an account named `O'Brien`
  makes `rdgw-config.psd1` throw before `Invoke-GatewaySetup.ps1` can log why. If you
  add a new prompt whose answer reaches either file, escape it at the interpolation
  site. There is an `xmllint --noout` check after generation as a backstop.
- **The backslashes in `xml_escape` are load-bearing.** bash 5.2 turned on
  `patsub_replacement`, which makes an unquoted `&` in a `${var//pat/repl}` replacement
  mean "the text that matched" - so `${s//</&lt;}` produces `<lt;` on a Proxmox VE 8
  host, and the escaping silently does nothing useful. `\&` is correct on 5.1 too,
  where quote removal just drops the backslash. This was caught by a smoke test, not
  by reading, and it would have made the fix above worthless.
- **`press_a_key` runs on the unattended path only, and stops as soon as the DVD
  starts streaming.** Two separate lessons, both learned from real runs. The first: it
  is gated on `UNATTEND == yes`, not just `START_VM == yes`, because with no answer file
  driving Setup, Windows is a live wizard within that first minute. The second, from the
  operator's first successful boot: **keystrokes are not harmless during unattended
  Setup either.** The original comment claimed "Setup is driven by the answer file, so a
  key that lands early or late does nothing". It does not. Setup shows a Cancel button
  that takes focus, and a fixed sixty seconds of Enter hammered it, opening and closing
  a confirmation dialog for the rest of the minute. It stayed harmless only because that
  dialog also defaults to Cancel. So the loop stops on evidence rather than a timer:
  `qm_bytes_read ide0` via the QEMU monitor tells the difference between "OVMF is looking
  at the DVD" and "Setup is streaming boot.wim off it". The third lesson, from the run
  after that fix: **stopping on evidence is only half of it, and starting on a timer
  loses the prompt.** That version kept the byte-counter stop but still pressed on a
  schedule inside a fixed twenty seconds opening the moment `qm start` returned, and each
  pass spawns two Perl programs, so the window bought
  seven or eight presses. OVMF with a TPM to measure does not reach the DVD that fast.
  The operator watched the window expire and answered the prompt by hand. Both halves are
  the same question - is the prompt on screen now - so the counter answers both: zero
  means the firmware has not opened the disc and there is nothing to answer, a number
  that has stopped moving is the prompt waiting, and a number still climbing means
  something is streaming and no key is wanted. Keys go out only in that middle state,
  which is what lets `BOOT_KEY_SECONDS` be patient (180s) without ever hammering Cancel.
  Covered by four stubbed scenarios; the load-bearing one is `neverboots`, where the DVD
  is never opened and the correct number of keypresses is **zero**. Do not reintroduce a
  press that is not conditioned on the counter having stopped moving. The blind path,
  when the counter will not answer at all, keeps its own short budget
  (`BOOT_KEY_BLIND_SECONDS`) precisely because it cannot make that distinction.
  The fourth lesson, and the one that actually cost the builds: **the logic was right
  and could not run**, because it read the counter through `qm monitor`, which hangs on
  piped input and took the whole script with it. See the `qm monitor` entry under "Ruled
  out". Correct reasoning about the wrong mechanism still fails on real hardware, and
  only running it on real hardware showed which.
- **A bare `whiptail --msgbox` aborts the script.** Under `set -Eeuo pipefail`,
  whiptail returns non-zero when a box is dismissed with Esc, the `ERR` trap fires, and
  every answer already typed is gone. Every informational box ends `|| true`. Every box
  whose answer matters ends `|| exit_script` or `|| return`.
- **`Invoke-Child` must quote its `ArgumentList`.** `Start-Process` joins the array
  with plain spaces and quotes nothing, so a script at `...\install cert.ps1` reaches
  `powershell.exe` as `-File ...\install` and dies with "does not have a '.ps1'
  extension" (reproduced: exit `-196608`). `custom_safe_name` also turns spaces into
  hyphens on the way in, so both ends are covered.
- **In `Configure-Guest.ps1`, the Default User hive block stays above the
  `ApplyTweaks` gate.** That gate is answered by a prompt that calls itself cosmetic and
  not security relevant, and it ends in `exit 0`. The hive block runs the operator's
  `DefaultUser` scripts and registers `UserOnce`, which have nothing to do with taskbar
  layout, so only the cosmetic writes inside it are conditional. Moving it back below
  the gate silently disables a feature.
- Two traps in that code, both found by the dry-run suite rather than by reading:
  `custom_stage_dir` **sets** `CUSTOM_STAGE` and prints nothing, because calling it as
  `stage="$(custom_stage_dir)"` runs the assignment in a subshell and the global comes
  back empty on the other side. And `custom_have_tty` probes `/dev/tty` by opening it,
  because `[[ -r /dev/tty ]]` passes on a node that then fails with "No such device or
  address" when there is no controlling terminal - which is exactly what happens under
  a test runner, and would silently skip the editor.
- The security toggles in the unattended path (UAC, Defender, Core Isolation, lockout, blank
  passwords, Ctrl+Alt+Del) all default to leaving Windows as it ships. They exist because the
  operator explicitly asked to be able to loosen them. State the consequence once in the
  prompt, then do what was picked — do not re-litigate it in the docs or the scripts.
- `Setup-RDGateway.ps1` must stay **pure ASCII** and must run under **Windows PowerShell 5.1**
  (`powershell.exe`, not `pwsh` — the WMI fallback uses `[wmiclass]`, removed in PS 7).
- The RD authorization policies go through the documented `Win32_TSGateway*` WMI classes
  rather than the `RDS:` provider, because the WMI method signatures are explicit about what
  each flag means. Certificate binding is the one exception.
- Prose over bullet lists in docs. Be direct about what isn't known.

## Licensing note

Microsoft's terms call for an RDS CAL for connections made through an RD Gateway, even in
the two-concurrent-admin-session case. Nothing enforces it technically — the 120-day grace
period belongs to RD Session Host, not RD Gateway — so it's a compliance judgment, not a
functional blocker. Stated in the runbook; don't quietly drop it.
