#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  proxmox-relay-peer.sh
#
#  Home end of the RD Gateway public relay. Run this on the Proxmox host AFTER
#  vps-relay-setup.sh has run on the VPS.
#
#  It brings up a WireGuard link to the relay and forwards the relayed traffic
#  on to the Windows RD Gateway VM. The link is outbound-only: nothing is opened
#  on your WAN, and no client device is involved at any point.
#
#  Why the NAT rule below exists: the Windows VM's default gateway is your
#  router, not this host. Without source NAT it would answer the relay by
#  shipping replies out the front door, and the connection would never complete.
#  Masquerading makes the traffic look like it came from this host, so replies
#  come back the way they arrived.
#
#  Usage, with the env file the VPS script wrote:
#      source proxmox-peer-wg0.env && bash proxmox-relay-peer.sh
#
#      DRY_RUN=1 bash proxmox-relay-peer.sh     # print everything, change nothing
#      bash proxmox-relay-peer.sh --down        # tear it back down
#
#  License: MIT
# ------------------------------------------------------------------------------

set -Eeuo pipefail

CL=$'\033[m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'
CM=" ${GN}✔${CL}"; CROSS=" ${RD}✘${CL}"; INFO=" ${BL}ℹ${CL}"

DRY_RUN="${DRY_RUN:-0}"
WG_IF="${WG_IF:-wg0}"
RDGW_PORT="${RDGW_PORT:-443}"
UDP_PORT="${UDP_PORT:-3391}"
KEEPALIVE="${KEEPALIVE:-25}"

msg_info()  { printf "%s %s...\n" "${INFO}" "$1"; }
msg_ok()    { printf "%s %s\n"    "${CM}"   "$1"; }
msg_warn()  { printf " ${YW}!${CL} %s\n"    "$1"; }
msg_error() { printf "%s %s\n"    "${CROSS}" "$1"; }

error_handler() {
  printf "\n%s Failed at line %s: %s%s%s\n" "${CROSS}" "$1" "${RD}" "$2" "${CL}"
  printf "   Back out with: bash %s --down\n" "$0"
  exit 1
}
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

