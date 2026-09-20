<#
.SYNOPSIS
    Applies the guest-side settings chosen during windows-rdgw-vm.sh.

.DESCRIPTION
    Runs once, as SYSTEM, on the first boot of a VM built by windows-rdgw-vm.sh.
    Every setting it touches came from a prompt in that script; nothing here
    decides anything on its own. The choices arrive in rdgw-config.psd1, which
    the builder writes next to this file.

    Two groups of work:

      1. Security posture. Account lockout, UAC, Defender, Core Isolation and
         the Ctrl+Alt+Del logon requirement. The builder defaults leave all of
         these where Windows put them; each one changes only if the operator
         explicitly asked for it.

      2. Server housekeeping. Filesystem and shell settings that make a
         Server 2025 box you administer over RDP less annoying to live with.
         Cosmetic or performance-related, never security-relevant.

    Read it top to bottom. Each block is independent - delete any you do not
    want and the rest still works.

    Deliberately pure ASCII, targeting Windows PowerShell 5.1, matching
    Setup-RDGateway.ps1.

.NOTES
    Written to the unattend ISO by windows-rdgw-vm.sh. Do not run it by hand
    against a machine you care about without reading rdgw-config.psd1 first.
#>

[CmdletBinding()]
param(
    [string] $ConfigPath = '',
    [string] $LogPath = ''
)

$ErrorActionPreference = 'Continue'

# These two defaults used to be (Join-Path $PSScriptRoot '...'), evaluated
# inside the param block. On a real Server 2025 build $PSScriptRoot came back
# empty, and Join-Path throws on an empty -Path - from inside a param default,
# which means the script dies during parameter binding, before its first
# statement, before the log it is holding the path to. There is no catch that
# helps and nothing is written down. See CLAUDE.md.
#
# Resolving in the body instead means the worst case is a wrong path we can
# report, not a script that vanishes.
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = 'C:\Windows\Setup\Scripts'
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:Root 'rdgw-config.psd1'
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $script:Root 'rdgw-setup.log'
}

$script:LogPath = $LogPath
$script:LogWritable = $true
$script:Failures = 0

# This file logs itself, and that is not optional decoration.
#
# It used to print with Write-Host alone and let the caller capture it with
# "& Configure-Guest.ps1 2>&1 | Tee-Object". That never worked: 2>&1 merges the
# error stream into the success stream, but Write-Host writes to the
# information stream, which a plain pipe does not carry. So every [ ok ] and
# [fail] line this script produced went to a console nobody was watching and
# none of it reached rdgw-setup.log - leaving an operator with a log that
# records the build happening and nothing about whether any setting took.
function Write-Line {
    param([string] $Line)
    Write-Host $Line
    if ($script:LogWritable) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $Line -Encoding ASCII -ErrorAction Stop
        } catch {
            $script:LogWritable = $false
            Write-Host "    (log not writable: $($_.Exception.Message))"
        }
    }
}

function Write-Step { param([string] $m) Write-Line "" ; Write-Line "=== $m ===" }
function Write-Good { param([string] $m) Write-Line "    [ ok ] $m" }
function Write-Skip { param([string] $m) Write-Line "    [skip] $m" }
function Write-Bad  { param([string] $m) $script:Failures++ ; Write-Line "    [fail] $m" }

