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
| `windows-rdgw-vm.sh` | Proxmox host, root | Dry-run verified. **Run for real once**, see below |
| `Setup-RDGateway.ps1` | The Windows guest, elevated | Written, parse/lint verified, **never run for real** |
| `Configure-Guest.ps1` | The Windows guest, SYSTEM | Written, parse/lint verified, **never run for real** |
| `Invoke-GatewaySetup.ps1` | The Windows guest, SYSTEM | Written, parse/lint verified, **never run for real** |
| `Invoke-CustomScripts.ps1` | The Windows guest | **Executed for real** on Windows PowerShell 5.1, see below |
| `sample-autounattend.xml` | — | Committed sample of generated output. Not read by anything |
| `vps-relay-setup.sh` | A public VPS | Optional path. Written, dry-run verified, **never run for real** |
| `proxmox-relay-peer.sh` | Proxmox host, root | Optional path. Written, dry-run verified, **never run for real** |
| `README.md` | — | Repo intro plus the full runbook |
| `RELAY.md` | — | The optional relay: architecture, steps, caveats |

The operator ran `windows-rdgw-vm.sh` on the real Proxmox host on 2026-09-19. The
VM was built and started, and then stopped dead at the Windows DVD's "Press any
key to boot from CD or DVD" prompt, which nobody was there to answer. That is
fixed: `press_a_key` now answers it from the host with `qm sendkey`. Nothing
past that point has been observed on real hardware, so everything under
"Assumed, never executed" still stands.

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

**Rebuilding the Windows ISO around `efisys_noprompt.bin` to kill the boot prompt.**
The no-prompt boot image really does ship on the media, next to `efisys.bin`, and
re-mastering with xorriso really would stop the DVD asking for a keypress. It also
breaks the install. Windows Setup reboots two or three times before it finishes, the
DVD is still first in the boot order each time, and the prompt timing out is exactly
what lets those reboots fall through to the disk instead of starting the install
over. Remove the prompt and you get an endless reinstall loop unless something also
changes the boot order mid-install, which nothing does. The prompt is load-bearing.
`press_a_key` answers it once from the host instead and leaves the timeout behaviour
intact for every later boot.

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
- `qm sendkey <vmid> <key>` is confirmed against the `qm` manual page.
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

- No script has touched a real Proxmox host. `--efidisk0 <storage>:1,efitype=4m` and
  `--tpmstate0 <storage>:1,version=v2.0` come from docs and forum usage, not from a run here.
- The WMI calls have never run against a real RD Gateway. If something breaks first, expect
  it here.
- `Administrators@BUILTIN` / `Remote Desktop Users@BUILTIN` for local groups on a
  non-domain-joined gateway comes from a published workgroup example. Microsoft's own class
  reference documents `UserGroupNames` as `Domain\UserGroupName`. **Verify after the first
  run** — the script prints `UserGroupNames` back specifically so this is checkable:
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
- **Nothing else about the unattended path has been executed.** The riskiest parts, in order:
  the `/IMAGE/NAME` value must match the media exactly and differs on Evaluation ISOs; the
  `$WinPEDriver$` scan is documented for Windows Server but has not been watched working
  here; and the `RDGW-FirstBoot` scheduled task's reboot handoff is reasoned about rather
  than observed. Each failure is visible and recoverable — Setup stops at a readable error,
  and the task logs every step to `C:\Windows\Setup\Scripts
dgw-setup.log` and stays
  registered so a reboot retries — but none of it has met a real disk.
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