shell_quote() {
  local arg out=""
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_.:=/@%,+-]+$ ]]; then out+="$arg "
    else out+="'${arg//\'/\'\\\'\'}' "; fi
  done
  printf '%s' "${out% }"
}
run() {
  printf "   ${DIM}\$ %s${CL}\n" "$(shell_quote "$@")"
  [[ "$DRY_RUN" == "1" ]] || "$@"
}
write_file() {
  local path="$1" mode="${2:-644}" content
  content="$(cat)"
  printf "   ${DIM}\$ write %s (mode %s)${CL}\n" "$path" "$mode"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "$content" | sed 's/^/       │ /'
    return
  fi
  install -d -m 700 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--down" ]]; then
  msg_info "Tearing down ${WG_IF}"
  run systemctl disable --now "wg-quick@${WG_IF}" || true
  run rm -f "/etc/wireguard/${WG_IF}.conf"
  msg_ok "Down. The PostDown rules removed the firewall entries with the interface."
  exit 0
fi

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
clear
cat <<'EOF'
   ____      _                             _
  |  _ \ ___| | __ _ _   _   _ __   ___  ___ _ __
  | |_) / _ \ |/ _` | | | | | '_ \ / _ \/ _ \ '__|
  |  _ <  __/ | (_| | |_| | | |_) |  __/  __/ |
  |_| \_\___|_|\__,_|\__, | | .__/ \___|\___|_|
                     |___/  |_|
                 home side — Proxmox host
EOF
echo

[[ "$DRY_RUN" == "1" ]] && msg_warn "DRY_RUN=1 — printing only, nothing will change"

[[ "$(id -u)" -eq 0 ]] || { msg_error "Run as root on the Proxmox host."; exit 1; }

missing=()
for v in WG_HOME_IP WG_VPS_IP WG_HOME_PRIVKEY WG_VPS_PUBKEY WG_VPS_ENDPOINT RDGW_LAN_IP; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  msg_error "Missing: ${missing[*]}"
  printf "   These come from the env file vps-relay-setup.sh wrote on the relay:\n"
  printf "     ${DIM}\$ source proxmox-peer-%s.env && bash %s${CL}\n" "$WG_IF" "$0"
  exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
  msg_warn "pveversion not found — this does not look like a Proxmox host."
  read -r -p "   Continue anyway? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || exit 0
fi

printf " ${BOLD}Relay${CL}    %s  (tunnel %s)\n" "$WG_VPS_ENDPOINT" "$WG_VPS_IP"
printf " ${BOLD}This host${CL} tunnel %s\n" "$WG_HOME_IP"
printf " ${BOLD}Forwards${CL} to %s on %s/tcp and %s/udp\n\n" "$RDGW_LAN_IP" "$RDGW_PORT" "$UDP_PORT"

# Is the gateway VM actually reachable from here? Catch it now, not later.
if [[ "$DRY_RUN" != "1" ]]; then
  if command -v nc >/dev/null 2>&1 && nc -z -w3 "$RDGW_LAN_IP" "$RDGW_PORT" 2>/dev/null; then
    msg_ok "${RDGW_LAN_IP}:${RDGW_PORT} answers from this host"
  else
    msg_warn "${RDGW_LAN_IP}:${RDGW_PORT} did not answer."
    msg_warn "Fine if the gateway is not configured yet — but if it is, fix that first."
  fi
fi

# ------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------
msg_info "Installing WireGuard"
run apt-get update -qq
run apt-get install -y -qq wireguard iptables
msg_ok "Installed"

msg_info "Writing /etc/wireguard/${WG_IF}.conf"
write_file "/etc/wireguard/${WG_IF}.conf" 600 <<EOF
# RD Gateway relay — home side. Generated $(date -Is).
#
# Outbound only: we dial the relay, so nothing is opened on the WAN.
# The PostUp rules forward relayed traffic to the gateway VM and masquerade it
# so the VM's replies come back through this host instead of out the router.

[Interface]
Address    = ${WG_HOME_IP}/24
PrivateKey = ${WG_HOME_PRIVKEY}

PostUp   = sysctl -q -w net.ipv4.ip_forward=1
PostUp   = iptables -I FORWARD 1 -i %i -d ${RDGW_LAN_IP} -p tcp --dport ${RDGW_PORT} -j ACCEPT
PostUp   = iptables -I FORWARD 1 -i %i -d ${RDGW_LAN_IP} -p udp --dport ${UDP_PORT} -j ACCEPT
PostUp   = iptables -I FORWARD 1 -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -t nat -I POSTROUTING 1 -s ${WG_VPS_IP}/32 -d ${RDGW_LAN_IP}/32 -j MASQUERADE

PostDown = iptables -D FORWARD -i %i -d ${RDGW_LAN_IP} -p tcp --dport ${RDGW_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i %i -d ${RDGW_LAN_IP} -p udp --dport ${UDP_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_VPS_IP}/32 -d ${RDGW_LAN_IP}/32 -j MASQUERADE

[Peer]
# The relay. AllowedIPs is deliberately just its tunnel address — this does NOT
# route your traffic through the VPS, it only accepts traffic from it.
PublicKey           = ${WG_VPS_PUBKEY}
Endpoint            = ${WG_VPS_ENDPOINT}
AllowedIPs          = ${WG_VPS_IP}/32
PersistentKeepalive = ${KEEPALIVE}
EOF

msg_info "Making IP forwarding survive reboots"
write_file /etc/sysctl.d/99-rdgw-relay.conf 644 <<'EOF'
# Required by the RD Gateway relay (proxmox-relay-peer.sh).
net.ipv4.ip_forward = 1
EOF
run sysctl -q --system
msg_ok "Forwarding enabled"

msg_info "Bringing up ${WG_IF}"
run systemctl enable --now "wg-quick@${WG_IF}"
msg_ok "Interface up"

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  msg_info "Waiting for the handshake (up to 30s)"
  ok=0
  for _ in $(seq 1 15); do
    if wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2}' | grep -qv '^0$'; then
      ok=1; break
    fi
    sleep 2
  done
  if [[ "$ok" -eq 1 ]]; then
    msg_ok "Handshake completed with ${WG_VPS_ENDPOINT}"
  else
    msg_warn "No handshake yet. Check that UDP ${WG_VPS_ENDPOINT##*:} is open on the relay,"
    msg_warn "and that the endpoint address is right. 'wg show ${WG_IF}' to watch."
  fi

  if ping -c1 -W3 "$WG_VPS_IP" >/dev/null 2>&1; then
    msg_ok "Relay answers on the tunnel (${WG_VPS_IP})"
  else
    msg_warn "No ping response from ${WG_VPS_IP} — not fatal, some hosts drop ICMP."
  fi

  if command -v pve-firewall >/dev/null 2>&1 && pve-firewall status 2>/dev/null | grep -qi 'Status: enabled'; then
    msg_warn "The Proxmox firewall is enabled. If traffic does not flow, it is filtering"
    msg_warn "the forward path — allow ${WG_VPS_IP} to reach ${RDGW_LAN_IP}:${RDGW_PORT} in the datacenter rules."
  fi
fi

cat <<EOF

${BOLD}${GN}Home end is up.${CL}

${BOLD}Confirm the whole path${CL}, from the relay:
   ${DIM}\$ wg show${CL}                              ${DIM}# a recent handshake${CL}
   ${DIM}\$ nc -vz ${RDGW_LAN_IP} ${RDGW_PORT}${CL}                ${DIM}# the gateway answers through the tunnel${CL}

Then from a phone on cellular, or anywhere off your LAN:
   ${DIM}\$ openssl s_client -connect rdg.yourdomain.tld:${RDGW_PORT} -servername rdg.yourdomain.tld${CL}

The certificate that comes back should be the one on your gateway. If it is,
the relay is passing TLS straight through and you can point the RD client at
that hostname.

${BOLD}Housekeeping${CL}
   Delete the env file on both machines now — it contains a private key:
   ${DIM}\$ shred -u proxmox-peer-${WG_IF}.env${CL}

${BOLD}If you rebuild the gateway VM on a different IP${CL}, update ${BL}RDGW_LAN_IP${CL}
in ${BL}/etc/wireguard/${WG_IF}.conf${CL} here and in ${BL}/etc/nginx/streams-available/rdgw.conf${CL}
plus the peer's AllowedIPs on the relay, then restart both ends.

EOF
