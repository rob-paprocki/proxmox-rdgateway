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
    [string] $LogPath = '',

    # Where this script and its config live. Passed explicitly by whatever
    # invokes it, because $PSScriptRoot came back empty on a real Server 2025
    # build. Resolved defensively below either way.
    [string] $ScriptRoot = '',

    # Apply only the cosmetic shell settings, to whoever is running this, then
    # restart Explorer and exit. The answer file registers this in HKLM RunOnce
    # so it fires at the first interactive logon - including the AutoLogon
    # account, which is the one account the Default User hive cannot reach.
    # See Set-ShellSetting.
    [switch] $ShellForCurrentUser,

    # Which pass this is running in, because when the work happens matters as
    # much as whether it happens.
    #
    #   Specialize - everything that can possibly be done before Windows creates
    #                a profile or shows a desktop: the Default User hive, all the
    #                machine-wide settings, the VirtIO guest tools and the
    #                operator's System scripts. This is where the bulk of the
    #                build belongs, and where cschneegans/unattend-generator puts
    #                its equivalent work.
    #   FirstBoot  - only what genuinely cannot run in specialize. Today that is
    #                removing the Defender feature, which needs a reboot and must
    #                not run alongside Setup's own servicing.
    #   All        - both, for running this by hand.
    [ValidateSet('Specialize', 'FirstBoot', 'All')]
    [string] $Phase = 'All'
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
    $script:Root = $ScriptRoot
}
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

# The cosmetic shell settings, written once and applied to whichever registry
# root is asked for. Being callable twice, with two different roots, is the
# entire point.
#
# Writing them only into the Default User hive is what this repo did for three
# builds, and it cannot work for the account AutoLogon creates: that profile is
# copied from the hive at roughly the moment this script is writing it, and on
# a real build the profile won - the operator got a centred taskbar and the
# light theme, having asked for neither. The Default User hive is still the
# right home for every profile created later, so it stays; it just is not
# enough on its own.
#
# cschneegans/unattend-generator solves the same problem by writing these again
# in its UserOnce phase against the real HKCU and then restarting Explorer.
# -ShellForCurrentUser is that, borrowed.
function Set-ShellSetting {
    param([Parameter(Mandatory = $true)][string] $Root)

    $adv = "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

    # Explorer: show file extensions, open to This PC, classic right-click menu.
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg $adv 'LaunchTo' 1
    Set-Reg "$Root\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" '(Default)' '' 'String'

    # Taskbar: left aligned, no search box, no Task View, no widgets.
    Set-Reg $adv 'TaskbarAl' 0
    Set-Reg $adv 'ShowTaskViewButton' 0
    Set-Reg $adv 'TaskbarDa' 0
    Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 0

    # No web results in the Start menu search box.
    Set-Reg "$Root\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1

    # Adjust for best performance. Animations over RDP are wasted bandwidth.
    Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2

    # Dark theme.
    Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme' 0
    Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 0

    # Desktop icons: This PC, Recycle Bin and the user folder visible.
    $iconKey = "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    Set-Reg $iconKey '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0
    Set-Reg $iconKey '{645FF040-5081-101B-9F08-00AA002F954E}' 0
    Set-Reg $iconKey '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 0
}

# Explorer reads the settings above once, at startup, so a logged-on user sees
# nothing until it is restarted. Only this session's Explorer: killing another
# user's would be rude, and on a server there may be several.
function Restart-ExplorerHere {
    try {
        $mySession = (Get-Process -Id $PID).SessionId
        $procs = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $mySession })
        if ($procs.Count -eq 0) {
            Write-Skip "Explorer is not running in this session - nothing to restart"
            return
        }
        $procs | Stop-Process -Force -ErrorAction Stop
        Write-Good "Explorer restarted so the shell settings take effect now"
    } catch {
        Write-Bad "Could not restart Explorer: $($_.Exception.Message) - sign out and back in"
    }
}

