#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  windows-rdgw-vm.sh
#
#  Builds a Proxmox VE virtual machine sized and configured for a Windows Server
#  2025 RD Gateway host. Styled after the community-scripts/ProxmoxVE VM scripts,
#  but fully self-contained: it sources nothing from the network except the
#  optional VirtIO driver ISO download, so you can read every line before you
#  run it.
#
#  It does NOT install Windows. There is no cloud image for Windows, so the
#  script stops after building a correctly configured VM shell with both ISOs
#  attached and the boot order set. You run Windows Setup from the console, then
#  run Setup-RDGateway.ps1 inside the guest.
#
#  Usage:
#      bash windows-rdgw-vm.sh
#      DRY_RUN=1 bash windows-rdgw-vm.sh     # print the qm commands, run nothing
#
#  License: MIT
# ------------------------------------------------------------------------------

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Cosmetics
# ------------------------------------------------------------------------------
CL=$'\033[m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; DGN=$'\033[32m'
CM=" ${GN}✔${CL}"; CROSS=" ${RD}✘${CL}"; INFO=" ${BL}ℹ${CL}"

APP="Windows Server 2025 — RD Gateway"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
DRY_RUN="${DRY_RUN:-0}"

header_info() {
  clear
  cat <<'EOF'
 __        ___           ____  ____   ___ ____  ____    ____  ____   ______        __
 \ \      / (_)_ __     |___ \| ___| |_ _|___ \| ___|  |  _ \|  _ \ / ___\ \      / /
  \ \ /\ / /| | '_ \      __) |___ \  | |  __) |___ \  | |_) | | | | |  _ \ \ /\ / /
   \ V  V / | | | | |    / __/ ___) | | | / __/ ___) | |  _ <| |_| | |_| | \ V  V /
    \_/\_/  |_|_| |_|   |_____|____/ |___|_____|____/  |_| \_\____/ \____|  \_/\_/

EOF
}

msg_info()  { printf "%s %s...\n" "${INFO}" "$1"; }
msg_ok()    { printf "%s %s\n"    "${CM}"   "$1"; }
msg_warn()  { printf " ${YW}!${CL} %s\n"    "$1"; }
msg_error() { printf "%s %s\n"    "${CROSS}" "$1"; }

error_handler() {
  local line=$1 cmd=$2
  printf "\n%s The script failed at line %s: %s%s%s\n" "${CROSS}" "${line}" "${RD}" "${cmd}" "${CL}"
  printf "   Nothing was rolled back. If a VM shell was created, remove it with: qm destroy %s\n" "${VMID:-<vmid>}"
  exit 1
}
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# Run a command, showing it first. Honours DRY_RUN.
shell_quote() {
  local arg out=""
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_.:=/@%,+-]+$ ]]; then
      out+="$arg "
    else
      out+="'${arg//\'/\'\\\'\'}' "
    fi
  done
  printf '%s' "${out% }"
}

run() {
  printf "   ${DIM}\$ %s${CL}\n" "$(shell_quote "$@")"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

exit_script() { clear; printf "%s Cancelled — nothing was created.\n" "${CROSS}"; exit 0; }

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Run this on the Proxmox host as root."
    exit 1
  fi
  for bin in qm pvesm pvesh whiptail awk sed; do
    command -v "$bin" >/dev/null 2>&1 || { msg_error "Missing required command: $bin"; exit 1; }
  done
  if ! pveversion 2>/dev/null | grep -qE "pve-manager/(8|9|1[0-9])"; then
    msg_warn "This was written against Proxmox VE 8.x/9.x. Detected: $(pveversion 2>/dev/null | head -n1)"
    whiptail --backtitle "$APP" --yesno "Untested Proxmox version. Continue anyway?" 10 60 || exit_script
  fi
  if [[ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]]; then
    msg_error "Windows Server 2025 needs an x86_64 host."
    exit 1
  fi
  if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    msg_error "No hardware virtualisation (vmx/svm) detected. Enable VT-x/AMD-V in the host BIOS."
    exit 1
  fi
  msg_ok "Preflight checks passed"
}

get_valid_nextid() {
  local try_id
  try_id="$(pvesh get /cluster/nextid)"
  while true; do
    if [[ -f "/etc/pve/qemu-server/${try_id}.conf" || -f "/etc/pve/lxc/${try_id}.conf" ]]; then
      try_id=$((try_id + 1)); continue
    fi
    if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[[:space:]])vm-${try_id}-disk"; then
      try_id=$((try_id + 1)); continue
    fi
    break
  done
  echo "$try_id"
}

