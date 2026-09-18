#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  vps-relay-setup.sh
#
#  Turns a cheap Debian/Ubuntu VPS into a public front door for an RD Gateway
#  that lives behind CGNAT or a firewall you do not want to open.
#
#      client ──TLS──▶ VPS:443 ──nginx stream (no TLS termination)──▶
#                       wg0 ──▶ Proxmox host ──▶ Windows RD Gateway
#
#  nginx runs at layer 4 with ssl_preread, so TLS terminates on the Windows box,
#  not here. This VPS never holds your certificate or sees a byte of plaintext,
#  and win-acme with Cloudflare DNS-01 keeps working on the gateway untouched.
#
#  CLIENT DEVICES INSTALL NOTHING. The WireGuard link is between this VPS and
#  your Proxmox host only. Clients just see a public hostname on 443.
#
#  Run this FIRST, then run proxmox-relay-peer.sh on the Proxmox host with the
#  values this script prints at the end.
#
#  Usage:
#      sudo bash vps-relay-setup.sh
#      DRY_RUN=1 bash vps-relay-setup.sh    # print every command, change nothing
#
#  License: MIT
# ------------------------------------------------------------------------------

set -Eeuo pipefail

CL=$'\033[m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'
CM=" ${GN}✔${CL}"; CROSS=" ${RD}✘${CL}"; INFO=" ${BL}ℹ${CL}"

DRY_RUN="${DRY_RUN:-0}"

# Defaults — override by exporting before running.
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_NET="${WG_NET:-10.77.0.0/24}"
WG_VPS_IP="${WG_VPS_IP:-10.77.0.1}"
WG_HOME_IP="${WG_HOME_IP:-10.77.0.2}"
RDGW_PORT="${RDGW_PORT:-443}"
UDP_PORT="${UDP_PORT:-3391}"

msg_info()  { printf "%s %s...\n" "${INFO}" "$1"; }
msg_ok()    { printf "%s %s\n"    "${CM}"   "$1"; }
msg_warn()  { printf " ${YW}!${CL} %s\n"    "$1"; }
msg_error() { printf "%s %s\n"    "${CROSS}" "$1"; }

