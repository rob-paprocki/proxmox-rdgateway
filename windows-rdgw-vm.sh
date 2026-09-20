#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  windows-rdgw-vm.sh
#
#  Builds a Proxmox VE virtual machine sized and configured for a Windows Server
#  2025 RD Gateway host. Styled after the community-scripts/ProxmoxVE VM scripts.
#
#  It can do one of two things, and asks which one you want:
#
#    Unattended  — builds a third CD carrying an answer file, the VirtIO
#                  drivers and the setup scripts, so Windows installs itself
#                  and a startup task configures the RD Gateway role. Nobody
#                  needs to be at the console.
#    Shell only  — the original behaviour: a correctly configured VM with both
#                  ISOs attached and the boot order set. You run Windows Setup
#                  from the console and Setup-RDGateway.ps1 inside the guest.
#
#  Usage, on the Proxmox host as root:
#
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/proxmox-rdgateway/main/windows-rdgw-vm.sh)"
#
#      bash windows-rdgw-vm.sh               # from a checkout
#      DRY_RUN=1 bash windows-rdgw-vm.sh     # print every command, run nothing
#                                            # and echo the generated answer file
#
#  Environment overrides:
#
#      REPO_REF           branch or tag to fetch the PowerShell files from
#      REPO_RAW           a different raw URL prefix entirely, e.g. a fork
#      BOOT_KEY_SECONDS   how long to watch for the DVD's "press any key to
#                         boot" prompt; it stops as soon as the DVD starts
#                         streaming (default 180)
#      BOOT_KEY           the key to send for that prompt (default ret)
#      BOOT_KEY_STREAM_MB how far the DVD counter must climb above where it
#                         settled before Setup counts as streaming (default 64)
#      BOOT_KEY_MAX       hard cap on keypresses (default 10)
#
#  What it touches on the network:
#
#    - the VirtIO driver ISO, only if you have none and ask it to download one
#    - Setup-RDGateway.ps1, Configure-Guest.ps1, Invoke-GatewaySetup.ps1 and
#      Invoke-CustomScripts.ps1, only on the unattended path and only when they
#      are not already sitting next to this script. Local copies always win, so
#      from a checkout nothing is fetched. Those four are copied to the unattend
#      ISO and run inside the guest — they are never executed on the Proxmox
#      host. Every URL is printed before it is fetched, and REPO_REF pins the
#      branch or tag.
#
#  Scripts of your own, if you supply any, are read from a directory you name
#  and copied to that same ISO. They are never run here either.
#
#  Nothing else leaves the machine. Read every line before you run it.
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

# Where this script is running from. When it is piped straight into bash — the
# one-liner in the usage block above — there is no BASH_SOURCE to work from, so
# fall back to the working directory.
_src="${BASH_SOURCE[0]:-}"
if [[ -n "$_src" && -f "$_src" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$_src")" && pwd)"
else
  SCRIPT_DIR="$PWD"
fi
unset _src

# The unattend ISO carries five PowerShell files. Running from a checkout they
# are already next to this script; running from the one-liner they have to be
# fetched. Pin a different ref or point somewhere else entirely with:
#   REPO_REF=some-branch bash -c "$(curl -fsSL .../windows-rdgw-vm.sh)"
REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/rob-paprocki/proxmox-rdgateway/${REPO_REF}}"
SUPPORT_FILES=(Setup-RDGateway.ps1 Configure-Guest.ps1 Invoke-GatewaySetup.ps1 Invoke-CustomScripts.ps1 Get-RDGWStatus.ps1)
SUPPORT_DIR=""

# Answering the Windows DVD's "press any key to boot" prompt. See press_a_key.
# BOOT_KEY_SECONDS is how long to keep watching for the prompt, not how long to
# press: keys go out only while the DVD is open and quiet. The blind budget is
# far shorter because a key nobody can account for is the dangerous kind.
BOOT_KEY_SECONDS="${BOOT_KEY_SECONDS:-180}"
BOOT_KEY_BLIND_SECONDS="${BOOT_KEY_BLIND_SECONDS:-30}"
BOOT_KEY="${BOOT_KEY:-ret}"
# How far the DVD counter must climb ABOVE where it first settled before we
# believe Setup is really streaming. Measured on the operator's host: a keyless
# boot reads ~3 MiB and stops, and the UEFI Boot Manager's own device
# enumeration reaches ~26 MiB all by itself - so any absolute total near that is
# a false positive waiting to happen, and an earlier version reported success
# while the VM sat on a menu. boot.wim is hundreds of MiB, so growth is the
# honest signal and 64 clears the firmware's noise by a wide margin.
BOOT_KEY_STREAM_MB="${BOOT_KEY_STREAM_MB:-64}"
# Hard cap on keypresses. The prompt lasts about five seconds and each poll
# costs a second or two, so a handful is all that can possibly land; beyond
# that we are pressing into a menu, and a bounded number of keys cannot walk
# through one.
BOOT_KEY_MAX="${BOOT_KEY_MAX:-10}"

# Scripts of your own, in the four categories the schneegans.de generator uses.
# CUSTOM_STAGE is a mktemp tree laid out as <category>/<filename>, created only
# if you actually add something. The exit trap removes it.
CUSTOM_CATEGORIES=(System DefaultUser FirstLogon UserOnce)
CUSTOM_STAGE=""
CUSTOM_CATEGORY=""
CUSTOM_EXT=""

# Answered by pick_resource_scope. Initialised here so the most restrictive
# setting is the one a future reordering would fall back to, never the widest.
RESOURCE_SCOPE="ThisServerOnly"
TARGET_MACHINES=""

# Set while an unattend ISO is being built, so the exit trap can clean up a
# loop mount, a staging directory or a download directory if something fails
# midway.
UNATTEND_MOUNT=""
UNATTEND_STAGE=""
UNATTEND_SUPPORT=""

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

# Leave no loop mount or staging directory behind, however we exit.
cleanup_handler() {
  if [[ -n "$UNATTEND_MOUNT" ]] && mountpoint -q "$UNATTEND_MOUNT" 2>/dev/null; then
    umount "$UNATTEND_MOUNT" 2>/dev/null || true
    rmdir "$UNATTEND_MOUNT" 2>/dev/null || true
  fi
  [[ -n "$UNATTEND_STAGE" ]] && rm -rf "$UNATTEND_STAGE"
  [[ -n "$UNATTEND_SUPPORT" ]] && rm -rf "$UNATTEND_SUPPORT"
  [[ -n "$CUSTOM_STAGE" ]] && rm -rf "$CUSTOM_STAGE"
  return 0
}
trap cleanup_handler EXIT

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

# Everything the wizard asks for comes back from whiptail with no character
# restriction, and both generated files have their own quoting rules. Tr0ub4dor&3
# is a perfectly ordinary Windows password and a bare & is not well-formed XML:
# without these, Setup rejects the answer file twenty minutes into a build the
# script already called ready.
xml_escape() {
  local s="$1"
  # Do not drop the backslashes. bash 5.2 turned on patsub_replacement, which
  # makes an unquoted & in the replacement mean "the text that matched", so
  # ${s//</&lt;} yields <lt; on a Proxmox VE 8 host and the escaping quietly
  # achieves nothing. Escaping the & is correct on 5.1 too, where quote removal
  # simply drops the backslash.
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  printf '%s' "$s"
}

# An XML comment additionally cannot contain a double hyphen.
xml_comment() {
  local s
  s="$(xml_escape "$1")"
  printf '%s' "${s//--/- -}"
}

# PowerShell wants a literal ' inside a single-quoted string doubled. Without
# this an account named O'Brien produces a data file that throws before any of
# Invoke-GatewaySetup.ps1's own diagnostics can run.
psd1_quote() {
  local s="${1//\'/\'\'}"
  printf "'%s'" "$s"
}

