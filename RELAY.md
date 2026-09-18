# Public relay — reaching the gateway without opening a port

An optional front door for the RD Gateway. Use it if you don't want TCP 443 open on your home WAN, or if your ISP has you behind CGNAT and you couldn't forward it anyway.

**Your client devices install nothing.** No WARP, no WireGuard, no cloudflared, no browser client. They type a hostname into the native RD client exactly as they would with a port-forward. The tunnel described here runs between two machines you own — a small VPS and your Proxmox host — and is invisible to everything else.

---

## Why not Cloudflare Tunnel

RD Gateway's transport doesn't use ordinary HTTP verbs. It opens two long-lived requests with the custom methods `RDG_IN_DATA` and `RDG_OUT_DATA`, and Cloudflare's edge runs an HTTP method allowlist — those two come back `501`, generated at the edge, before the request is ever forwarded. You can confirm it yourself against any proxied hostname:

```bash
curl -s -o /dev/null -X RDG_IN_DATA  -w '%{http_code}\n' https://any-cloudflare-site.example/
curl -s -o /dev/null -X PROPFIND     -w '%{http_code}\n' https://any-cloudflare-site.example/
```

The first returns `501`; the second reaches the origin and gets whatever the origin says. The `501` response carries a `cf-ray` header but no `cf-cache-status`, which is how you know it never left the edge.

No amount of `cloudflared` configuration reaches this. `disableChunkedEncoding` and the request-buffering controls are real settings that RD Gateway genuinely needs from a reverse proxy, and they all sit downstream of the point where the request already died. Cloudflare Tunnel also can't carry UDP on a public hostname, so the 3391 transport was never going to survive either.

This relay solves it by not speaking HTTP at all.

---

## The shape of it

```
  RD client                VPS (public IP)              your house
 ┌──────────┐            ┌────────────────┐         ┌──────────────────────┐
 │ mstsc /  │──TLS:443──▶│ nginx stream   │         │ Proxmox host         │
 │ Windows  │            │ (layer 4 only, │══wg0═══▶│  └─ forwards + NAT   │
 │ App      │◀─UDP:3391─▶│  no TLS term)  │         │      └─▶ RDGW01:443  │
 └──────────┘            └────────────────┘         └──────────────────────┘
                              ▲                            ▲
                     dials nothing inward          dials OUT to the VPS
```

nginx runs in `stream` mode with `ssl_preread`, which reads the SNI to pick a backend without decrypting anything. TLS terminates on the Windows box, exactly as it would with a port-forward. Three things follow from that:

The relay never holds your certificate and cannot read a byte of your session. Your win-acme setup on the gateway keeps working untouched — it validates over Cloudflare DNS-01 and never needed inbound 80 or 443 anyway. And because nothing on the path parses HTTP, the custom-verb problem simply doesn't arise.

The WireGuard link is dialled **outbound** from your Proxmox host, so your router still has nothing forwarded and nothing listening.

---

## What it costs

A VPS with a public IPv4, which is about $4–5/month anywhere reasonable. Pick a region near you — you're adding a hop, and RDP notices latency more than bandwidth. The bandwidth itself is modest; an RDP session is typically single-digit Mbps, against the 1–2 TB/month these plans include.

---

## Running it

**1. On the VPS**, as root:

```bash
bash vps-relay-setup.sh
```