# ------------------------------------------------------------------------------
# 7. Shell settings for every account created from here on
#
#    These live in HKCU, so they are written into the Default User hive and new
#    profiles inherit them. That covers every account made later and is worth
#    doing - but it does NOT cover the AutoLogon account, whose profile is
#    copied out of this hive at about the moment this script is writing it. On
#    a real build that race was lost. The same settings are therefore applied a
#    second time, per user, by -ShellForCurrentUser at first logon. Neither
#    half is redundant: this one reaches future profiles, that one reaches the
#    account the operator is actually looking at.
# ------------------------------------------------------------------------------
function Invoke-DefaultUserHive {
    # Everything that has to happen BEFORE any profile exists. Called twice by
    # two different callers, and only one of them normally does the work:
    #
    #   specialize, via Invoke-GatewaySetup.ps1 -Register ->
    #       Configure-Guest.ps1 -DefaultUserOnly. This is the correct moment.
    #       Windows has not created a single profile yet, so what goes into the
    #       hive is genuinely inherited by the first account.
    #
    #   the first-boot task, as a fallback, if the specialize call did not run
    #       or did not finish.
    #
    # It used to run only from the first-boot task, and that loses a race it
    # cannot win: AutoLogon creates the first profile from this hive at about
    # the moment this code is writing it. On a real build the profile won and
    # the operator got a centred taskbar and the light theme having asked for
    # neither. cschneegans/unattend-generator does the hive in specialize for
    # this reason - reg load, script, reg unload as three separate commands.
    #
    # The marker file is what stops the DefaultUser custom scripts running
    # twice. The shell settings are idempotent registry writes and would not
    # care, but someone else's script is not required to be.
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
        # Everything between here and the unload is wrapped, because an unmounted
        # hive is not optional. reg.exe keeps NTUSER.DAT open for as long as it is
        # loaded, so a script that throws half way through used to leave the Default
        # User profile locked for the rest of setup - and every profile created
        # afterwards inherits from a file nothing can write to. cschneegans'
        # generator sidesteps this by making load, run and unload three separate
        # answer-file commands, so a failing script cannot skip the unload. We run
        # inside one script, so try/finally is how we get the same guarantee.
        try {
            if ($cfg.ApplyTweaks) {
                Set-ShellSetting -Root $u
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
        }
        finally {
            [gc]::Collect()
            & reg.exe unload $mountPoint 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Good "Default User hive written and unloaded"
            } else {
                Write-Bad "Default User hive written but would not unload - a reboot clears this"
            }
        }
    }
}

# Removing the Defender feature, which is a CBS servicing operation and the
# single slowest thing in the whole build - 10m33s on a measured run, half of
# everything after first boot. It is also the one piece of guest configuration
# that cannot move into specialize: it needs a reboot to finish, and running a
# feature uninstall concurrently with Setup's own servicing is asking for a
# corrupted image. So it stays in the first-boot task while everything else
# moves earlier. See the -Phase parameter.
function Invoke-DefenderRemoval {
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
}