run() {
  printf "   ${DIM}\$ %s${CL}\n" "$(shell_quote "$@")"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

# Write a file, showing what goes into it. Honours DRY_RUN, which prints the
# whole body rather than writing it — the same contract vps-relay-setup.sh uses.
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
# Unattended install
#
# Everything here builds a small second ISO holding four things:
#
#   autounattend.xml       Windows Setup finds this on its own. It scans the
#                          root of every removable drive looking for exactly
#                          that filename, so no boot option changes.
#   $WinPEDriver$\...      The VirtIO storage and network drivers. Windows
#                          Server scans every drive letter from C upward for a
#                          directory with this name during the windowsPE pass
#                          and stages every INF underneath it. That is what
#                          lets Setup see a VirtIO SCSI disk with nobody there
#                          to click "Load driver".
#   rdgw\*.ps1             Copied to C:\Windows\Setup\Scripts during the
#                          specialize pass, then run by a startup task.
#   rdgw\rdgw-config.psd1  Every answer given below, as plain data.
#
# The answer file is generated per build and is not checked into the repo.
# sample-autounattend.xml shows what a typical run produces.
# ------------------------------------------------------------------------------

# The four stock Server 2025 images, each with the GVLK that matches it. The
# key here selects the edition; it does not activate anything. Evaluation media
# carries its own licensing and must not be given a key at all — the two are
# mutually exclusive and mixing them fails the install.
pick_edition() {
  local choice
  choice="$(whiptail --backtitle "$APP" --title "Windows edition" --radiolist \
    "Which image should Setup install?\n\nThese must match your media exactly. Check yours with:\n  dism /Get-WimInfo /WimFile:<mount>\\\\sources\\\\install.wim" 18 78 5 \
    "std"       "Standard (Desktop Experience)"             ON  \
    "dc"        "Datacenter (Desktop Experience)"           OFF \
    "std-eval"  "Standard Evaluation (Desktop Experience)"  OFF \
    "dc-eval"   "Datacenter Evaluation (Desktop Experience)" OFF \
    "custom"    "Type the image name myself"                OFF 3>&1 1>&2 2>&3)" || exit_script

  case "$choice" in
    std)      IMAGE_NAME="Windows Server 2025 Standard (Desktop Experience)"
              GVLK="TVRH6-WHNXV-R9WG3-9XRFY-MY832" ;;
    dc)       IMAGE_NAME="Windows Server 2025 Datacenter (Desktop Experience)"
              GVLK="D764K-2NDRG-47T6Q-P8T8W-YP6DF" ;;
    std-eval) IMAGE_NAME="Windows Server 2025 Standard Evaluation (Desktop Experience)"
              GVLK="" ;;
    dc-eval)  IMAGE_NAME="Windows Server 2025 Datacenter Evaluation (Desktop Experience)"
              GVLK="" ;;
    custom)   ask "Exact image name from dism /Get-WimInfo" "Windows Server 2025 Standard (Desktop Experience)"
              IMAGE_NAME="$ASK_RESULT"
              ask "Product key (blank for none, e.g. evaluation media)" ""
              GVLK="$ASK_RESULT" ;;
  esac
}

# Ask twice, compare, allow empty. An empty password is a supported answer:
# Configure-Guest.ps1 clears LimitBlankPasswordUse when it sees one, because
# otherwise the account cannot authenticate through the gateway at all.
ask_password() {
  local first second
  while true; do
    first="$(whiptail --backtitle "$APP" --title "Administrator password" \
      --passwordbox "Password for the local account '${ADMIN_USER}'.\n\nLeave it empty for a blank password." 12 70 \
      3>&1 1>&2 2>&3)" || exit_script
    second="$(whiptail --backtitle "$APP" --title "Administrator password" \
      --passwordbox "Type it again." 10 70 3>&1 1>&2 2>&3)" || exit_script
    if [[ "$first" != "$second" ]]; then
      whiptail --backtitle "$APP" --title "Mismatch" --msgbox "Those did not match. Try again." 8 50 || true
      continue
    fi
    if [[ -z "$first" ]]; then
      whiptail --backtitle "$APP" --title "Blank password" \
        --yesno "A blank password means this account cannot log on over the network until LimitBlankPasswordUse is cleared.\n\nThis script will clear it for you, which removes that protection machine-wide.\n\nUse a blank password?" 14 72 --defaultno || continue
    fi
    ADMIN_PASS="$first"
    if [[ -z "$first" ]]; then BLANK_PASSWORD="true"; else BLANK_PASSWORD="false"; fi
    return
  done
}

# Which machines the gateway will proxy connections to. This is the resource
# side of the policy pair: the CAP decides who gets through the gateway at all,
# and this decides what they may reach once they are.
#
# Setup-RDGateway.ps1 turns AnyResource into a RAP with ResourceGroupType 'ALL'
# and the other two into a named resource group holding an explicit list.
pick_resource_scope() {
  local choice
  choice="$(whiptail --backtitle "$APP" --title "What clients may reach" --radiolist \
    "Once someone is through the gateway, what should they be allowed to reach?\n\nEvery target still needs Remote Desktop switched on and your account in its own local Remote Desktop Users group. The gateway decides where you may tunnel, not what you may log into." 17 78 3 \
    "any"    "Any machine the gateway can reach"       ON  \
    "listed" "Only machines I name, plus the gateway"  OFF \
    "self"   "Only the gateway itself"                 OFF 3>&1 1>&2 2>&3)" || exit_script

  TARGET_MACHINES=""
  case "$choice" in
    any)
      RESOURCE_SCOPE="AnyResource"
      whiptail --backtitle "$APP" --title "Any machine" --msgbox \
        "Anything this server can route to is reachable through it.\n\nThat is a jump host: a credential that passes the connection policy reaches your whole LAN rather than a chosen list. Windows Firewall on each target is still in the way, and each target still controls its own Remote Desktop Users group." 14 72 || true
      ;;
    listed)
      RESOURCE_SCOPE="Listed"
      ask "Machines to allow (space separated names or IPs)" ""
      TARGET_MACHINES="$ASK_RESULT"
      ;;
    self)
      RESOURCE_SCOPE="ThisServerOnly"
      ;;
  esac
}

# List the script files directly inside a directory, one per line, sorted.
# Anything we cannot hand to a documented Windows interpreter is left out
# rather than silently copied.
#
# Case-insensitive on purpose. Linux globs are not, so a perfectly reasonable
# INSTALL.PS1 sitting in an import directory used to be skipped here and then
# reported as "no scripts found" - which is worse than either accepting it or
# refusing it. custom_copy_in lower-cases the extension as it copies, so
# everything downstream of the staging tree stays plain lower case.
list_scripts() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 1 -type f \
    \( -iname '*.ps1' -o -iname '*.cmd' -o -iname '*.bat' -o -iname '*.reg' \) \
    2>/dev/null | sort || true
}

count_scripts() {
  local n
  n="$(list_scripts "$1" | grep -c . || true)"
  printf "%s" "${n:-0}"
}

# ------------------------------------------------------------------------------
# Scripts of your own
#
# Four categories, run on the new machine at four different moments. The names
# and the timing come from the schneegans.de unattend generator, because that
# is the vocabulary most people arrive with:
#
#   System       as SYSTEM on the first boot, before anyone logs on
#   DefaultUser  as SYSTEM with C:\Users\Default\NTUSER.DAT mounted, so what
#                you write lands in every profile created afterwards
#   FirstLogon   at the first interactive logon, elevated
#   UserOnce     at each new user's first logon, in that user's own context
#
# You can write one here or import files you already have. Either way it ends
# up in one staging tree laid out as <category>/<filename>, which
# build_unattend_iso copies onto the CD. That tree is a mktemp directory the
# exit trap removes, so the helpers below write to it directly instead of
# through run(): there is nothing here for DRY_RUN to protect you from, and the
# answer file needs the real counts to decide what to register.
# ------------------------------------------------------------------------------

# Sets CUSTOM_STAGE. Deliberately not a function that prints the path: calling
# it as "$(custom_stage_dir)" would run the assignment in a subshell and the
# global would come back empty on the other side.
custom_stage_dir() {
  [[ -n "$CUSTOM_STAGE" ]] || CUSTOM_STAGE="$(mktemp -d)"
}

custom_total() {
  local cat total=0
  if [[ -n "$CUSTOM_STAGE" ]]; then
    for cat in "${CUSTOM_CATEGORIES[@]}"; do
      total=$((total + $(count_scripts "${CUSTOM_STAGE}/${cat}")))
    done
  fi
  printf '%s' "$total"
}

custom_when_text() {
  case "$1" in
    System)      printf 'before anyone logs on, as SYSTEM' ;;
    DefaultUser) printf 'Default User hive mounted, as SYSTEM' ;;
    FirstLogon)  printf 'the first interactive logon, elevated' ;;
    UserOnce)    printf "each new user's first logon, as them" ;;
  esac
}

# Cancel on these two goes back to the menu rather than out of the script, so
# they return non-zero instead of calling exit_script the way the others do.
pick_custom_category() {
  CUSTOM_CATEGORY="$(whiptail --backtitle "$APP" --title "When should it run?" --radiolist \
    "Pick the phase. These are the schneegans.de category names." 15 74 4 \
    "System"      "$(custom_when_text System)"      ON  \
    "DefaultUser" "$(custom_when_text DefaultUser)" OFF \
    "FirstLogon"  "$(custom_when_text FirstLogon)"  OFF \
    "UserOnce"    "$(custom_when_text UserOnce)"    OFF 3>&1 1>&2 2>&3)" || return 1
  [[ -n "$CUSTOM_CATEGORY" ]]
}