error_handler() {
  printf "\n%s Failed at line %s: %s%s%s\n" "${CROSS}" "$1" "${RD}" "$2" "${CL}"
  printf "   Partial state may exist. 'wg-quick down %s' and remove\n" "$WG_IF"
  printf "   /etc/nginx/streams-enabled/rdgw.conf to back out.\n"
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
# Write a file, showing what goes into it. Honours DRY_RUN.
write_file() {
  local path="$1" mode="${2:-644}" content
  content="$(cat)"
  printf "   ${DIM}\$ write %s (mode %s)${CL}\n" "$path" "$mode"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "$content" | sed 's/^/       │ /'
    return
  fi
  install -d -m 755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  [[ "$(id -u)" -eq 0 ]] || { msg_error "Run as root (sudo bash $0)."; exit 1; }

  if ! command -v apt-get >/dev/null 2>&1; then
    msg_error "This expects Debian or Ubuntu. Adapt the package steps for anything else."
    exit 1
  fi

  # A relay with no public address is not a relay.
  PUBLIC_IP="${PUBLIC_IP:-}"
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    msg_error "Could not determine this host's public IP. Re-run with PUBLIC_IP=x.x.x.x"
    exit 1
  fi
  msg_ok "Public IP: ${BL}${PUBLIC_IP}${CL}"

  # Refuse to fight whatever already owns 443.
  if ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${RDGW_PORT}\$"; then
    msg_warn "Something is already listening on TCP ${RDGW_PORT}:"
    ss -lntp 2>/dev/null | grep -E "[:.]${RDGW_PORT}\s" | sed 's/^/     /'
    msg_warn "nginx will fail to bind. Stop it, or re-run with RDGW_PORT=8443."
    read -r -p "   Continue anyway? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 0
  fi
  msg_ok "Preflight checks passed"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
clear
cat <<'EOF'
  ____  ____     ____       _                             _
 |  _ \|  _ \   / ___| __ _| |_ _____      ____ _ _   _  | |    ___  ___ __ _ _   _
 | |_) | | | | | |  _ / _` | __/ _ \ \ /\ / / _` | | | | | |   / _ \/ __/ _` | | | |
 |  _ <| |_| | | |_| | (_| | ||  __/\ V  V / (_| | |_| | | |  |  __/ (_| (_| | |_| |
 |_| \_\____/   \____|\__,_|\__\___| \_/\_/ \__,_|\__, | |_|   \___|\___\__,_|\__, |
                                                  |___/                       |___/
                        public relay — VPS side
EOF
echo

[[ "$DRY_RUN" == "1" ]] && msg_warn "DRY_RUN=1 — printing only, nothing will change"

preflight

# --- the one thing we must be told ------------------------------------------
if [[ -z "${RDGW_LAN_IP:-}" ]]; then
  echo
  printf " %sWhat is the LAN IP of your Windows RD Gateway VM?%s\n" "${BOLD}" "${CL}"
  printf " (the address you pinned in Phase 3 — e.g. 192.168.1.50)\n"
  read -r -p " > " RDGW_LAN_IP
fi
if ! [[ "$RDGW_LAN_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  msg_error "'$RDGW_LAN_IP' is not an IPv4 address."
  exit 1
fi
msg_ok "Gateway target: ${BL}${RDGW_LAN_IP}:${RDGW_PORT}${CL}"

# --- packages ----------------------------------------------------------------
msg_info "Installing WireGuard and nginx"
run apt-get update -qq
# nginx-full carries the stream module on Debian/Ubuntu; nginx-light does not.
run apt-get install -y -qq wireguard nginx-full curl iproute2
msg_ok "Packages installed"

if [[ "$DRY_RUN" != "1" ]] && ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  msg_error "This nginx was built without the stream module. Install nginx-full."
  exit 1
fi
msg_ok "nginx has the stream module"

# --- keys --------------------------------------------------------------------
msg_info "Generating WireGuard keys"
if [[ "$DRY_RUN" == "1" ]]; then
  VPS_PRIV="<generated>"; VPS_PUB="<generated>"
  HOME_PRIV="<generated>"; HOME_PUB="<generated>"
else
  umask 077
  install -d -m 700 /etc/wireguard
  VPS_PRIV="$(wg genkey)";  VPS_PUB="$(printf '%s' "$VPS_PRIV"  | wg pubkey)"
  HOME_PRIV="$(wg genkey)"; HOME_PUB="$(printf '%s' "$HOME_PRIV" | wg pubkey)"
fi
msg_ok "Keypairs generated for both ends"

# --- wireguard ---------------------------------------------------------------
msg_info "Writing /etc/wireguard/${WG_IF}.conf"
write_file "/etc/wireguard/${WG_IF}.conf" 600 <<EOF
# RD Gateway relay — VPS side. Generated $(date -Is).
# This tunnel carries ONLY traffic between this VPS and the Proxmox host.
[Interface]
Address    = ${WG_VPS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIV}

[Peer]
# Proxmox host at home. It dials out to us, so nothing inbound is needed there.
PublicKey  = ${HOME_PUB}
AllowedIPs = ${WG_HOME_IP}/32, ${RDGW_LAN_IP}/32
EOF

run systemctl enable --now "wg-quick@${WG_IF}"
msg_ok "WireGuard up on ${WG_IF} (UDP ${WG_PORT})"

# --- nginx stream ------------------------------------------------------------
# Only emit [::] listeners if this host actually has global IPv6. On a v4-only
# VPS nginx refuses to bind them and 'nginx -t' fails outright.
if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
  LISTEN6_TCP="    listen [::]:${RDGW_PORT};"
  LISTEN6_UDP="    listen [::]:${UDP_PORT} udp;"
  msg_ok "Global IPv6 present — the relay will listen on both families"
else
  LISTEN6_TCP=""
  LISTEN6_UDP=""
  msg_warn "No global IPv6 on this host; listening on IPv4 only"
fi

# Layer 4 only. ssl_preread reads the SNI without decrypting, which leaves room
# to add more backends later without touching the RD Gateway path.
msg_info "Writing the nginx stream configuration"
write_file /etc/nginx/streams-available/rdgw.conf 644 <<EOF
# RD Gateway relay. Generated $(date -Is) by vps-relay-setup.sh
#
# No ssl_certificate here on purpose: TLS terminates on the Windows box.
# This host is a pipe and cannot read the traffic.

map \$ssl_preread_server_name \$rdgw_upstream {
    # Add more names here later, e.g.
    #   other.example.com  10.77.0.9:443;
    default  ${RDGW_LAN_IP}:${RDGW_PORT};
}

server {
    listen ${RDGW_PORT};
${LISTEN6_TCP}
    ssl_preread on;
    proxy_pass \$rdgw_upstream;

    # RD sessions idle while you read something. Do not cut them at 10 minutes.
    proxy_timeout        12h;
    proxy_connect_timeout 10s;
}

server {
    # RD Gateway's UDP transport. Optional — TCP alone works, this just makes
    # a high-latency link feel better. Drop this block if it misbehaves.
    listen ${UDP_PORT} udp;
${LISTEN6_UDP}
    proxy_pass ${RDGW_LAN_IP}:${UDP_PORT};

    # Do NOT set proxy_responses here. It caps how many datagrams nginx will
    # relay back per client datagram, and RDP-over-UDP is a two-way stream.
    proxy_timeout 10m;
}
EOF

run install -d -m 755 /etc/nginx/streams-enabled
run ln -sfn /etc/nginx/streams-available/rdgw.conf /etc/nginx/streams-enabled/rdgw.conf

# Debian's nginx.conf has no stream{} block by default; add an include once.
if [[ "$DRY_RUN" == "1" ]]; then
  printf "   ${DIM}\$ ensure nginx.conf includes streams-enabled/*.conf${CL}\n"
elif ! grep -q 'streams-enabled' /etc/nginx/nginx.conf; then
  msg_info "Adding the stream{} include to nginx.conf"
  cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
  cat >> /etc/nginx/nginx.conf <<'EOF'

# Added by vps-relay-setup.sh — layer 4 proxying for RD Gateway.
stream {
    include /etc/nginx/streams-enabled/*.conf;
}
EOF
  msg_ok "stream{} block added (original backed up)"
else
  msg_ok "nginx.conf already includes streams-enabled"
fi

msg_info "Testing and reloading nginx"
run nginx -t
run systemctl enable --now nginx
run systemctl reload nginx
msg_ok "nginx listening on ${RDGW_PORT}/tcp and ${UDP_PORT}/udp"

# --- firewall ----------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  msg_info "Opening ports in ufw"
  run ufw allow "${RDGW_PORT}/tcp"
  run ufw allow "${UDP_PORT}/udp"
  run ufw allow "${WG_PORT}/udp"
  msg_ok "ufw rules added"
else
  msg_warn "ufw is not active. If your provider has a cloud firewall, allow:"
  printf "     TCP %s, UDP %s, UDP %s\n" "$RDGW_PORT" "$UDP_PORT" "$WG_PORT"
fi

# --- hand-off ----------------------------------------------------------------
HOME_CONF="/root/proxmox-peer-${WG_IF}.env"
msg_info "Saving the home-side values to ${HOME_CONF}"
write_file "$HOME_CONF" 600 <<EOF
# Feed these to proxmox-relay-peer.sh on the Proxmox host.
# Generated $(date -Is) on the relay. Treat WG_HOME_PRIVKEY as a secret.
export WG_IF="${WG_IF}"
export WG_HOME_IP="${WG_HOME_IP}"
export WG_VPS_IP="${WG_VPS_IP}"
export WG_HOME_PRIVKEY="${HOME_PRIV}"
export WG_VPS_PUBKEY="${VPS_PUB}"
export WG_VPS_ENDPOINT="${PUBLIC_IP}:${WG_PORT}"
export RDGW_LAN_IP="${RDGW_LAN_IP}"
EOF
msg_ok "Saved"

cat <<EOF

${BOLD}${GN}Relay is up.${CL} Two things left.

${BOLD}1. Bring up the home end${CL}
   Copy ${BL}${HOME_CONF}${CL} and ${BL}proxmox-relay-peer.sh${CL} to the Proxmox host, then:

   ${DIM}\$ source proxmox-peer-${WG_IF}.env && bash proxmox-relay-peer.sh${CL}

   That file holds a private key. Move it over ssh/scp, not a chat window, and
   delete it from both machines afterwards.

${BOLD}2. Point DNS at this box${CL}
   In Cloudflare, set ${BL}rdg.yourdomain.tld${CL} to an ${BOLD}A record${CL} for ${BL}${PUBLIC_IP}${CL},
   ${BOLD}DNS only (grey cloud)${CL}. Proxying it would put the orange-cloud HTTP
   pipeline back in the path, which is the thing that cannot carry RD Gateway.

${BOLD}Then check it${CL}
   From the VPS, once the home end is up:
     ${DIM}\$ wg show${CL}                                    ${DIM}# handshake within ~30s${CL}
     ${DIM}\$ nc -vz ${RDGW_LAN_IP} ${RDGW_PORT}${CL}                     ${DIM}# reaches the gateway${CL}
   From anywhere:
     ${DIM}\$ openssl s_client -connect rdg.yourdomain.tld:${RDGW_PORT} -servername rdg.yourdomain.tld${CL}
   You should see the certificate issued to your gateway — proof the relay is
   passing TLS through rather than terminating it.

${BOLD}What this costs you${CL}
   RD Gateway will log every connection as arriving from ${BL}${WG_VPS_IP}${CL} rather
   than the real client, because a layer 4 proxy has nowhere to put the original
   address and RD Gateway does not speak PROXY protocol. Per-source-IP blocking
   on the gateway is therefore off the table; do that here instead, with ufw or
   your provider's firewall.

EOF