It asks for the LAN IP of your gateway VM, installs WireGuard and `nginx-full` (the stream module isn't in `nginx-light`), generates both keypairs, writes the nginx stream config, and drops the home-side values in `/root/proxmox-peer-wg0.env`.

`DRY_RUN=1 bash vps-relay-setup.sh` prints every command and every file it would write, and changes nothing.

**2. Move the env file** to the Proxmox host over scp. It contains a private key — don't paste it through a chat window, and shred it on both ends when you're done.

**3. On the Proxmox host**, as root:

```bash
source proxmox-peer-wg0.env && bash proxmox-relay-peer.sh
```

That brings up the tunnel, enables forwarding, and installs four firewall rules scoped to exactly the gateway VM and exactly the two ports. The rules live in the WireGuard config's `PostUp`/`PostDown`, so they appear and disappear with the interface rather than lingering in your ruleset.

**4. Point DNS at the relay.** In Cloudflare, `rdg.yourdomain.tld` becomes an **A record for the VPS address, DNS only — grey cloud.** Orange-clouding it would put the HTTP pipeline back in the path, which is the thing that can't carry this protocol.

---

### The NAT rule, and why it's there

Your Windows VM's default gateway is your router, not the Proxmox host. Without source NAT it would receive the relayed connection fine and then answer by shipping replies out the front door, where they'd arrive from an address the client never dialled and get dropped. Masquerading rewrites the source to the Proxmox host's LAN address so the replies come back the way they arrived.

The cost of that is the one real downside of this design: **RD Gateway logs every connection as coming from the relay's tunnel address**, not the real client. A layer 4 proxy has nowhere to put the original address and RD Gateway doesn't speak PROXY protocol, so this isn't fixable without terminating TLS on the relay — which would mean putting your certificate and your plaintext on a rented box.

Practically: per-source-IP blocking moves to the VPS, where `ufw` or your provider's cloud firewall can do it. Event 4625 on the gateway still tells you *that* someone is guessing passwords, just not *who*.

---

## Checking it works

From the VPS, once both ends are up:

```bash
wg show                          # a handshake within the last couple of minutes
nc -vz 192.168.1.50 443          # the gateway answers through the tunnel
```

From anywhere off your LAN — a phone on cellular is the honest test, since consumer routers often don't hairpin:

```bash
openssl s_client -connect rdg.yourdomain.tld:443 -servername rdg.yourdomain.tld
```

The certificate that comes back should be the one on your gateway. If it is, the relay is passing TLS straight through rather than terminating it, and you can point the RD client at that hostname with no other changes.

---

## When something breaks

**No handshake.** Check UDP 51820 is open on the VPS — both in `ufw` and in your provider's cloud firewall, which is a separate thing people forget. `wg show` on either end tells you whether packets are moving.

**Handshake fine, `nc` fails.** The tunnel is up but forwarding isn't. Confirm `net.ipv4.ip_forward` is 1 on Proxmox, and check whether the Proxmox datacenter firewall is enabled — if it is, it filters the forward path independently of the `iptables` rules the script installs, and you'll need a matching rule there.

**`nc` works but the client doesn't connect.** DNS is probably still orange-clouded. `dig rdg.yourdomain.tld +short` should return your VPS address, not a Cloudflare one (`104.x`, `172.67.x`).

**The UDP transport misbehaves.** RDP over UDP through a stateless proxy is the least certain part of this. Delete the second `server` block from `/etc/nginx/streams-available/rdgw.conf` and reload — you lose some smoothness on a high-latency link and nothing else. TCP 443 alone is a complete, working configuration.

---

## Backing it out

```bash
# Proxmox host
bash proxmox-relay-peer.sh --down

# VPS
systemctl disable --now wg-quick@wg0
rm -f /etc/nginx/streams-enabled/rdgw.conf && systemctl reload nginx
```

Then repoint DNS at your WAN address and forward 443 if you want the direct path back.

---

## Sources

- [MS-TSGU 2.1.2 — HTTP Transport](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsgu/9532a7c5-299d-4503-8fa1-15c2335a2fde) — the spec explicitly supports a reverse proxy terminating the client connection
- [FreeRDP #6731](https://github.com/FreeRDP/FreeRDP/issues/6731) — what a reverse proxy has to get right for `RDG_IN_DATA`: no chunked re-encoding, no buffering either direction
- [ngx_stream_proxy_module](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html) — `proxy_timeout`, `proxy_responses`, UDP proxying
- [ngx_stream_ssl_preread_module](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html) — SNI routing without decryption
- [Cloudflare: public hostnames don't support UDP](https://community.cloudflare.com/t/public-hostname-udp/452994)
- [Cloudflare community: RD Gateway via proxied](https://community.cloudflare.com/t/microsoft-remote-desktop-gateway-via-proxied/245148) — works grey-clouded, fails orange