# The VirtIO guest tools, which carry the QEMU guest agent. This is what lets
# the builder on the Proxmox host read rdgw-setup.log, so it wants to happen as
# early as it possibly can - but "as early as it can" is the first boot, not
# specialize, and that was measured rather than assumed. See CLAUDE.md.
#
# Defined above both callers on purpose: PowerShell resolves functions in script
# order at run time, so one defined below its caller does not exist yet.
function Invoke-GuestToolsInstall {
    Write-Step "VirtIO guest tools"

    # Two installs, and the order is the whole point. The bundle lays down the
    # balloon, serial, input and SPICE components and takes a couple of
    # minutes; the agent it also carries is the one piece anybody is waiting
    # for, because until qemu-ga answers the builder on the Proxmox host cannot
    # read a single line of this log and just prints a byte counter. The CD
    # ships that agent on its own as guest-agent\qemu-ga-x86_64.msi, which is a
    # few seconds. So put it in first, let the host start streaming, and then
    # spend the minutes on everything else.
    $agentMsi = $null
    $guestTools = $null
    foreach ($d in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') {
        if (-not $agentMsi) {
            $c = "${d}:\guest-agent\qemu-ga-x86_64.msi"
            if (Test-Path -LiteralPath $c) { $agentMsi = $c }
        }
        if (-not $guestTools) {
            $c = "${d}:\virtio-win-guest-tools.exe"
            if (Test-Path -LiteralPath $c) { $guestTools = $c }
        }
        if ($agentMsi -and $guestTools) { break }
    }

    if (-not $agentMsi) {
        Write-Skip "No guest-agent\qemu-ga-x86_64.msi on any drive - the agent arrives with the bundle below instead, a couple of minutes later"
    } else {
        try {
            # Start-Process joins ArgumentList with plain spaces and quotes
            # nothing, so the path is quoted here. See Invoke-Child.
            $p = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList '/i', "`"$agentMsi`"", '/qn', '/norestart' `
                -Wait -PassThru -ErrorAction Stop
            $null = $p.Handle
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                Write-Good "QEMU guest agent in from $agentMsi (exit $($p.ExitCode)) - the host can read this log from here on"
            } else {
                # Not a failure: the bundle installs the agent too. It only
                # means the host stays blind for another minute or two.
                Write-Skip "$agentMsi exited $($p.ExitCode) - falling back to the bundle for the agent"
            }
        } catch {
            Write-Skip "Could not run msiexec on ${agentMsi}: $($_.Exception.Message)"
        }
    }

    if (-not $guestTools) {
        Write-Skip "virtio-win-guest-tools.exe not found on any drive - is the VirtIO CD still attached? Install it by hand later"
        return
    }

    try {
        $p = Start-Process -FilePath $guestTools -ArgumentList '/passive', '/norestart' `
            -Wait -PassThru -ErrorAction Stop
        # Same reason as Invoke-CustomScripts.ps1: without touching Handle,
        # ExitCode reads back empty once the child is gone.
        $null = $p.Handle
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Good "Installed $guestTools (exit $($p.ExitCode))"
        } else {
            Write-Bad "$guestTools exited $($p.ExitCode)"
            Write-Line "         Windows Installer logs are in C:\Windows\Temp\Virtio-win-guest-tools_*.log"
            Write-Line "         By hand: $guestTools"
        }
    } catch {
        Write-Bad "Could not run ${guestTools}: $($_.Exception.Message)"
    }
}


if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Bad "No config file at $ConfigPath. Nothing to do."
    exit 1
}
$cfg = Import-PowerShellDataFile -LiteralPath $ConfigPath

# ------------------------------------------------------------------------------
# 0. -ShellForCurrentUser: the second half of the shell settings
#
#    Runs at the first interactive logon, as that user, from an HKLM RunOnce
#    value the answer file writes. Everything here is cosmetic, so it touches
#    nothing else and never fails the build.
# ------------------------------------------------------------------------------
if ($Phase -eq 'FirstBoot') {
    # Everything else already happened in specialize, before any desktop existed.
    # These two are what is left, and the order is deliberate: the guest tools
    # take about a minute and bring up the agent the builder needs to read this
    # log, while Defender takes ten and produces nothing anyone can watch.
    Invoke-GuestToolsInstall
    Invoke-DefenderRemoval
    Write-Step "Done"
    if ($script:Failures -gt 0) {
        Write-Line "    $($script:Failures) setting(s) could not be applied - see the [fail] lines above"
    }
    exit 0
}

if ($ShellForCurrentUser) {
    Write-Step "Shell settings (current user: $env:USERNAME)"

    # Belt and braces on the automatic logon. The answer file sets LogonCount 1
    # and Windows decrements it, so this should already be zero - but if that
    # decrement ever does not happen, a gateway that logs itself in on every
    # boot is a gateway with a permanently unlocked console. Safe to do here
    # and nowhere earlier: by the time this runs the one automatic logon has
    # already happened, so it cannot suppress the logon the RunOnce values
    # below depend on. cschneegans/unattend-generator does this in the same
    # phase, for the same reason.
    #
    # Needs elevation, which a RunOnce value does not always have, so a failure
    # here is logged and shrugged off rather than treated as a problem.
    try {
        Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
            -Name 'AutoLogonCount' -Type DWord -Value 0 -Force -ErrorAction Stop
        Write-Good "AutoLogonCount set to 0"
    } catch {
        Write-Skip "Could not clear AutoLogonCount (needs elevation): $($_.Exception.Message)"
    }

    if ($cfg.ApplyTweaks) {
        Set-ShellSetting -Root 'HKCU:'
        # The Edge shortcut this user inherited from the Default User desktop.
        $lnk = Join-Path $env:USERPROFILE 'Desktop\Microsoft Edge.lnk'
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            Write-Good "Removed the Edge desktop shortcut"
        }
        Restart-ExplorerHere
    } else {
        Write-Skip "Shell settings skipped - housekeeping was not requested at build time"
    }
    Write-Step "Done"
    exit 0
}

# ------------------------------------------------------------------------------
# 0b. VirtIO guest tools - NOT here, and this line exists to say so
#
#     They were here for exactly one build, put first on purpose: the builder on
#     the Proxmox host cannot read this log until the QEMU guest agent answers,
#     the agent arrives with these tools, so the earlier they go in the sooner
#     follow_build prints real lines instead of a byte counter.
#
#     Measured on that build: the installer starts, shows its progress bar, and
#     then exits 1603 with every MSI rolled back. No qemu-ga service, no
#     vioserial service, and follow_build spent the whole build blind. An
#     installer bundle cannot run in specialize. See CLAUDE.md.
#
#     So it runs at the top of the first-boot pass instead, which is the
#     earliest point it works. -Phase All still does it here, because a by-hand
#     run is on a booted machine where it is fine.
# ------------------------------------------------------------------------------
if ($Phase -eq 'All') {
    Invoke-GuestToolsInstall
} else {
    Write-Step "VirtIO guest tools"
    Write-Skip "Not in specialize - an installer bundle exits 1603 there. The first-boot pass does it first."
}

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
# Defender. In the normal build this does NOT run here: -Phase Specialize
# skips it and the first-boot task calls -Phase FirstBoot for it alone,
# because it is a servicing operation that needs a reboot and must not run
# beside Setup's own. A by-hand run with -Phase All does it in place.
if ($Phase -eq 'All') {
    Invoke-DefenderRemoval
} else {
    Write-Step "Microsoft Defender"
    Write-Skip "Left to the first boot - it needs a reboot and must not run during Setup"
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
# 5b. IPv6
#
#     DisabledComponents is the documented switch, and 0xFF is the documented
#     value for "disable IPv6 on all interfaces and tunnels" while leaving the
#     protocol installed. Do not go looking for a way to remove it outright:
#     Microsoft does not support that and Windows components assume v6 is
#     present. Unbinding ms_tcpip6 as well covers anything that reads the
#     adapter binding rather than the policy value.
#
#     Only touched when the operator asked for it at build time. Windows ships
#     with IPv6 on, Microsoft recommends leaving it on, and for this project
#     there is a second reason in CLAUDE.md: a routable v6 prefix is the free
#     way around CGNAT, needing only an AAAA record and a firewall rule.
# ------------------------------------------------------------------------------
Write-Step "IPv6"
if ($cfg.DisableIPv6) {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 0xFF
    try {
        Disable-NetAdapterBinding -Name '*' -ComponentID 'ms_tcpip6' -ErrorAction Stop
        Write-Good "IPv6 unbound from every adapter"
    } catch {
        # Specialize may run before the adapters are enumerated. The policy
        # value above is the one that actually decides, so this is a note.
        Write-Skip "Could not unbind IPv6 from the adapters: $($_.Exception.Message)"
    }
    Write-Good "IPv6 disabled - chosen at build time. Takes effect at the next reboot."
} else {
    Write-Skip "Left enabled - the Windows default, and a routable v6 prefix is the free way past CGNAT"
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

Invoke-DefaultUserHive
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

# Edge's first-run experience: the full-screen "welcome, let's get you set up"
# takeover on first launch. Machine-wide policy, which is the whole point -
# unlike the shell settings it does not live in HKCU, so it cannot lose the
# race against the profile AutoLogon creates and needs no per-user second pass.
# The same three keys cschneegans/unattend-generator writes in its specialize
# phase. StartupBoost and BackgroundMode keep Edge out of memory on a box whose
# job is to be a gateway.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended' 'StartupBoostEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended' 'BackgroundModeEnabled' 0

# Do not reboot out from under a logged-on administrator. A gateway that
# reboots mid-session during Windows Update is a gateway nobody trusts.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1

# The Windows startup chime, which is separate from the system sounds silenced
# below and survives them.
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' 'DisableStartupSound' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides' 'UserSetting_DisableStartupSound' 1

# The Edge shortcut on the all-users desktop. The per-user copy is removed by
# -ShellForCurrentUser, because by the time this runs the profile already has
# its own inherited copy.
if (Test-Path -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk') {
    Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -Force -ErrorAction SilentlyContinue
    Write-Good "Removed the all-users Edge desktop shortcut"
}

# NumLock on at the logon screen. .DEFAULT is the hive the logon UI uses.
Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'

# Silence system sounds. Audio over RDP that only ever plays error dings is
# worth turning off.
#
# The scheme keys are absent on a fresh Server 2025 - a real build reported
# "Cannot find path 'HKEY_USERS\.DEFAULT\AppEvents\Schemes\Apps' because it
# does not exist". That is a Server install without the Desktop audio schemes
# populated, not a failure of anything, so it is a skip. A [fail] line here
# costs more than it is worth: it pushes the closing count above zero and sends
# the operator hunting for a problem that does not exist.
$soundKey = 'Registry::HKEY_USERS\.DEFAULT\AppEvents\Schemes\Apps'
if (-not (Test-Path -LiteralPath $soundKey)) {
    Write-Skip "No .DEFAULT sound schemes on this install - nothing to silence"
} else {
    try {
        Get-ChildItem -LiteralPath $soundKey -Recurse -ErrorAction Stop |
            Where-Object { $_.PSChildName -eq '.Current' } |
            ForEach-Object {
                Set-ItemProperty -LiteralPath $_.PSPath -Name '(Default)' -Value '' -ErrorAction SilentlyContinue
            }
        Write-Good "System sounds cleared in the .DEFAULT hive"
    } catch {
        Write-Bad "System sounds -- $($_.Exception.Message)"
    }
}

# Let the scripts this build relies on actually run.
#
# Set-ExecutionPolicy throws "Security error" when the policy is already fixed
# by Group Policy, which it is on a real Server 2025 build. Nothing is wrong and
# nothing can be done about it from here - and it does not matter, because every
# script this build launches is invoked with -ExecutionPolicy Bypass on its own
# command line, which outranks the machine policy anyway. Report what the policy
# actually is rather than calling an immovable setting a failure.
try {
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    Write-Good "Execution policy (LocalMachine) = RemoteSigned"
} catch {
    $effective = try { (Get-ExecutionPolicy -Scope LocalMachine).ToString() } catch { 'unknown' }
    Write-Skip "Execution policy is set by policy and cannot be changed here (it is $effective). Harmless - every script this build starts passes -ExecutionPolicy Bypass."
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