pick_custom_kind() {
  CUSTOM_EXT="$(whiptail --backtitle "$APP" --title "What kind of script?" --radiolist \
    "The extension is what picks the interpreter on the other end." 13 74 3 \
    "ps1" "PowerShell   run with powershell.exe" ON  \
    "cmd" "Batch        run with cmd.exe /c"     OFF \
    "reg" "Registry     imported with reg.exe"   OFF 3>&1 1>&2 2>&3)" || return 1
  [[ -n "$CUSTOM_EXT" ]]
}

# Open the editor on something rather than a blank page, so the context is in
# front of you while you write and still there if the file is read later.
custom_seed_file() {
  local path="$1" cat="$2" ext="$3" when
  when="$(custom_when_text "$cat")"

  case "$ext" in
    ps1)
      cat >"$path" <<SEEDEOF
# ${cat} script for this RD Gateway build.
#
# Runs at:     ${when}
# Started as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File
#
# Output and the exit code go to C:\\Windows\\Setup\\Scripts\\rdgw-setup.log.
# A non-zero exit is logged and skipped rather than stopping the build, and
# anything still running after fifteen minutes is killed.

SEEDEOF
      ;;
    cmd)
      cat >"$path" <<SEEDEOF
@echo off
:: ${cat} script for this RD Gateway build.
::
:: Runs at:     ${when}
:: Started as:  cmd.exe /c
::
:: Output and the exit code go to C:\\Windows\\Setup\\Scripts\\rdgw-setup.log.

SEEDEOF
      ;;
    reg)
      cat >"$path" <<SEEDEOF
Windows Registry Editor Version 5.00

; ${cat} script for this RD Gateway build.
;
; Runs at:     ${when}
; Imported by: reg.exe import
SEEDEOF
      if [[ "$cat" == "DefaultUser" ]]; then
        cat >>"$path" <<SEEDEOF
;
; Write HKEY_CURRENT_USER as though you were the logged-on user. It is
; rewritten to point at the mounted Default User hive before it is imported,
; so what you set here is inherited by every profile created afterwards.
SEEDEOF
      fi
      printf '\n' >>"$path"
      ;;
  esac

  # Only .reg files get rewritten for the mounted hive. A .ps1 or .cmd in this
  # category runs as SYSTEM with nobody logged on, so HKCU points at SYSTEM's
  # own profile and a write there reaches no real user. Say where the hive is.
  if [[ "$cat" == "DefaultUser" && "$ext" != "reg" ]]; then
    case "$ext" in
      ps1)
        cat >>"$path" <<'HIVEEOF'
# Nobody is logged on yet, so HKCU: here is SYSTEM's own profile, not the one
# new accounts inherit. The Default User hive is mounted for you:
#
#   $env:RDGW_HIVE_PATH    Registry::HKEY_USERS\rdgwDefault
#
#   New-Item -Path "$env:RDGW_HIVE_PATH\Software\Example" -Force
#   New-ItemProperty -Path "$env:RDGW_HIVE_PATH\Software\Example" `
#       -Name Sample -Value 1 -PropertyType DWord -Force

HIVEEOF
        ;;
      cmd)
        cat >>"$path" <<'HIVEEOF'
:: Nobody is logged on yet, so HKCU here is SYSTEM's own profile. The Default
:: User hive is mounted at %RDGW_HIVE_ROOT% (HKU\rdgwDefault) - write there:
::
::   reg add "%RDGW_HIVE_ROOT%\Software\Example" /v Sample /t REG_DWORD /d 1 /f

HIVEEOF
        ;;
    esac
  fi
}

# Can we actually reach the terminal by name? [[ -r /dev/tty ]] is not enough:
# the node can exist and still refuse to open when there is no controlling
# terminal. Try it for real rather than asking about it.
custom_have_tty() {
  { true </dev/tty >/dev/tty; } 2>/dev/null
}

# $VISUAL and $EDITOR first, then what Proxmox actually ships.
custom_find_editor() {
  local e
  for e in "${VISUAL:-}" "${EDITOR:-}" nano vim vi; do
    [[ -n "$e" ]] || continue
    if command -v "${e%% *}" >/dev/null 2>&1; then
      printf '%s' "$e"
      return 0
    fi
  done
  return 1
}

# No editor on the box. Take the body off the terminal instead. /dev/tty and
# not stdin, because in the one-liner form stdin has already been spent on the
# script itself.
custom_paste_into() {
  local path="$1" line
  printf "\n   Paste the script, then a line containing only ${BL}EOF${CL}\n\n"
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    printf '%s\n' "$line" >>"$path"
  done < <(if custom_have_tty; then cat /dev/tty; else cat; fi)
  printf "\n"
}

# Did anything survive besides the header we seeded and blank lines?
custom_has_content() {
  local path="$1" line trimmed
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" ]] && continue
    case "$trimmed" in
      "#"*|"::"*|";"*|"@echo off"|"Windows Registry Editor"*) continue ;;
      [Rr][Ee][Mm][[:space:]]*) continue ;;
    esac
    return 0
  done <"$path"
  return 1
}

# Turn whatever was typed into something every later stage can actually see.
#
# Three things bite here. A name ending in "/" leaves ${x##*/} empty, so the
# file becomes ".ps1" - a dotfile, which bash globs skip without dotglob, so it
# is staged and then invisible to every count, listing and copy. A name with a
# space survives all the way to the guest and then breaks Start-Process, which
# joins its argument array without quoting. And a name that is only an
# extension leaves nothing to sort on.
custom_safe_name() {
  local raw="$1" ext="$2" fallback="$3" name
  name="${raw##*/}"
  name="${name//[[:space:]]/-}"
  [[ "$name" == *".${ext}" ]] || name="${name}.${ext}"
  case "$name" in
    .*) name="$fallback" ;;
  esac
  [[ -n "${name%.*}" ]] || name="$fallback"
  printf '%s' "$name"
}

# Copy one script into the staging tree, refusing anything a Windows
# interpreter cannot be handed. Returns non-zero and says why if it cannot.
custom_copy_in() {
  local src="$1" cat="$2" dst base ext name
  case "$src" in
    *.ps1|*.cmd|*.bat|*.reg|*.PS1|*.CMD|*.BAT|*.REG) ;;
    *)
      whiptail --backtitle "$APP" --title "Not a script" --msgbox \
        "$(basename -- "$src")\n\nOnly .ps1, .cmd, .bat and .reg can be run on the other end." 10 68 || true
      return 1 ;;
  esac
  # Everything downstream - count_scripts, stage_custom_scripts, custom_review -
  # globs lower case, so INSTALL.PS1 would be accepted here and then be invisible
  # to all three of them. Normalise the extension rather than teaching four
  # globs about case.
  base="$(basename -- "$src")"
  ext="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
  name="${base%.*}.${ext}"

  dst="${CUSTOM_STAGE}/${cat}"
  mkdir -p "$dst" || { msg_error "Could not create ${dst}"; return 1; }
  cp -- "$src" "${dst}/${name}" || { msg_error "Could not copy ${src}"; return 1; }
  return 0
}

custom_write_script() {
  local stage cat ext name path editor next
  local -a ed

  pick_custom_category || return 0
  cat="$CUSTOM_CATEGORY"
  pick_custom_kind || return 0
  ext="$CUSTOM_EXT"

  custom_stage_dir
  stage="$CUSTOM_STAGE"
  mkdir -p "${stage}/${cat}"

  # Numbered in tens so there is room to slot something in between, and taken
  # from the highest prefix already present rather than the count - after a
  # removal the count would hand back a number that is still in use. Zero
  # padded because the runner sorts these as text, where 100 sorts before 20.
  next="$(ls -1 "${stage}/${cat}" 2>/dev/null | sed -n 's/^0*\([0-9]\{1,\}\)-.*/\1/p' | sort -n | tail -1)"
  next=$(( (${next:-0} / 10 + 1) * 10 ))
  next="$(printf '%03d' "$next")"

  ask "File name (scripts run in filename order)" "${next}-script.${ext}"
  name="$(custom_safe_name "$ASK_RESULT" "$ext" "${next}-script.${ext}")"
  path="${stage}/${cat}/${name}"

  if [[ -e "$path" ]]; then
    whiptail --backtitle "$APP" --title "Already there" --yesno \
      "${cat}/${name} already exists.\n\nOverwrite it? Saying no takes you back to the menu." 10 68 --defaultno || return 0
  fi

  custom_seed_file "$path" "$cat" "$ext"

  if editor="$(custom_find_editor)"; then
    read -r -a ed <<<"$editor"
    msg_info "Opening ${BL}${cat}/${name}${CL} in ${BL}${ed[0]}${CL}"
    # whiptail has been drawing on the terminal, so hand it over properly. In
    # the one-liner form stdin is not the terminal, hence asking for it by
    # name - but only when it is actually there to ask for.
    if custom_have_tty; then
      "${ed[@]}" "$path" </dev/tty >/dev/tty 2>&1 || true
    else
      "${ed[@]}" "$path" || true
    fi
    # code, subl, gedit and friends fork and return immediately, so without
    # this the content check below runs against a file nobody has typed into
    # yet and deletes it out from under the open window.
    case "${ed[0]##*/}" in
      code|code-insiders|codium|subl|sublime_text|gedit|atom|kate|gnome-text-editor)
        msg_warn "${ed[0]##*/} returns straight away - it does not wait for you to close it"
        if custom_have_tty; then
          printf "   Press Enter once you have saved and closed it. "
          read -r _ </dev/tty || true
          printf "\n"
        fi ;;
    esac
  else
    msg_warn "No editor found - tried \$VISUAL, \$EDITOR, nano, vim, vi"
    custom_paste_into "$path"
  fi

  if custom_has_content "$path"; then
    msg_ok "Added ${BL}${cat}/${name}${CL}"
  else
    rm -f "$path"
    whiptail --backtitle "$APP" --title "Nothing saved" --msgbox \
      "${name} had nothing in it beyond the header, so it was discarded." 9 68 || true
  fi
}