# ------------------------------------------------------------------------------
# Storage and ISO pickers
# ------------------------------------------------------------------------------

# select_storage <content-type> <prompt-title>  -> sets STORAGE_RESULT
select_storage() {
  local content="$1" title="$2"
  local -a menu=()
  local line name type avail

  while read -r line; do
    name="$(awk '{print $1}' <<<"$line")"
    type="$(awk '{print $2}' <<<"$line")"
    avail="$(awk '{printf "%.0fG", $6/1024/1024}' <<<"$line")"
    menu+=("$name" "type=${type} free=${avail}" "OFF")
  done < <(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"')

  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No active storage accepts content type '${content}'."
    exit 1
  fi
  if [[ ${#menu[@]} -eq 3 ]]; then
    STORAGE_RESULT="${menu[0]}"
    printf "%s %s storage: ${BL}%s${CL}\n" "${CM}" "$title" "$STORAGE_RESULT"
    return
  fi
  menu[2]="ON"
  STORAGE_RESULT="$(whiptail --backtitle "$APP" --title "$title" \
    --radiolist "Choose the storage to use:" 16 70 6 "${menu[@]}" 3>&1 1>&2 2>&3)" || exit_script
  printf "%s %s storage: ${BL}%s${CL}\n" "${CM}" "$title" "$STORAGE_RESULT"
}

# select_iso <title> <regex-hint>  -> sets ISO_RESULT (a volid), or empty
select_iso() {
  local title="$1" hint="${2:-}"
  local -a menu=()
  local st volid base

  while read -r st; do
    while read -r volid; do
      [[ -z "$volid" ]] && continue
      base="${volid##*/}"
      if [[ -n "$hint" && ! "$base" =~ $hint ]]; then continue; fi
      menu+=("$volid" "${base:0:58}" "OFF")
    done < <(pvesm list "$st" --content iso 2>/dev/null | awk '$1 ~ /:iso\// {print $1}')
  done < <(pvesm status --content iso 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

  if [[ ${#menu[@]} -eq 0 ]]; then
    ISO_RESULT=""
    return
  fi
  menu[2]="ON"
  ISO_RESULT="$(whiptail --backtitle "$APP" --title "$title" \
    --radiolist "Choose the ISO:" 20 78 10 "${menu[@]}" 3>&1 1>&2 2>&3)" || exit_script
}

# Resolve the on-disk directory a storage uses for ISOs, without the file existing.
iso_dir_for_storage() {
  local st="$1"
  pvesm path "${st}:iso/__probe__.iso" 2>/dev/null | sed 's#/__probe__\.iso$##'
}

fetch_virtio() {
  local st="$1" dir target
  dir="$(iso_dir_for_storage "$st")"
  if [[ -z "$dir" ]]; then
    msg_error "Could not resolve the ISO directory for storage '${st}'. Download virtio-win.iso manually."
    exit 1
  fi
  target="${dir}/virtio-win.iso"
  msg_info "Downloading the VirtIO driver ISO to ${target}"
  run mkdir -p "$dir"
  if [[ "$DRY_RUN" != "1" ]]; then
    if ! curl -fL --progress-bar -o "${target}.part" "$VIRTIO_URL"; then
      rm -f "${target}.part"
      msg_error "Download failed. Grab it yourself from ${VIRTIO_URL} and re-run."
      exit 1
    fi
    mv -f "${target}.part" "$target"
  fi
  VIRTIO_ISO="${st}:iso/virtio-win.iso"
  msg_ok "VirtIO ISO ready (${BL}${VIRTIO_ISO}${CL})"
}

# ------------------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------------------
default_settings() {
  VMID="$(get_valid_nextid)"
  HN="rdgw01"
  CORE_COUNT="4"
  RAM_SIZE="6144"
  DISK_SIZE="80"
  CPU_TYPE="host"
  MACHINE="q35"
  PREENROLL="1"
  ADD_TPM="yes"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  cat <<EOF
${DGN}VM ID          ${BL}${VMID}${CL}
${DGN}Hostname       ${BL}${HN}${CL}
${DGN}Cores          ${BL}${CORE_COUNT}${CL}
${DGN}RAM            ${BL}${RAM_SIZE} MiB${CL}
${DGN}Disk           ${BL}${DISK_SIZE} GiB${CL}
${DGN}CPU model      ${BL}${CPU_TYPE}${CL}
${DGN}Machine        ${BL}${MACHINE} + OVMF (UEFI)${CL}
${DGN}Secure Boot    ${BL}pre-enrolled MS keys${CL}
${DGN}TPM 2.0        ${BL}${ADD_TPM}${CL}
${DGN}Bridge         ${BL}${BRG}${CL}
${DGN}Start after    ${BL}${START_VM}${CL}
EOF
}

ask() {  # ask <title> <default> -> ASK_RESULT
  ASK_RESULT="$(whiptail --backtitle "$APP" --inputbox "$1" 9 66 "$2" --title "$1" 3>&1 1>&2 2>&3)" || exit_script
  if [[ -z "$ASK_RESULT" ]]; then ASK_RESULT="$2"; fi
  return 0
}

advanced_settings() {
  ask "VM ID" "$(get_valid_nextid)";              VMID="$ASK_RESULT"
  ask "Hostname / VM name" "rdgw01";              HN="$ASK_RESULT"
  ask "CPU cores" "4";                            CORE_COUNT="$ASK_RESULT"
  ask "RAM in MiB (4096 minimum for 2025)" "6144"; RAM_SIZE="$ASK_RESULT"
  ask "System disk size in GiB (32 minimum)" "80"; DISK_SIZE="$ASK_RESULT"

  CPU_TYPE="$(whiptail --backtitle "$APP" --title "CPU model" --radiolist \
    "host is fastest. x86-64-v2-AES lets you live-migrate between mismatched CPUs." 12 74 2 \
    "host"           "Pass the physical CPU through (recommended)" ON \
    "x86-64-v2-AES"  "Portable baseline for migration"             OFF 3>&1 1>&2 2>&3)" || exit_script

  MACHINE="q35"
  if whiptail --backtitle "$APP" --title "Secure Boot" \
      --yesno "Pre-enrol the Microsoft Secure Boot keys?\n\nYes = Secure Boot works out of the box. The stable VirtIO drivers are WHQL-signed, so this is safe.\n\nNo = Secure Boot disabled; pick this only if you plan to load unsigned drivers." 14 70; then
    PREENROLL="1"
  else
    PREENROLL="0"
  fi

  if whiptail --backtitle "$APP" --title "TPM 2.0" \
      --yesno "Add an emulated TPM 2.0?\n\nServer 2025 does not require one to install, but BitLocker and Credential Guard do. It costs 4 MiB." 12 70; then
    ADD_TPM="yes"
  else
    ADD_TPM="no"
  fi

  ask "Network bridge" "vmbr0";                   BRG="$ASK_RESULT"
  ask "MAC address" "$GEN_MAC";                   MAC="$ASK_RESULT"
  ask "VLAN tag (blank for none)" ""
  if [[ -n "$ASK_RESULT" ]]; then VLAN=",tag=$ASK_RESULT"; else VLAN=""; fi
  ask "MTU (blank for default)" ""
  if [[ -n "$ASK_RESULT" ]]; then MTU=",mtu=$ASK_RESULT"; else MTU=""; fi

  if whiptail --backtitle "$APP" --title "Start VM" --yesno "Start the VM when the script finishes?" 8 60; then
    START_VM="yes"
  else
    START_VM="no"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
header_info
GEN_MAC="02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')"

preflight

[[ "$DRY_RUN" == "1" ]] && msg_warn "DRY_RUN=1 — commands will be printed, not executed"

if whiptail --backtitle "$APP" --title "$APP" \
    --yesno "Build a Windows Server 2025 VM ready for the RD Gateway role.\n\nUse default settings?" 12 62 --defaultno; then
  printf "\n${BOLD}${DGN}Using default settings${CL}\n"
  default_settings
else
  printf "\n${BOLD}${YW}Using advanced settings${CL}\n"
  advanced_settings
fi

printf "\n"
# --- Windows ISO -------------------------------------------------------------
msg_info "Looking for Windows ISOs in your storages"
select_iso "Windows Server 2025 ISO" 'windows|win.*server|[Ss][Ww]_[Dd][Vv][Dd]'
if [[ -z "$ISO_RESULT" ]]; then
  msg_warn "Nothing matched 'windows'. Showing every ISO."
  select_iso "Select the Windows Server 2025 ISO"
fi
if [[ -z "$ISO_RESULT" ]]; then
  msg_error "No ISOs found. Upload the Windows Server 2025 ISO to a storage first."
  exit 1
fi
WIN_ISO="$ISO_RESULT"
msg_ok "Windows ISO: ${BL}${WIN_ISO}${CL}"

# --- VirtIO ISO --------------------------------------------------------------
select_iso "VirtIO driver ISO" 'virtio'
if [[ -n "$ISO_RESULT" ]]; then
  VIRTIO_ISO="$ISO_RESULT"
  msg_ok "VirtIO ISO: ${BL}${VIRTIO_ISO}${CL}"
else
  msg_warn "No virtio-win ISO found in storage"
  if whiptail --backtitle "$APP" --title "VirtIO drivers" \
      --yesno "Windows Setup cannot see a VirtIO SCSI disk without these drivers.\n\nDownload virtio-win.iso now (~700 MB)?" 12 68; then
    select_storage iso "VirtIO ISO"
    fetch_virtio "$STORAGE_RESULT"
  else
    msg_error "Cannot continue without the VirtIO ISO. Get it from:"
    printf "     %s\n" "$VIRTIO_URL"
    exit 1
  fi
fi

# --- Disk storage ------------------------------------------------------------
select_storage images "VM disk"
STORAGE="$STORAGE_RESULT"

# --- Build -------------------------------------------------------------------
printf "\n"
msg_info "Creating the VM shell"
run qm create "$VMID" \
  --name "$HN" \
  --machine "$MACHINE" \
  --bios ovmf \
  --ostype win11 \
  --cpu "$CPU_TYPE" \
  --sockets 1 \
  --cores "$CORE_COUNT" \
  --memory "$RAM_SIZE" \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU}" \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --vga std \
  --tablet 1 \
  --onboot 1 \
  --tags "windows;rdgateway" \
  --description "Windows Server 2025 RD Gateway. Built by windows-rdgw-vm.sh on $(date -Is)."
msg_ok "Created VM ${BL}${VMID}${CL} (${HN})"

msg_info "Adding the UEFI variable store"
run qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=${PREENROLL}"
msg_ok "EFI disk added (Secure Boot keys pre-enrolled: ${PREENROLL})"

if [[ "$ADD_TPM" == "yes" ]]; then
  msg_info "Adding the emulated TPM 2.0"
  run qm set "$VMID" --tpmstate0 "${STORAGE}:1,version=v2.0"
  msg_ok "TPM 2.0 added"
fi

msg_info "Adding the system disk"
run qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE},iothread=1,discard=on,ssd=1,cache=writeback"
msg_ok "Disk added (${DISK_SIZE} GiB, VirtIO SCSI single, writeback, discard)"

msg_info "Attaching the installation media"
run qm set "$VMID" --ide0 "${WIN_ISO},media=cdrom"
run qm set "$VMID" --ide2 "${VIRTIO_ISO},media=cdrom"
run qm set "$VMID" --boot "order=ide0;scsi0"
msg_ok "Both ISOs attached, booting from the Windows DVD first"

if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starting the VM"
  run qm start "$VMID"
  msg_ok "Started"
fi

# ------------------------------------------------------------------------------
# What happens next
# ------------------------------------------------------------------------------
cat <<EOF

${BOLD}${GN}VM ${VMID} is built.${CL} Windows is not installed yet — do that next.

${BOLD}1. Open the console${CL}
   Proxmox web UI -> VM ${VMID} -> Console. Press a key fast when it says
   "Press any key to boot from CD" — if you miss it you land in the UEFI shell;
   type ${BL}exit${CL}, pick Boot Manager, and choose the DVD.

${BOLD}2. Load the storage driver${CL}
   Windows Setup will show ${YW}no disks${CL}. That is expected.
   Click ${BL}Load driver${CL} -> Browse -> the second CD drive ->
   ${BL}vioscsi\\2k25\\amd64${CL} -> Next. The 80 GiB disk appears.
   While you are there, also load ${BL}NetKVM\\2k25\\amd64${CL} for the NIC.

${BOLD}3. Pick the right edition${CL}
   Choose a ${BL}(Desktop Experience)${CL} edition unless you are comfortable
   administering Server Core entirely from PowerShell.

${BOLD}4. First boot, inside Windows${CL}
   - Run ${BL}virtio-win-guest-tools.exe${CL} from the VirtIO CD. This installs the
     balloon driver, the QEMU guest agent and the rest of the VirtIO stack.
   - Give the machine a ${BL}static IP or a DHCP reservation${CL}. An RD Gateway
     whose address moves is an RD Gateway you cannot reach.
   - Windows Update, then reboot.

${BOLD}5. Detach the ISOs${CL}
   ${DIM}\$ qm set ${VMID} --ide0 none --ide2 none --boot order=scsi0${CL}

${BOLD}6. Configure the gateway${CL}
   Copy ${BL}Setup-RDGateway.ps1${CL} into the VM and run it from an elevated
   PowerShell prompt. See RDGW-RUNBOOK.md for the DNS, certificate and
   port-forwarding work that has to happen around it.

EOF
