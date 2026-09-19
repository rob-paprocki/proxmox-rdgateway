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
#  The unattended path needs the sibling scripts from this repo, so run it from
#  a checkout rather than curling this one file.
#
#  Usage:
#      bash windows-rdgw-vm.sh
#      DRY_RUN=1 bash windows-rdgw-vm.sh     # print every command, run nothing
#                                            # and echo the generated answer file
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

# Where the sibling scripts live. The unattend ISO needs Setup-RDGateway.ps1,
# Configure-Guest.ps1 and Invoke-GatewaySetup.ps1, so this has to be a real
# checkout rather than a lone curl of this one file.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Set while an unattend ISO is being built, so the exit trap can clean up a
# loop mount or a staging directory if something fails midway.
UNATTEND_MOUNT=""
UNATTEND_STAGE=""

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
      whiptail --backtitle "$APP" --title "Mismatch" --msgbox "Those did not match. Try again." 8 50
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

  ask "Target machines to reach (space separated, blank for this server only)" ""
  TARGET_MACHINES="$ASK_RESULT"

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
  local stage="$1" product_key_block=""

  if [[ -n "$GVLK" ]]; then
    product_key_block="
            <ProductKey>
                <Key>${GVLK}</Key>
                <WillShowUI>Never</WillShowUI>
            </ProductKey>"
  fi

  write_file "${stage}/autounattend.xml" 644 <<XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<!--
    Generated by windows-rdgw-vm.sh for VM ${VMID} (${HN}).

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
                            <Value>${IMAGE_NAME}</Value>
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
                <FullName>${ADMIN_USER}</FullName>${product_key_block}
            </UserData>
        </component>
    </settings>

    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>${HN}</ComputerName>
            <TimeZone>${WIN_TIMEZONE}</TimeZone>
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
                    <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Invoke-GatewaySetup.ps1 -Register</Path>
                </RunSynchronousCommand>
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
                        <Name>${ADMIN_USER}</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>${ADMIN_PASS}</Value>
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
                <Username>${ADMIN_USER}</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                    <Value>${ADMIN_PASS}</Value>
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
    targets+="'${m}', "
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
    ComputerName         = '${HN}'
    AccountName          = '${ADMIN_USER}'
    ExternalFqdn         = '${EXTERNAL_FQDN}'
    TargetMachines       = @(${targets})
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
  msg_ok "Answer file written"

  msg_info "Staging the first-boot scripts"
  local f
  for f in Configure-Guest.ps1 Invoke-GatewaySetup.ps1 Setup-RDGateway.ps1; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
      msg_error "Missing ${SCRIPT_DIR}/${f}. Run this from a full checkout of the repo."
      exit 1
    fi
    run mkdir -p "${stage}/rdgw"
    run cp "${SCRIPT_DIR}/${f}" "${stage}/rdgw/${f}"
  done
  msg_ok "Scripts staged"

  iso_dir="$(iso_dir_for_storage "$UNATTEND_STORAGE")"
  if [[ -z "$iso_dir" ]]; then
    msg_error "Could not resolve the ISO directory for storage '${UNATTEND_STORAGE}'."
    exit 1
  fi
  out="${iso_dir}/unattend-${VMID}.iso"

  msg_info "Building ${out}"
  run mkdir -p "$iso_dir"
  case "$ISO_TOOL" in
    xorriso) run xorriso -as mkisofs -quiet -J -r -V UNATTEND -o "$out" "$stage" ;;
    *)       run "$ISO_TOOL" -quiet -J -r -V UNATTEND -o "$out" "$stage" ;;
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
fi

# ------------------------------------------------------------------------------
# What happens next
if [[ "$UNATTEND" == "yes" ]]; then
cat <<EOF

${BOLD}${GN}VM ${VMID} is built and will install itself.${CL}

Nothing below needs you at the console. It is here so you know what is
happening and where to look when it does not happen.

${BOLD}What runs, in order${CL}
   1. Windows Setup boots from the DVD, finds ${BL}autounattend.xml${CL} on the
      unattend CD by itself, and stages the VirtIO drivers from the
      ${BL}\$WinPEDriver\$${CL} folder on that same CD. No "Load driver" step.
   2. It wipes disk 0, partitions it (EFI / MSR / NTFS), and installs
      ${BL}${IMAGE_NAME}${CL}.
   3. The specialize pass copies the scripts to
      ${BL}C:\\Windows\\Setup\\Scripts${CL} and registers a startup task.
   4. That task applies your settings, installs the RD Gateway role, reboots
      if Windows asks, then runs ${BL}Setup-RDGateway.ps1${CL} and verifies the
      TSGateway service.

   Expect ${BL}two or three reboots${CL} and roughly 20-40 minutes depending on
   the disk underneath.

${BOLD}Where to look${CL}
   ${BL}C:\\Windows\\Setup\\Scripts\\rdgw-setup.log${CL}  every step, timestamped
   ${BL}C:\\Windows\\Panther\\setupact.log${CL}           Windows Setup itself

   The gateway is done when the log ends with ${BL}First-boot setup finished.${CL}

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
   PowerShell prompt. See README.md for the DNS, certificate and
   port-forwarding work that has to happen around it.

EOF
fi