custom_import_path() {
  local src cat f added=0 loose base

  ask "File or directory to import" "/root/rdgw-scripts"
  src="${ASK_RESULT%/}"
  [[ -n "$src" ]] || return 0

  if [[ -f "$src" ]]; then
    pick_custom_category || return 0
    custom_stage_dir
    base="$(basename -- "$src")"
    custom_copy_in "$src" "$CUSTOM_CATEGORY" || return 0
    msg_ok "Added ${BL}${CUSTOM_CATEGORY}/${base}${CL}"
    return 0
  fi

  if [[ ! -d "$src" ]]; then
    whiptail --backtitle "$APP" --title "Not found" --msgbox \
      "${src} is not a file or a directory." 8 66 || true
    return 0
  fi

  custom_stage_dir
  for cat in "${CUSTOM_CATEGORIES[@]}"; do
    [[ -d "${src}/${cat}" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      custom_copy_in "$f" "$cat" && added=$((added + 1))
    done < <(list_scripts "${src}/${cat}")
  done

  # Scripts sitting loose at the top level are offered whether or not a
  # category subdirectory also matched. Gating this on "nothing else matched"
  # meant a mixed directory imported the subdirectories and dropped the loose
  # files without saying so.
  loose="$(count_scripts "$src")"
  if [[ "$loose" -gt 0 ]]; then
    if whiptail --backtitle "$APP" --title "Loose scripts" --yesno \
        "${src} also holds ${loose} script(s) directly, outside the ${CUSTOM_CATEGORIES[*]} subdirectories.\n\nTreat those as System scripts?" 13 72; then
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        custom_copy_in "$f" System && added=$((added + 1))
      done < <(list_scripts "$src")
    fi
  fi

  if [[ "$added" -eq 0 ]]; then
    whiptail --backtitle "$APP" --title "Nothing to import" --msgbox \
      "No .ps1, .cmd, .bat or .reg files under ${src}." 9 70 || true
  else
    msg_ok "Imported ${added} script(s) from ${BL}${src}${CL}"
  fi
}

custom_review() {
  local cat f rel choice
  local -a rows=()

  if [[ -n "$CUSTOM_STAGE" ]]; then
    for cat in "${CUSTOM_CATEGORIES[@]}"; do
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        rel="${cat}/$(basename -- "$f")"
        rows+=("$rel" "$(custom_when_text "$cat")" "OFF")
      done < <(list_scripts "${CUSTOM_STAGE}/${cat}")
    done
  fi

  if [[ "${#rows[@]}" -eq 0 ]]; then
    whiptail --backtitle "$APP" --title "Custom scripts" --msgbox \
      "Nothing added yet." 8 50 || true
    return 0
  fi

  choice="$(whiptail --backtitle "$APP" --title "What will be included" --radiolist \
    "All of these go on the CD, in filename order within each category.\n\nPick one to remove it, or leave it on 'keep everything'." 20 78 9 \
    "keep everything" "" ON "${rows[@]}" 3>&1 1>&2 2>&3)" || return 0

  if [[ -n "$choice" && "$choice" != "keep everything" ]]; then
    rm -f "${CUSTOM_STAGE}/${choice}"
    msg_ok "Removed ${BL}${choice}${CL}"
  fi
}

pick_custom_scripts() {
  local choice total

  whiptail --backtitle "$APP" --title "Custom scripts" --yesno \
    "Run scripts of your own on the new machine?\n\nWrite them here, or import files already sitting on this host. Each one is tagged with when it should run:\n\n  System        before anyone logs on, as SYSTEM\n  DefaultUser   with the Default User hive mounted\n  FirstLogon    the first interactive logon, elevated\n  UserOnce      each new user's first logon\n\nPowerShell, batch and .reg files are all supported." 21 76 --defaultno || return 0

  while true; do
    total="$(custom_total)"
    choice="$(whiptail --backtitle "$APP" --title "Custom scripts (${total} so far)" --menu \
      "" 14 76 4 \
      "write"  "Write a new script here" \
      "import" "Import a file or a directory from this host" \
      "review" "Review what will be included, or remove one" \
      "done"   "Finished" 3>&1 1>&2 2>&3)" || return 0

    case "$choice" in
      write)  custom_write_script ;;
      import) custom_import_path ;;
      review) custom_review ;;
      *)      return 0 ;;
    esac
  done
}

# Copy what you added onto the CD. It goes under rdgw/ so the existing
# specialize xcopy carries it across with everything else; no extra answer-file
# command is needed to place it.
stage_custom_scripts() {
  local stage="$1" cat src dst f staged=0

  [[ -n "$CUSTOM_STAGE" ]] || return 0

  msg_info "Staging custom scripts"
  for cat in "${CUSTOM_CATEGORIES[@]}"; do
    src="${CUSTOM_STAGE}/${cat}"
    [[ -d "$src" ]] || continue

    dst="${stage}/rdgw/custom/${cat}"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      run mkdir -p "$dst"
      run cp "$f" "${dst}/"
      staged=$((staged + 1))
    done < <(list_scripts "$src")
  done
  msg_ok "Custom scripts staged (${staged})"
}

unattend_settings() {
  ask "Local administrator account name" "rdgadmin"
  ADMIN_USER="$ASK_RESULT"
  ask_password

  ask "External FQDN clients will connect to" "rdg.example.com"
  EXTERNAL_FQDN="$ASK_RESULT"

  # Windows time zone ID, not an IANA name. "tzutil /l" inside Windows lists
  # them all; the mapping from Europe/London to "GMT Standard Time" is not
  # something worth embedding a table for.
  ask "Windows time zone ID" "Eastern Standard Time"
  WIN_TIMEZONE="$ASK_RESULT"

  pick_resource_scope

  pick_edition

  ask "Account lockout threshold (0 disables lockout)" "10"
  LOCKOUT_THRESHOLD="$ASK_RESULT"
  if [[ "$LOCKOUT_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$LOCKOUT_THRESHOLD" -gt 0 ]]; then
    ask "Lockout window and duration in minutes" "15"
    LOCKOUT_WINDOW="$ASK_RESULT"
  else
    LOCKOUT_THRESHOLD="0"
    LOCKOUT_WINDOW="15"
  fi

  # Each of these defaults to leaving Windows alone. They are offered because
  # the operator asked for them, and the consequence is stated in the prompt.
  DISABLE_UAC="false"
  whiptail --backtitle "$APP" --title "User Account Control" \
    --yesno "Disable UAC?\n\nElevation prompts stop. Anything running as an administrator runs fully elevated with no consent step.\n\nDefault is to leave UAC enabled." 13 72 --defaultno && DISABLE_UAC="true"

  DISABLE_DEFENDER="false"
  whiptail --backtitle "$APP" --title "Microsoft Defender" \
    --yesno "Disable Microsoft Defender?\n\nThis box terminates an authentication endpoint from the public internet.\n\nDefault is to leave Defender enabled." 13 72 --defaultno && DISABLE_DEFENDER="true"

  DISABLE_CORE_ISOLATION="false"
  whiptail --backtitle "$APP" --title "Core Isolation" \
    --yesno "Disable Core Isolation (VBS / HVCI)?\n\nYou are already paying for the TPM and Secure Boot this VM was given.\n\nDefault is to leave it at the Windows setting." 13 72 --defaultno && DISABLE_CORE_ISOLATION="true"

  # The odd one out: defaults to ON, because sending Ctrl+Alt+Del to a Proxmox
  # console is a menu trip rather than a keystroke.
  DISABLE_CAD="true"
  whiptail --backtitle "$APP" --title "Ctrl+Alt+Del" \
    --yesno "Require Ctrl+Alt+Del at the logon screen?\n\nSaying no removes the requirement, which is easier from a Proxmox console.\n\nDefault is no requirement." 13 72 --defaultno && DISABLE_CAD="false"

  APPLY_TWEAKS="true"
  whiptail --backtitle "$APP" --title "Server housekeeping" \
    --yesno "Apply the housekeeping settings?\n\n8.3 names off, fast startup off, long paths on, WPBT off, no Windows Update auto-reboot, system sounds off, NumLock on, and Explorer/taskbar/theme defaults suited to RDP.\n\nNone of these are security relevant." 15 72 || APPLY_TWEAKS="false"

  pick_custom_scripts
}

