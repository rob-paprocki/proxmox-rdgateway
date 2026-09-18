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
| `windows-rdgw-vm.sh` | Proxmox host, root | Written, dry-run verified, **never run for real** |
| `Setup-RDGateway.ps1` | The Windows guest, elevated | Written, parse/lint verified, **never run for real** |
| `vps-relay-setup.sh` | A public VPS | Optional path. Written, dry-run verified, **never run for real** |
| `proxmox-relay-peer.sh` | Proxmox host, root | Optional path. Written, dry-run verified, **never run for real** |
| `README.md` | — | Repo intro plus the full runbook |
| `RELAY.md` | — | The optional relay: architecture, steps, caveats |

Nothing has been deployed. No VM exists yet.

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

**Cloudflare Tunnel / Workers / any orange-clouded hostname.** RD Gateway's HTTP transport
uses the custom methods `RDG_IN_DATA` and `RDG_OUT_DATA` (MS-TSGU). Cloudflare's edge runs an
HTTP method allowlist and returns `501` for both, generated at the edge — the request never
reaches the origin, and never reaches a Worker. Verified empirically:

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

**Cloudflare Spectrum.** The only Cloudflare product that proxies arbitrary TCP. Business
plan and up, roughly $200/month.

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

- All four shell scripts: `bash -n` and `shellcheck -S warning` clean; exercised end to end
  with `DRY_RUN=1` against stubbed `qm` / `pvesm` / `pvesh` / `whiptail`, covering the default
  path, the advanced path, and the virtio-download path.
- The generated nginx stream config passes `nginx -t` against a real nginx with the stream
  module loaded.
- Every `iptables` rule parses under `iptables-translate`.
- `Setup-RDGateway.ps1` parses; PSScriptAnalyzer reports nothing beyond `Write-Host` and
  `ShouldProcess` style notes; the file is deliberately **pure ASCII** because Windows
  PowerShell 5.1 reads a BOM-less file as Windows-1252 and would mangle anything else.
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
- **RDP-over-UDP through nginx stream is the least certain thing in the repo.** Note that
  `proxy_responses 0` was removed from that block deliberately: `nginx -t` accepts it silently
  but it caps how many datagrams come back and would break the session at runtime. If UDP
  misbehaves, delete the whole second `server` block — TCP 443 alone is complete.

## Next steps

1. Settle the CGNAT question. It decides everything downstream.
2. Run `windows-rdgw-vm.sh` on the Proxmox host. Start with `DRY_RUN=1`.
3. Install Windows from the console — Setup shows **no disks** until `vioscsi\2k25\amd64` is
   loaded from the second CD. That's expected, not a failure.
4. Run `Setup-RDGateway.ps1` with `-TargetMachines` listing every machine he wants to reach.
   Check the `UserGroupNames` readback.
5. Each target machine needs only: RDP enabled, his account in its local Remote Desktop Users
   group, firewall allowing 3389 from the gateway, and a name the gateway can resolve.
   Windows Pro is fine as a target; only the gateway has to be Server.

## Conventions used here

- Shell scripts print every command before running it and honour `DRY_RUN=1`. Keep that —
  the operator explicitly wants to follow along rather than be handed a black box.
- Generated config files are echoed in dry-run mode too.
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