# Wrapper so one failed registry write cannot take the whole run down.
function Set-Reg {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)] $Value,
        [ValidateSet('DWord', 'String', 'ExpandString')][string] $Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value `
            -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Good "$Path :: $Name = $Value"
    } catch {
        Write-Bad "$Path :: $Name -- $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Bad "No config file at $ConfigPath. Nothing to do."
    exit 1
}
$cfg = Import-PowerShellDataFile -LiteralPath $ConfigPath

# ------------------------------------------------------------------------------
# 1. Account lockout
#
#    Threshold 0 disables lockout entirely. Anything else sets the threshold,
#    the observation window and the lockout duration together. README.md calls
#    10 attempts per 15 minutes a reasonable floor for a gateway that faces the
#    internet.
# ------------------------------------------------------------------------------
Write-Step "Account lockout policy"
$threshold = [int] $cfg.LockoutThreshold
if ($threshold -le 0) {
    & net.exe accounts /lockoutthreshold:0 | Out-Null
    Write-Good "Lockout disabled (threshold 0) - chosen at build time"
} else {
    $window = [int] $cfg.LockoutWindow
    & net.exe accounts "/lockoutthreshold:$threshold" | Out-Null
    & net.exe accounts "/lockoutwindow:$window" "/lockoutduration:$window" | Out-Null
    Write-Good "Lockout: $threshold attempts, $window minute window and duration"
}

# ------------------------------------------------------------------------------
# 2. Blank password over the network
#
#    Windows refuses network logon for blank-password accounts by default
#    (LimitBlankPasswordUse = 1). An RD Gateway authenticates over the network,
#    so a blank-password account cannot get in at all unless this is cleared.
#    Touched only when the operator actually chose a blank password - otherwise
#    the protection stays exactly where Windows put it.
# ------------------------------------------------------------------------------
Write-Step "Blank password policy"
if ($cfg.BlankPassword) {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LimitBlankPasswordUse' 0
    Write-Good "Blank-password network logon permitted - required by the blank password chosen at build time"
} else {
    Write-Skip "Left at the Windows default (blank passwords cannot log on over the network)"
}

# ------------------------------------------------------------------------------
# 3. User Account Control
# ------------------------------------------------------------------------------
Write-Step "User Account Control"
if ($cfg.DisableUac) {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 0
    Write-Good "UAC disabled - chosen at build time. Takes effect after a reboot."
} else {
    Write-Skip "Left enabled"
}

# ------------------------------------------------------------------------------
# 4. Microsoft Defender Antivirus
#
#    Sets the service start type to 4 (disabled). Tamper Protection blocks this
#    on a machine where it is switched on; that failure is logged, not fatal.
# ------------------------------------------------------------------------------
Write-Step "Microsoft Defender"
if ($cfg.DisableDefender) {
    # This used to write Start=4 over the six WinDefend service keys, which is
    # what most "disable Defender" snippets do and which Microsoft documents
    # against in as many words: "Don't disable, stop, or modify any of the
    # associated services that are used by Microsoft Defender Antivirus ...
    # Manually modifying these services can cause severe instability". Tamper
    # Protection is on by default on Server 2025 and denies those writes even to
    # SYSTEM, so the old code failed on every key and then printed success
    # anyway.
    #
    # On Windows Server, Defender is an installable feature, and removing it is
    # the documented route. It needs a reboot to finish, which the first-boot
    # task takes before it installs the gateway role.
    $removed = $false
    try {
        Import-Module ServerManager -ErrorAction SilentlyContinue
        $feature = Get-WindowsFeature -Name Windows-Defender -ErrorAction Stop
        if (-not $feature -or -not $feature.Installed) {
            Write-Skip "The Windows-Defender feature is not installed - nothing to remove"
            $removed = $true
        } else {
            $result = Uninstall-WindowsFeature -Name Windows-Defender -ErrorAction Stop
            if ($result.Success) {
                $removed = $true
                Write-Good "Windows-Defender feature removed - chosen at build time. Finishes at the next reboot."
            } else {
                Write-Bad "Uninstall-WindowsFeature returned exit code $($result.ExitCode)"
            }
        }
    } catch {
        Write-Bad "Could not remove the Windows-Defender feature: $($_.Exception.Message)"
    }
    if (-not $removed) {
        Write-Bad "Defender is still installed. By hand: Uninstall-WindowsFeature Windows-Defender -Restart"
    }
} else {
    Write-Skip "Left enabled"
}

# ------------------------------------------------------------------------------
# 5. Core Isolation / virtualisation-based security
# ------------------------------------------------------------------------------
Write-Step "Core Isolation (VBS / HVCI)"
if ($cfg.DisableCoreIsolation) {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Write-Good "VBS and HVCI disabled - chosen at build time"
} else {
    Write-Skip "Left at the Windows default"
}

# ------------------------------------------------------------------------------
# 6. Ctrl+Alt+Del at the logon screen
#
#    DisableCAD = 1 means "do not require CTRL+ALT+DEL". Sending that key
#    combination to a Proxmox console takes a menu trip, which is why the
#    builder defaults this one to not-required.
# ------------------------------------------------------------------------------
Write-Step "Ctrl+Alt+Del logon requirement"
if ($cfg.DisableCad) {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 1
    Write-Good "Ctrl+Alt+Del no longer required to log on"
} else {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 0
    Write-Good "Ctrl+Alt+Del required to log on (Proxmox console: the toolbar sends it)"
}

# ------------------------------------------------------------------------------
# 7. Shell settings for every account created from here on
#
#    These live in HKCU, so they are written into the Default User hive before
#    anyone logs on for the first time and new profiles inherit them. An account
#    that already has a profile keeps whatever it has - which is why this script
#    is scheduled at startup, ahead of the first interactive logon.
# ------------------------------------------------------------------------------
Write-Step "Shell settings (Default User hive)"

$defaultHive = 'C:\Users\Default\NTUSER.DAT'
$mountPoint = 'HKU\rdgwDefault'
$loaded = $false

if (Test-Path -LiteralPath $defaultHive) {
    & reg.exe load $mountPoint $defaultHive 2>&1 | Out-Null
    $loaded = ($LASTEXITCODE -eq 0)
}

if (-not $loaded) {
    Write-Skip "Could not load the Default User hive - shell settings skipped, everything above still applied"
} else {
    $u = 'Registry::HKEY_USERS\rdgwDefault'

    # The shell defaults below are cosmetic and belong to the housekeeping
    # answer. Everything after them does not: your DefaultUser scripts and the
    # UserOnce registration have nothing to do with taskbar layout, so they run
    # either way.
    if ($cfg.ApplyTweaks) {
        $adv = "$u\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

        # Explorer: show file extensions, open to This PC, classic right-click menu.
        Set-Reg $adv 'HideFileExt' 0
        Set-Reg $adv 'LaunchTo' 1
        Set-Reg "$u\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" '(Default)' '' 'String'

        # Taskbar: left aligned, no search box, no Task View, no widgets.
        Set-Reg $adv 'TaskbarAl' 0
        Set-Reg $adv 'ShowTaskViewButton' 0
        Set-Reg $adv 'TaskbarDa' 0
        Set-Reg "$u\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 0

        # No web results in the Start menu search box.
        Set-Reg "$u\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1

        # Adjust for best performance. Animations over RDP are wasted bandwidth.
        Set-Reg "$u\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2

        # Dark theme.
        Set-Reg "$u\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme' 0
        Set-Reg "$u\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 0

        # Desktop icons: This PC, Recycle Bin and the user folder visible.
        $iconKey = "$u\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        Set-Reg $iconKey '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0
        Set-Reg $iconKey '{645FF040-5081-101B-9F08-00AA002F954E}' 0
        Set-Reg $iconKey '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 0

    } else {
        Write-Skip "Shell defaults skipped - housekeeping was not requested"
    }
    # Anything you supplied for the DefaultUser category runs here, while the
    # hive is still mounted, so what it writes is inherited by every profile
    # created afterwards. The UserOnce registration goes in for the same
    # reason: a RunOnce value in this hive is inherited by each new profile and
    # fires at that user's first logon, then deletes itself.
    $runner = Join-Path $script:Root 'Invoke-CustomScripts.ps1'
    if (Test-Path -LiteralPath $runner) {
        try {
            & $runner -Category DefaultUser -HiveRoot $mountPoint
        } catch {
            Write-Bad "Custom DefaultUser scripts failed: $($_.Exception.Message)"
        }

        $userOnceDir = Join-Path $script:Root 'custom\UserOnce'
        $userOnceCount = 0
        if (Test-Path -LiteralPath $userOnceDir) {
            $userOnceCount = @(Get-ChildItem -LiteralPath $userOnceDir -File -ErrorAction SilentlyContinue).Count
        }
        if ($userOnceCount -gt 0) {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Category UserOnce' -f $runner
            Set-Reg "$u\Software\Microsoft\Windows\CurrentVersion\RunOnce" 'RDGWUserOnce' $cmd 'String'
            Write-Good "UserOnce scripts ($userOnceCount) registered for every new profile"
        }
    }

    [gc]::Collect()
    & reg.exe unload $mountPoint 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Good "Default User hive written and unloaded"
    } else {
        Write-Bad "Default User hive written but would not unload - a reboot clears this"
    }
}

if (-not $cfg.ApplyTweaks) {
    Write-Step "Server housekeeping"
    Write-Skip "Skipped - not requested at build time"
    Write-Step "Done"
    exit 0
}

# ------------------------------------------------------------------------------
# 8. Filesystem and system behaviour
#
#    None of this is security-relevant.
# ------------------------------------------------------------------------------
Write-Step "Filesystem and system behaviour"

# 8.3 short names cost write performance and buy nothing on a modern server.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 1
try {
    & fsutil.exe 8dot3name set 1 | Out-Null
    Write-Good "fsutil 8dot3name set 1"
} catch {
    Write-Bad "fsutil 8dot3name -- $($_.Exception.Message)"
}

# Fast startup hibernates the kernel instead of shutting down. On a VM it only
# makes "restart" and "shut down" behave differently, which is confusing.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0

# Long paths, so robocopy and friends stop failing at 260 characters.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1

# WPBT lets host firmware drop an executable into Windows at boot. Nothing on a
# QEMU guest needs it.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1

# Do not reboot out from under a logged-on administrator. A gateway that
# reboots mid-session during Windows Update is a gateway nobody trusts.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1

# NumLock on at the logon screen. .DEFAULT is the hive the logon UI uses.
Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'

# Silence system sounds. Audio over RDP that only ever plays error dings is
# worth turning off.
try {
    Get-ChildItem -LiteralPath 'Registry::HKEY_USERS\.DEFAULT\AppEvents\Schemes\Apps' -Recurse -ErrorAction Stop |
        Where-Object { $_.PSChildName -eq '.Current' } |
        ForEach-Object {
            Set-ItemProperty -LiteralPath $_.PSPath -Name '(Default)' -Value '' -ErrorAction SilentlyContinue
        }
    Write-Good "System sounds cleared in the .DEFAULT hive"
} catch {
    Write-Bad "System sounds -- $($_.Exception.Message)"
}

# Let the scripts this build relies on actually run.
try {
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    Write-Good "Execution policy (LocalMachine) = RemoteSigned"
} catch {
    Write-Bad "Set-ExecutionPolicy -- $($_.Exception.Message)"
}

# Windows.old only exists if this was an upgrade rather than a clean install,
# but check anyway - it is 10+ GiB when it is there.
if (Test-Path -LiteralPath 'C:\Windows.old') {
    try {
        & takeown.exe /F 'C:\Windows.old' /R /A /D Y | Out-Null
        & icacls.exe 'C:\Windows.old' /grant 'Administrators:F' /T /C /Q | Out-Null
        Remove-Item -LiteralPath 'C:\Windows.old' -Recurse -Force -ErrorAction Stop
        Write-Good "Removed C:\Windows.old"
    } catch {
        Write-Bad "C:\Windows.old -- $($_.Exception.Message)"
    }
} else {
    Write-Skip "No C:\Windows.old to remove"
}

Write-Step "Done"
if ($script:Failures -gt 0) {
    Write-Line "    $($script:Failures) setting(s) could not be applied - see the [fail] lines above"
} else {
    Write-Line "    every setting applied without error"
}
exit 0