# Find the three PowerShell files the unattend ISO needs, or fetch them.
#
# Local copies always win, so a checkout — or a directory where you have edited
# them — behaves exactly as before and nothing is downloaded. Only the one-liner
# path reaches the network, and it prints every URL before fetching it.
resolve_support_files() {
  local f fetched=0 local_count=0

  # Resolved one at a time. The old all-or-nothing form meant a single absent
  # file sent every other one to a download too, so three hand-edited local
  # copies were quietly excluded from the build in favour of upstream - the
  # opposite of what "local copies always win" is supposed to mean.
  SUPPORT_DIR="$(mktemp -d)"
  UNATTEND_SUPPORT="$SUPPORT_DIR"

  for f in "${SUPPORT_FILES[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
      cp -- "${SCRIPT_DIR}/${f}" "${SUPPORT_DIR}/${f}" || {
        msg_error "Could not read ${SCRIPT_DIR}/${f}"
        exit 1
      }
      local_count=$((local_count + 1))
      continue
    fi

    if [[ "$fetched" -eq 0 ]]; then
      msg_warn "Not every PowerShell file is next to this script — fetching what is missing"
      printf "     %sThey are copied to the unattend ISO and run inside the guest, not here.%s
" "$DIM" "$CL"
    fi
    fetched=$((fetched + 1))

    printf "   ${DIM}\$ curl -fsSL -o %s %s${CL}
" "${SUPPORT_DIR}/${f}" "${REPO_RAW}/${f}"
    [[ "$DRY_RUN" == "1" ]] && continue
    if ! curl -fsSL -o "${SUPPORT_DIR}/${f}" "${REPO_RAW}/${f}"; then
      msg_error "Could not download ${f}"
      printf "     Tried: %s
" "${REPO_RAW}/${f}"
      printf "     Check REPO_REF (currently '%s'), or clone the repo and run from there.
" "$REPO_REF"
      exit 1
    fi
    if [[ ! -s "${SUPPORT_DIR}/${f}" ]]; then
      msg_error "Downloaded ${f} is empty."
      exit 1
    fi
  done

  if [[ "$fetched" -eq 0 ]]; then
    msg_ok "All ${local_count} PowerShell files found locally (${BL}${SCRIPT_DIR}${CL})"
  else
    msg_ok "${local_count} local, ${fetched} fetched from ${BL}${REPO_REF}${CL}"
  fi
}

require_iso_tool() {
  if command -v xorriso >/dev/null 2>&1; then
    ISO_TOOL="xorriso"
  elif command -v genisoimage >/dev/null 2>&1; then
    ISO_TOOL="genisoimage"
  elif command -v mkisofs >/dev/null 2>&1; then
    ISO_TOOL="mkisofs"
  else
    msg_error "No ISO build tool found. Install one:"
    printf "     ${DIM}\$ apt-get install -y xorriso${CL}\n"
    exit 1
  fi
  msg_ok "ISO builder: ${BL}${ISO_TOOL}${CL}"
}

# Copy the three drivers Setup needs out of the VirtIO ISO into $WinPEDriver$.
# Pinned to the 2k25 directories on purpose — the w10/w11 trees exist too and
# carry the same driver generation, but this is a Server build.
stage_drivers() {
  local stage="$1" src mnt d
  src="$(pvesm path "$VIRTIO_ISO" 2>/dev/null)"
  if [[ -z "$src" ]]; then
    msg_error "Could not resolve a path for ${VIRTIO_ISO}."
    exit 1
  fi
  mnt="$(mktemp -d)"
  UNATTEND_MOUNT="$mnt"

  msg_info "Staging VirtIO drivers from ${src}"
  run mount -o loop,ro "$src" "$mnt"

  for d in vioscsi viostor NetKVM; do
    if [[ "$DRY_RUN" != "1" && ! -d "${mnt}/${d}/2k25/amd64" ]]; then
      run umount "$mnt"; rmdir "$mnt"; UNATTEND_MOUNT=""
      msg_error "Missing ${d}/2k25/amd64 on the VirtIO ISO."
      printf "     That ISO is too old for Server 2025. Get a current one from:\n     %s\n" "$VIRTIO_URL"
      exit 1
    fi
    run mkdir -p "${stage}/\$WinPEDriver\$/${d}"
    run cp -r "${mnt}/${d}/2k25/amd64/." "${stage}/\$WinPEDriver\$/${d}/"
  done

  run umount "$mnt"
  rmdir "$mnt" 2>/dev/null || true
  UNATTEND_MOUNT=""
  msg_ok "Drivers staged (vioscsi, viostor, NetKVM — 2k25/amd64)"
}

generate_answer_file() {
  local stage="$1" product_key_block="" firstlogon_block="" shell_block=""
  local x_user x_pass x_hn x_tz x_img x_key c_hn

  x_user="$(xml_escape "$ADMIN_USER")"
  x_pass="$(xml_escape "$ADMIN_PASS")"
  x_hn="$(xml_escape "$HN")"
  x_tz="$(xml_escape "$WIN_TIMEZONE")"
  x_img="$(xml_escape "$IMAGE_NAME")"
  x_key="$(xml_escape "$GVLK")"
  c_hn="$(xml_comment "$HN")"

  if [[ -n "$GVLK" ]]; then
    product_key_block="
            <ProductKey>
                <Key>${x_key}</Key>
                <WillShowUI>Never</WillShowUI>
            </ProductKey>"
  fi

  # Order 2 passes -ScriptRoot explicitly, and that is not decoration: the
  # script defaults it to $PSScriptRoot, which came back EMPTY on a real
  # Server 2025 build, so Join-Path threw and the script died before
  # registering the task or writing one word to the log.
  #
  # That explanation used to live in an XML comment next to the <Path> element
  # it describes. It cost a whole build. Windows accepts comments at the
  # document root, inside <settings> and inside <component>, but a comment
  # inside <RunSynchronousCommand> makes the specialize pass fail outright:
  # "Windows could not parse or process unattend answer file", error
  # 0x80220005, and Setup stops at "The computer restarted unexpectedly".
  # The file is still well-formed XML, so xmllint is happy and only a real
  # install finds it. Keep prose about the answer file in this script, where
  # it costs nothing, and emit no comments below <component>.
  #
  # The cosmetic shell settings get applied twice, and the second time is this
  # one. Configure-Guest.ps1 writes them into the Default User hive so later
  # profiles inherit them, but the AutoLogon account's profile is copied out of
  # that hive at about the moment the hive is being written, and on a real build
  # the profile won: the operator asked for a left taskbar and dark theme and
  # got neither. So the same settings are re-applied per user at the first
  # interactive logon, against the real HKCU, and Explorer is restarted.
  # cschneegans/unattend-generator does exactly this in its UserOnce phase.
  #
  # Registered unconditionally: Configure-Guest.ps1 reads ApplyTweaks from the
  # config itself and writes a "skipped" line if it was not asked for, which is
  # one more piece of evidence in the log than silence would be.
  shell_block="
                <RunSynchronousCommand wcm:action=\"add\">
                    <Order>3</Order>
                    <Description>Re-apply the shell settings for the first account</Description>
                    <Path>reg.exe add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce /v RDGWShell /t REG_SZ /d \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Setup\\Scripts\\Configure-Guest.ps1 -ShellForCurrentUser -ConfigPath C:\\Windows\\Setup\\Scripts\\rdgw-config.psd1\" /f</Path>
                </RunSynchronousCommand>"

  # FirstLogon scripts have to beat the single automatic logon below, so they
  # are registered here in specialize rather than by the startup task, which
  # races it. RunOnce under HKLM fires at the first interactive logon and the
  # value deletes itself once it has run.
  if [[ -n "$CUSTOM_STAGE" && "$(count_scripts "${CUSTOM_STAGE}/FirstLogon")" -gt 0 ]]; then
    firstlogon_block="
                <RunSynchronousCommand wcm:action=\"add\">
                    <Order>4</Order>
                    <Description>Register the first-logon custom scripts</Description>
                    <Path>reg.exe add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce /v RDGWFirstLogon /t REG_SZ /d \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Setup\\Scripts\\Invoke-CustomScripts.ps1 -Category FirstLogon -ScriptRoot C:\\Windows\\Setup\\Scripts\" /f</Path>
                </RunSynchronousCommand>"
  fi

  write_file "${stage}/autounattend.xml" 644 <<XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<!--
    Generated by windows-rdgw-vm.sh for VM ${VMID} (${c_hn}).

    Read this before you boot it. It wipes disk 0 without asking.

    The local account password below is in clear text. Base64 in an answer file
    is obfuscation, not encryption, so this file does not pretend otherwise.
    The ISO is written mode 600, and Invoke-GatewaySetup.ps1 deletes the copy
    Windows caches in C:\Windows\Panther once setup finishes. Delete the ISO
    when the build is done.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>0409:00000409</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>

        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">

            <!--
                Disk 0 is the only disk this VM has; the CD drives are not
                counted here. EFI, MSR, then everything else as NTFS. There is
                deliberately no recovery partition: Windows Setup creates the
                WinRE partition itself on an NTFS boot volume by shrinking the
                OS volume on first boot.
            -->
            <DiskConfiguration>
                <WillShowUI>OnError</WillShowUI>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>EFI</Type>
                            <Size>300</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>MSR</Type>
                            <Size>16</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Type>Primary</Type>
                            <Extend>true</Extend>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>FAT32</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>3</PartitionID>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>

            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>${x_img}</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                    <WillShowUI>OnError</WillShowUI>
                </OSImage>
            </ImageInstall>

            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>${x_user}</FullName>${product_key_block}
            </UserData>
        </component>
    </settings>

    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>${x_hn}</ComputerName>
            <TimeZone>${x_tz}</TimeZone>
        </component>

        <!--
            Copy the scripts off this CD and register the startup task that
            finishes the build. The drive letter is not predictable, so the
            first command walks the alphabet looking for our marker file.
        -->
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Copy RD Gateway setup scripts from the unattend CD</Description>
                    <Path>cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %d:\rdgw\rdgw-config.psd1 xcopy /E /I /Y %d:\rdgw C:\Windows\Setup\Scripts</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Description>Register the first-boot task</Description>
                    <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Invoke-GatewaySetup.ps1 -Register -ScriptRoot C:\Windows\Setup\Scripts</Path>
                </RunSynchronousCommand>${shell_block}${firstlogon_block}
            </RunSynchronous>
        </component>
    </settings>

    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>0409:00000409</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>

        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>${x_user}</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>${x_pass}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>

            <!--
                One automatic logon so the machine lands on a desktop you can
                look at. Windows clears the stored credential once the count is
                spent. The gateway build itself does not depend on this: it runs
                from a startup task as SYSTEM whether anyone logs on or not.
            -->
            <AutoLogon>
                <Username>${x_user}</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                    <Value>${x_pass}</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>

            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
        </component>
    </settings>
</unattend>
XMLEOF
}

generate_config_psd1() {
  local stage="$1" targets="" m
  for m in $TARGET_MACHINES; do
    targets+="$(psd1_quote "$m"), "
  done
  targets="${targets%, }"

  write_file "${stage}/rdgw/rdgw-config.psd1" 644 <<PSDEOF
#
# Every answer given to windows-rdgw-vm.sh, as plain data. Read by
# Configure-Guest.ps1 and Invoke-GatewaySetup.ps1 on the first boot.
#
# Generated for VM ${VMID} (${HN}). No secrets live here — the account password
# is in autounattend.xml.
#
@{
    ComputerName         = $(psd1_quote "$HN")
    AccountName          = $(psd1_quote "$ADMIN_USER")
    ExternalFqdn         = $(psd1_quote "$EXTERNAL_FQDN")
    TargetMachines       = @(${targets})
    ResourceScope        = '${RESOURCE_SCOPE}'
    CertificateSource    = 'SelfSigned'

    LockoutThreshold     = ${LOCKOUT_THRESHOLD}
    LockoutWindow        = ${LOCKOUT_WINDOW}
    BlankPassword        = \$${BLANK_PASSWORD}

    DisableUac           = \$${DISABLE_UAC}
    DisableDefender      = \$${DISABLE_DEFENDER}
    DisableCoreIsolation = \$${DISABLE_CORE_ISOLATION}
    DisableCad           = \$${DISABLE_CAD}

    ApplyTweaks          = \$${APPLY_TWEAKS}
}
PSDEOF
}

build_unattend_iso() {
  local stage iso_dir out
  stage="$(mktemp -d)"
  UNATTEND_STAGE="$stage"

  stage_drivers "$stage"

  msg_info "Generating the answer file"
  generate_answer_file "$stage"
  generate_config_psd1 "$stage"

  # Belt and braces over xml_escape. Windows Setup rejecting the answer file
  # looks identical to Setup ignoring it, twenty minutes in, at a screen with no
  # useful error. Catch it here instead.
  # Check the answer file, and say which tool did the checking.
  #
  # This used to be "command -v xmllint, else skip". On a real Proxmox VE 9
  # host that means skip - xmllint is not installed - so the only validation
  # this repo had never ran once where it mattered, silently. Proxmox does
  # ship perl with XML::LibXML, which pve-manager itself depends on, so prefer
  # that and keep python3 as a second string. If neither exists, say so out
  # loud rather than printing a reassuring line.
  #
  # Two questions, one pass:
  #   1. Is it well-formed? A stray & from a password is enough to break it.
  #   2. Does it carry an XML comment below <component>? That is legal XML
  #      which Windows rejects outright, failing the whole pass with
  #      0x80220005 twenty minutes into an install. See CLAUDE.md.
  local xml_file="${stage}/autounattend.xml" deep="" tool=""
  if [[ "$DRY_RUN" != "1" ]]; then
    if command -v xmllint >/dev/null 2>&1; then
      tool="xmllint"
      xmllint --noout "$xml_file" 2>/dev/null || deep="malformed"
      [[ -z "$deep" ]] && deep="$(xmllint --xpath \
        'count(//*[local-name()="component"]/*//comment())' "$xml_file" 2>/dev/null || echo 0)"
    elif perl -MXML::LibXML -e 1 >/dev/null 2>&1; then
      tool="perl XML::LibXML"
      deep="$(perl -MXML::LibXML -e '
        my $d = eval { XML::LibXML->load_xml(location => $ARGV[0]) };
        unless ($d) { print q{malformed}; exit 0 }
        print scalar @{[ $d->findnodes(q{//*[local-name()="component"]/*//comment()}) ]};
      ' "$xml_file" 2>/dev/null)" || deep="malformed"
    elif command -v python3 >/dev/null 2>&1; then
      tool="python3"
      deep="$(python3 - "$xml_file" <<'PYEOF'
import sys, xml.dom.minidom
try:
    d = xml.dom.minidom.parse(sys.argv[1])
except Exception:
    print("malformed"); raise SystemExit(0)
def below(n):
    t = 0
    for k in n.childNodes:
        if k.nodeType == k.COMMENT_NODE: t += 1
        elif k.nodeType == k.ELEMENT_NODE: t += below(k)
    return t
total = 0
for c in d.getElementsByTagName("*"):
    if c.localName == "component":
        for kid in c.childNodes:
            if kid.nodeType == kid.ELEMENT_NODE:
                total += below(kid)
print(total)
PYEOF
)" || deep="malformed"
    fi
  fi

  if [[ "$deep" == "malformed" ]]; then
    msg_error "The generated autounattend.xml is not well-formed XML."
    msg_error "Re-run with DRY_RUN=1 to read it. Suspect whatever you typed into"
    msg_error "the account name, password, hostname or time zone."
    exit 1
  elif [[ -n "$deep" && "$deep" != "0" ]]; then
    msg_error "The answer file carries ${deep} XML comment(s) nested below <component>."
    msg_error "Legal XML, and Windows fails the whole pass for it. Move the prose"
    msg_error "into windows-rdgw-vm.sh instead. See CLAUDE.md, 'Ruled out'."
    exit 1
  elif [[ -n "$tool" ]]; then
    msg_ok "Answer file written, checked with ${tool}"
  elif [[ "$DRY_RUN" == "1" ]]; then
    msg_ok "Answer file written"
  else
    msg_warn "Answer file written but NOT checked - no xmllint, perl XML::LibXML or python3"
  fi

  msg_info "Staging the first-boot scripts"
  local f
  for f in "${SUPPORT_FILES[@]}"; do
    if [[ "$DRY_RUN" != "1" && ! -f "${SUPPORT_DIR}/${f}" ]]; then
      msg_error "Missing ${SUPPORT_DIR}/${f}."
      exit 1
    fi
    run mkdir -p "${stage}/rdgw"
    run cp "${SUPPORT_DIR}/${f}" "${stage}/rdgw/${f}"
  done
  msg_ok "Scripts staged"

  stage_custom_scripts "$stage"

  # The last cheap place to see what the guest will get. A file that never made
  # it onto the CD is indistinguishable, from inside Windows, from one the
  # first-boot task decided not to run.
  # The last cheap place to see what the guest will get. A file that never made
  # it onto the CD is indistinguishable, from inside Windows, from one the
  # first-boot task decided not to run.
  msg_info "Going on the CD"
  local f b
  if [[ -d "${stage}/rdgw" ]]; then
    while IFS= read -r f; do
      printf "     %s
" "${f#"${stage}/"}"
      b="$(basename -- "$f")"
      # Joliet allows 64 characters, or 103 with -joliet-long. Past that Windows
      # sees a truncated name and the runner never matches it.
      if (( ${#b} > 100 )); then
        msg_warn "Name is too long for the CD and will be truncated: ${b}"
      fi
    done < <(find "${stage}/rdgw" -type f 2>/dev/null | sort || true)
    if [[ -d "${stage}/\$WinPEDriver\$" ]]; then
      printf "     %s\$WinPEDriver\$: %s file(s)%s
" "$DIM"         "$(find "${stage}/\$WinPEDriver\$" -type f 2>/dev/null | wc -l)" "$CL"
    fi
  else
    printf "     %s(nothing on disk — DRY_RUN printed the copies instead of making them)%s
" "$DIM" "$CL"
  fi

  iso_dir="$(iso_dir_for_storage "$UNATTEND_STORAGE")"
  if [[ -z "$iso_dir" ]]; then
    msg_error "Could not resolve the ISO directory for storage '${UNATTEND_STORAGE}'."
    exit 1
  fi
  out="${iso_dir}/unattend-${VMID}.iso"

  msg_info "Building ${out}"
  run mkdir -p "$iso_dir"
  case "$ISO_TOOL" in
    xorriso) run xorriso -as mkisofs -quiet -J -joliet-long -r -V UNATTEND -o "$out" "$stage" ;;
    *)       run "$ISO_TOOL" -quiet -J -joliet-long -r -V UNATTEND -o "$out" "$stage" ;;
  esac
  # The answer file inside carries the account password in clear text.
  run chmod 600 "$out"

  rm -rf "$stage"
  UNATTEND_STAGE=""
  UNATTEND_ISO="${UNATTEND_STORAGE}:iso/unattend-${VMID}.iso"
  UNATTEND_ISO_PATH="$out"
  msg_ok "Unattend ISO ready (${BL}${UNATTEND_ISO}${CL})"
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

# The Windows DVD's EFI loader prints "Press any key to boot from CD or DVD"
# and gives up after about five seconds.
#
# That prompt has to stay. Setup reboots two or three times before it is
# finished, the DVD is still first in the boot order each time, and the prompt
# timing out is exactly what lets those reboots fall through to the disk
# instead of starting the install over. Rebuilding the media around
# efisys_noprompt.bin would fix the first boot and buy an endless reinstall
# loop in exchange.
#
# So the prompt stays and the host answers it, once. qm sendkey pushes a
# keystroke into the running VM, and it does work - confirmed on the operator's
# host by sending one to a VM parked on "Press any key to enter the Boot
# Manager Menu" and watching the menu open. Knowing *when* to send it is the
# whole difficulty, and that is what the byte counter below is for.
# How many bytes QEMU has read from a drive. Best effort: it prints nothing
# when the counter cannot be read, and the caller copes.
#
# Do not put this back on "qm monitor". Measured on the operator's Proxmox VE
# 9.2.20 host, against a running VM:
#
#     printf 'info blockstats\n' | qm monitor 200     ->  exit 124 under
#                                                         timeout 10, zero
#                                                         bytes of output
#
# It does not merely fail to answer. It never exits, and it prints its own
# "qm>" prompt into the caller's terminal - so qm_bytes_read never returned,
# press_a_key hung inside it forever, and the VM sat on an unanswered boot
# prompt until it timed out into "No bootable option or device was found".
# That was the real cause of two failed builds. qm monitor wants a terminal;
# a pipe does not satisfy it, and there is no flag that changes this.
#
# "qm status <vmid> --verbose" needs no terminal, exits by itself, and carries
# the same counters in an indented stanza per device:
#
#     blockstat:
#             ide0:
#                     rd_bytes: 3405824
#                     rd_operations: 1663
#
# It asks for the named device and, failing that, totals every rd_bytes it saw.
# The fallback matters because guessing the device name wrong would not merely
# lose the DVD counter, it would drop press_a_key into its blind mode - the one
# branch that cannot tell a boot prompt from Setup's Cancel button. Totalling
# is honest at this point in the boot because the disk is still blank and
# nothing but the DVD is being read at any volume. Any rd_bytes at all means
# the counter was readable, so a total of zero still prints.
#
# The timeout is belt and braces. Nothing in this loop may be allowed to block
# forever again.
qm_bytes_read() {
  local dev="$1"
  timeout 10 qm status "$VMID" --verbose 2>/dev/null | awk -v d="$dev" '
    /^blockstat:/            { inb = 1; next }
    inb && /^[^[:space:]]/   { inb = 0 }
    inb && NF == 1 && $1 ~ /:$/ { cur = substr($1, 1, length($1) - 1); next }
    inb && $1 == "rd_bytes:" {
      any = 1
      total += $2
      if (cur == d) { named = $2; found = 1 }
    }
    END { if (found) print named; else if (any) print total }'
}

# Answer the DVD's "Press any key to boot from CD or DVD" prompt, once, then
# stop.
#
# Stopping is the hard part, and the first version got it wrong. It pressed
# Enter every two seconds for a fixed sixty on the theory that Setup is driven
# by the answer file and would ignore the extras. It does not: Windows Setup
# shows a Cancel button that takes focus, so the surplus keypresses hammered it
# and the operator watched a confirmation dialog open and close for the rest of
# the minute. It only stayed harmless because that dialog also defaults to
# Cancel.
#
# So the keys have to stop as soon as the prompt has been answered, and the VM
# will tell us: before the keypress the DVD has given up only a boot sector and
# a loader, and after it Setup streams boot.wim off the same disc. A read count
# climbing hard means we are through and can stop pressing.
#
# The second version got the other half wrong. It kept the stop condition but
# still pressed on a schedule, inside a fixed twenty-second window opening the
# moment qm start returned - and every pass spawns two Perl programs, so twenty
# seconds bought seven or eight presses. OVMF with a TPM to measure does not
# usually reach the DVD that fast. The operator watched the whole window expire
# before the prompt appeared and then answered it by hand.
#
# The third version had the logic right and could not run it, because it read
# the counter through qm monitor, which hangs on piped input. See qm_bytes_read
# above. Watching that happen on the real host is what produced this version.
#
# The fourth version read the counter fine and drew two wrong conclusions from
# it, both found by tracing a real boot second by second. Measured on the
# operator's host, with no keys sent at all:
#
#     t=1  ide0=0          t=4  ide0=1169408     t=7  ide0=3084288
#     t=3  ide0=59392      t=5  ide0=1536000     t=9  ide0=3005824  <- flat
#                                                     ...and flat for the
#                                                     remaining 54 samples
#
# So the DVD gives up about 3 MiB and stops. Two lessons.
#
# First, "stop when the total passes 24 MiB" was a false positive. The UEFI
# Boot Manager's own device enumeration reads ~26 MiB - more than that
# threshold - so once the prompt had been missed and the firmware fell through
# to its menu, this function announced "Setup is streaming the DVD" at a VM
# parked on "Please select boot device". The honest measure is growth above
# where the counter first settled, because boot.wim is hundreds of MiB and
# firmware noise is tens.
#
# Second, "press only while the counter is exactly flat" was too narrow. Each
# poll costs a second or two because qm status is not instant, and the prompt
# lasts about five seconds, so the flat state can be entered and left between
# two samples. Keys now go out from the moment the firmware has touched the
# disc at all, which is harmless - the OVMF splash ignores Enter, and Setup's
# Cancel button only exists once the counter is climbing hard, which is the
# branch that exits. BOOT_KEY_MAX caps the total so a missed prompt cannot turn
# into a walk through the boot menu.
#
# All of this only holds while the counter is readable. When it is not we are
# back to pressing on faith, which is what hammered Cancel, so that path stays
# on a short leash and says so.
press_a_key() {
  local deadline bytes floor="" sent=0 grow_at tries=0

  grow_at=$(( BOOT_KEY_STREAM_MB * 1024 * 1024 ))

  msg_info "Answering the \"press any key to boot\" prompt"
  printf "   ${DIM}\$ qm sendkey %s %s${CL}   (up to %s, stopping the moment Setup streams)\n" \
    "$VMID" "$BOOT_KEY" "$BOOT_KEY_MAX"
  if [[ "$DRY_RUN" == "1" ]]; then
    msg_ok "Skipped — DRY_RUN"
    return 0
  fi

  # Settle which mode we are in before starting, because it decides how long we
  # are allowed to keep going. QEMU can be slow to answer in the first seconds
  # after qm start, so let the monitor miss a few times before writing it off.
  while (( tries < 5 )); do
    bytes="$(qm_bytes_read ide0)"
    [[ "$bytes" =~ ^[0-9]+$ ]] && break
    tries=$((tries + 1))
    sleep 1
  done

  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    msg_warn "Cannot read the DVD's byte counter from qm status - pressing blind"
    deadline=$((SECONDS + BOOT_KEY_BLIND_SECONDS))
    while (( SECONDS < deadline )); do
      qm sendkey "$VMID" "$BOOT_KEY" >/dev/null 2>&1 || true
      sent=$((sent + 1))
      sleep 2
    done
    msg_warn "Sent ${sent} keypress(es) blind over ${BOOT_KEY_BLIND_SECONDS}s. Watch the console."
    return 0
  fi

  deadline=$((SECONDS + BOOT_KEY_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
      # Where the counter first settled, which is the baseline everything is
      # measured against. A drop means the VM restarted and the counter reset,
      # so re-baseline rather than go negative.
      if [[ -z "$floor" ]] || (( bytes < floor )); then floor="$bytes"; fi

      if (( bytes - floor > grow_at )); then
        msg_ok "Setup is streaming the DVD (+$(( (bytes - floor) / 1048576 )) MiB) - stopped after ${sent} keypress(es)"
        return 0
      fi

      # Press from the moment the firmware has touched the disc, not only when
      # the counter is exactly flat. Polling costs a second or two, so "flat"
      # was too narrow a target to hit a five-second prompt reliably - it was
      # missed on a real build. Keys before the prompt are harmless: the OVMF
      # splash ignores Enter, and Setup's Cancel button - the thing this whole
      # function exists to avoid - only appears once the counter is climbing
      # hard, which is the branch above.
      if (( sent < BOOT_KEY_MAX )); then
        qm sendkey "$VMID" "$BOOT_KEY" >/dev/null 2>&1 || true
        sent=$((sent + 1))
      fi
    fi
    sleep 1
    bytes="$(qm_bytes_read ide0)"
  done

  msg_warn "Watched ${BOOT_KEY_SECONDS}s, sent ${sent} keypress(es), never saw Setup stream the DVD"
  msg_warn "Open the console. If the VM is at the UEFI shell, type ${BL}exit${CL} and boot the DVD by hand."
  return 0
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

# --- Unattended install ------------------------------------------------------
printf "\n"
UNATTEND="no"
if whiptail --backtitle "$APP" --title "Unattended install" \
    --yesno "Install Windows and configure the RD Gateway role without anyone at the console?\n\nThis builds a third CD holding an answer file, the VirtIO drivers and the setup scripts. Windows Setup wipes disk 0, installs, then a startup task installs the RD Gateway role and runs Setup-RDGateway.ps1.\n\nSaying no builds the VM shell only, and you install Windows by hand." 17 76; then
  UNATTEND="yes"
  resolve_support_files
  require_iso_tool
  select_storage iso "Unattend ISO"
  UNATTEND_STORAGE="$STORAGE_RESULT"
  unattend_settings
fi

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

if [[ "$UNATTEND" == "yes" ]]; then
  printf "\n"
  build_unattend_iso
  # q35 exposes only ide0 and ide2, both of which are taken, so the third
  # CD goes on the SATA controller. Boot order is unchanged.
  msg_info "Attaching the unattend CD"
  run qm set "$VMID" --sata0 "${UNATTEND_ISO},media=cdrom"
  msg_ok "Unattend CD attached on sata0"
fi

if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starting the VM"
  run qm start "$VMID"
  msg_ok "Started"
  # Only on the unattended path. With no answer file driving it, Windows Setup
  # is a live wizard within the first minute, and Enter every two seconds would
  # walk through the language screen, Install now, the edition list and the EULA
  # before anyone had looked at the console. The shell-only path exists to let
  # the operator drive those.
  [[ "$UNATTEND" == "yes" ]] && press_a_key
fi

# ------------------------------------------------------------------------------
# What happens next
#
# Two blocks the unattended summary interpolates, built here so the heredoc
# below stays readable.
RESOURCE_SUMMARY=""
case "${RESOURCE_SCOPE}" in
  AnyResource)
    RESOURCE_SUMMARY="   ${BL}Any machine this server can route to.${CL} Each one still needs Remote
   Desktop switched on and your account in its own local Remote Desktop
   Users group; the gateway decides where you may tunnel, not what you may
   log into." ;;
  Listed)
    RESOURCE_SUMMARY="   The gateway itself plus: ${BL}${TARGET_MACHINES}${CL}
   Anything not on that list is refused with event 301, so add machines by
   re-running ${BL}Setup-RDGateway.ps1 -TargetMachines${CL} later." ;;
  *)
    RESOURCE_SUMMARY="   ${BL}This gateway only.${CL} Re-run ${BL}Setup-RDGateway.ps1${CL} with
   ${BL}-TargetMachines${CL} or ${BL}-ResourceScope AnyResource${CL} to widen it." ;;
esac

CUSTOM_SUMMARY=""
if [[ "$(custom_total)" -gt 0 ]]; then
  CUSTOM_SUMMARY="
${BOLD}Your own scripts${CL}
   $(custom_total) of them, run from ${BL}C:\\Windows\\Setup\\Scripts\\custom${CL} and logged
   in the same file, prefixed ${BL}custom/<category>${CL}. One that fails or runs
   past 15 minutes is logged and skipped rather than stopping the build.
"
fi

if [[ "$UNATTEND" == "yes" ]]; then
cat <<EOF

${BOLD}${GN}VM ${VMID} is built and will install itself.${CL}

Nothing below needs you at the console. It is here so you know what is
happening and where to look if it stalls.

${BOLD}What runs, in order${CL}
   1. The DVD asks you to press a key to boot from it. This script answered
      that from the host with ${BL}qm sendkey${CL}, which is why nothing had to
      be at the console. The prompt is left in place on purpose: Setup's own
      reboots rely on it timing out to fall through to the disk.
   2. Windows Setup finds ${BL}autounattend.xml${CL} on the unattend CD by
      itself and stages the VirtIO drivers from the ${BL}\$WinPEDriver\$${CL}
      folder on that same CD. No "Load driver" step.
   3. It wipes disk 0, partitions it (EFI / MSR / NTFS), and installs
      ${BL}${IMAGE_NAME}${CL}.
   4. The specialize pass copies the scripts to
      ${BL}C:\\Windows\\Setup\\Scripts${CL} and registers a startup task.
   5. That task applies your settings, installs the VirtIO guest tools from
      the CD still attached on ide2 (so Proxmox can read the IP and shut the
      VM down cleanly), installs the RD Gateway role, reboots if Windows asks,
      then runs ${BL}Setup-RDGateway.ps1${CL} and verifies the TSGateway service.

   Expect ${BL}two or three reboots${CL} and roughly 20-40 minutes depending on
   the disk underneath.

${BOLD}Where to look${CL}
   ${BL}C:\\Windows\\Setup\\Scripts\\rdgw-setup.log${CL}  every step, timestamped
   ${BL}C:\\Windows\\Panther\\setupact.log${CL}           Windows Setup itself

   The gateway is done when the log ends with ${BL}First-boot setup finished.${CL}
${CUSTOM_SUMMARY}
${BOLD}Reachable through the gateway${CL}
${RESOURCE_SUMMARY}

${BOLD}When it is finished${CL}
   Detach the media and delete the unattend CD — it holds the account password
   in clear text:
   ${DIM}\$ qm set ${VMID} --ide0 none --ide2 none --sata0 none --boot order=scsi0${CL}
   ${DIM}\$ rm ${UNATTEND_ISO_PATH}${CL}

   Then give the VM a ${BL}static IP or DHCP reservation${CL}, forward TCP 443 to
   it, and replace the self-signed certificate with a real one. README.md
   Phase 5 and 6 cover the DNS, certificate and firewall work.

${BOLD}If it stalls${CL}
   The task is ${BL}RDGW-FirstBoot${CL} and stays registered until it succeeds, so
   a reboot retries. Read the log first; it names the failing step and prints
   the command to finish by hand.

EOF
else
cat <<EOF

${BOLD}${GN}VM ${VMID} is built.${CL} Windows is not installed yet — do that next.

${BOLD}1. Open the console${CL}
   Proxmox web UI -> VM ${VMID} -> Console. Press a key when it offers to
   boot from the DVD; you have about five seconds. Miss it and you land in the
   UEFI shell: type ${BL}exit${CL}, pick Boot Manager, and choose the DVD.

   ${DIM}The unattended path answers that prompt from the host. This one leaves
   it to you on purpose - with no answer file driving Setup, a keystroke every
   two seconds would walk through the very screens you are here to drive.${CL}

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
   PowerShell prompt. See README.md for the DNS, certificate and
   port-forwarding work that has to happen around it.

EOF
fi
