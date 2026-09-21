<#
.SYNOPSIS
    First-boot orchestrator for a VM built by windows-rdgw-vm.sh.

.DESCRIPTION
    Runs as SYSTEM from a scheduled task that fires at startup, and survives the
    reboot that installing the RD Gateway role demands.

    That reboot is why this file exists. Setup-RDGateway.ps1 stops and asks you
    to reboot and re-run with -SkipRoleInstall when Install-WindowsFeature
    reports RestartNeeded, and SetupComplete.cmd is not allowed to reboot and
    resume. So the work is split across boots and this script keeps the place:

        boot 1   apply Configure-Guest.ps1, run any custom System scripts,
                 install the RDS-Gateway role, reboot if Windows asks for one
        boot 2   configure the gateway (Setup-RDGateway.ps1 -SkipRoleInstall),
                 verify, clean up, unregister the task

    If nothing needs a reboot it finishes on the first boot. If something goes
    wrong it stops after MaxBoots rather than looping forever, leaves the task
    registered and writes why to the log.

    Everything it does is appended to:

        C:\Windows\Setup\Scripts\rdgw-setup.log

    Deliberately pure ASCII, targeting Windows PowerShell 5.1.

.PARAMETER Register
    Register the startup scheduled task and exit. Called once from the answer
    file during the specialize pass; not used afterwards.
#>

[CmdletBinding()]
param(
    [switch] $Register,
    [string] $ScriptRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot came back EMPTY on a real Windows Server 2025 build, and that
# one empty string cost three failed builds. Join-Path throws on an empty
# -Path, so the script died on the very next line - before the log existed,
# before the task was registered, before it could say a single word about why.
# From the outside it looked exactly like "the customizations silently didn't
# apply": scripts present on disk, no task, no log, no clue.
#
# Observed, not theorised: running this by hand on that guest reproduced it,
# and adding -ScriptRoot made the same command succeed immediately. Why the
# variable is empty there is still unexplained - it is populated on Windows 11
# PowerShell 5.1 for both absolute and relative -File, with LF or CRLF endings,
# all of which were tested. So do not trust it. Take the first source that
# actually yields something, and say so if we had to fall back.
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = 'C:\Windows\Setup\Scripts'
}

$TaskName = 'RDGW-FirstBoot'
$LogPath = Join-Path $ScriptRoot 'rdgw-setup.log'
$StatePath = Join-Path $ScriptRoot 'rdgw-state.json'
$ConfigPath = Join-Path $ScriptRoot 'rdgw-config.psd1'
$MaxBoots = 5

# Append one line to the shared log, in ASCII.
#
# The encoding is the point. This file used to write with
# "$line | Tee-Object -FilePath $LogPath -Append", and Tee-Object on Windows
# PowerShell 5.1 writes UTF-16. Configure-Guest.ps1 and Invoke-CustomScripts.ps1
# both append with -Encoding ASCII, so the one log ended up half UTF-16 and half
# ASCII - and on a real build findstr refused to read it:
#
#     FINDSTR: Warning - input file rdgw-setup.log is in Unicode format.
#
# A log the operator cannot grep is most of the way to no log at all, which is
# the failure this whole file exists to avoid. Everything writes ASCII now.
# Defined above the -Register block on purpose: PowerShell resolves functions at
# run time in script order, so a helper defined further down would not exist yet
# when that block runs.
function Add-LogLine {
    param([string] $Message, [string] $Level = 'info')
    $line = "{0}  [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII -ErrorAction Stop
    } catch {
        Write-Host "    (log not writable: $($_.Exception.Message))"
    }
}

# ------------------------------------------------------------------------------
# Registration. Kept here so the schtasks arguments live next to the script they
# launch rather than buried in the answer file.
#
# This runs once, from the answer file's specialize pass, and it used to be the
# quietest code in the repo: it created the task, trusted schtasks, and exited.
# When it failed there was nothing to find. It now writes to the same log as
# everything else and, more importantly, reads the task back before claiming
# success - because "schtasks said 0" and "the task exists" turned out not to
# be the same question.
# ------------------------------------------------------------------------------
if ($Register) {
    $self = Join-Path $ScriptRoot 'Invoke-GatewaySetup.ps1'
    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -ScriptRoot `"$ScriptRoot`""

    Add-LogLine "Registering '$TaskName' from $ScriptRoot"

    & schtasks.exe /Create /TN $TaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR $action
    $createRc = $LASTEXITCODE

    & schtasks.exe /Query /TN $TaskName 2>&1 | Out-Null
    $exists = ($LASTEXITCODE -eq 0)

    # Two HKLM RunOnce values, which fire at the first interactive logon -
    # including the AutoLogon account. They used to be two more
    # RunSynchronousCommand entries in the answer file, and that broke a build:
    # a <Path> is capped at 259 characters and those commands were 273 and 266.
    # Windows does not report a length problem, it just refuses the whole
    # specialize pass with 0x80220005. Here there is no limit, and a failure is
    # visible in the log instead of being a dialog twenty minutes later.
    #
    # The shell one is unconditional: Configure-Guest.ps1 reads ApplyTweaks
    # itself and writes a "skipped" line if it was not asked for, which is more
    # evidence than silence. The custom-scripts one only goes in if there is
    # something to run.
    $runOnce = 'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $pwsh = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'

    $wanted = @{
        RDGWShell = "$pwsh `"$ScriptRoot\Configure-Guest.ps1`" -ShellForCurrentUser -ScriptRoot `"$ScriptRoot`""
    }
    $firstLogonDir = Join-Path $ScriptRoot 'custom\FirstLogon'
    if (Test-Path -LiteralPath $firstLogonDir) {
        if (@(Get-ChildItem -LiteralPath $firstLogonDir -File -ErrorAction SilentlyContinue).Count -gt 0) {
            $wanted['RDGWFirstLogon'] =
                "$pwsh `"$ScriptRoot\Invoke-CustomScripts.ps1`" -Category FirstLogon -ScriptRoot `"$ScriptRoot`""
        }
    }

    foreach ($name in $wanted.Keys) {
        try {
            if (-not (Test-Path -LiteralPath $runOnce)) {
                New-Item -Path $runOnce -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $runOnce -Name $name -Value $wanted[$name] `
                -PropertyType String -Force -ErrorAction Stop | Out-Null
            Add-LogLine "RunOnce '$name' registered for the first interactive logon"
        } catch {
            Add-LogLine "RunOnce '$name' could not be registered: $($_.Exception.Message)" 'warn'
        }
    }

    if ($exists) {
        Add-LogLine "'$TaskName' registered and read back - first boot will run it"
        exit 0
    }

    Add-LogLine "'$TaskName' was NOT created (schtasks exit $createRc). Nothing will configure this machine. Run this by hand, elevated: powershell -NoProfile -ExecutionPolicy Bypass -File $self -Register" 'error'
    exit 1
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
function Write-Line {
    param([string] $Message, [string] $Level = 'info')
    Add-LogLine $Message $Level
}

function Get-State {
    $state = [pscustomobject]@{
        Boots = 0
        GuestConfigured = $false
        GuestRebootDone = $false
        SystemScriptsRun = $false
        RoleInstalled = $false
        GatewayConfigured = $false
    }
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $saved = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            # Copy across only the fields we recognise, so a state file left by
            # an older copy of this script still loads instead of starting the
            # boot count over.
            foreach ($name in $state.PSObject.Properties.Name) {
                if ($saved.PSObject.Properties[$name]) { $state.$name = $saved.$name }
            }
        } catch {
            Write-Line "State file unreadable, starting over: $($_.Exception.Message)" 'warn'
        }
    }
    return $state
}

function Save-State {
    param($State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding ASCII
}

# Component Based Servicing is the key that matters after a feature install;
# the Windows Update one is checked because updates can land in the same window.
#
# PendingFileRenameOperations is deliberately NOT checked. It is frequently set
# on a freshly installed Windows for reasons that have nothing to do with us,
# and it does not reliably clear on reboot - testing it would risk rebooting on
# every pass until the boot limit stopped us.
function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) { return $true }
    }
    return $false
}

function Stop-Here {
    param([string] $Reason)
    Write-Line $Reason 'error'
    Write-Line "Stopping. The scheduled task '$TaskName' is still registered and will try again on the next boot." 'error'
    Write-Line "To finish by hand: powershell -File $ScriptRoot\Setup-RDGateway.ps1 -ExternalFqdn <fqdn> -SkipRoleInstall" 'error'
    exit 1
}

function Complete-Setup {
    param($State)

    # The answer file holds the local administrator password. Windows caches it
    # here for the length of Setup and it is no longer needed.
    foreach ($leftover in 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\autounattend.xml') {
        if (Test-Path -LiteralPath $leftover) {
            try {
                Remove-Item -LiteralPath $leftover -Force -ErrorAction Stop
                Write-Line "Removed cached answer file $leftover"
            } catch {
                Write-Line "Could not remove $leftover : $($_.Exception.Message)" 'warn'
            }
        }
    }

    $State.GatewayConfigured = $true
    Save-State $State

    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    Write-Line "Unregistered scheduled task '$TaskName'"
    Write-Line "First-boot setup finished."
    exit 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
$state = Get-State
$state.Boots = [int] $state.Boots + 1
Save-State $state

Write-Line "---- RDGW first-boot pass $($state.Boots) of $MaxBoots ----"

if ($state.GatewayConfigured) {
    Write-Line "Already finished on an earlier boot. Nothing to do."
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    exit 0
}

if ($state.Boots -gt $MaxBoots) {
    Stop-Here "Reached the $MaxBoots boot limit without finishing. Read the log above for the last real error."
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-Here "Missing $ConfigPath. The unattend ISO did not copy cleanly."
}
try {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigPath -ErrorAction Stop
} catch {
    # Without this the task dies on a raw parse exception and the log says
    # nothing at all, which is the opposite of what this file exists for.
    Stop-Here "$ConfigPath could not be parsed: $($_.Exception.Message)"
}

# --- 1. Guest settings -------------------------------------------------------
if (-not $state.GuestConfigured) {
    Write-Line "Applying guest configuration"
    try {
        # No pipe and no Tee-Object: Configure-Guest.ps1 appends to the same log
        # itself. It has to, because everything it prints goes to the
        # information stream, which "2>&1 | Tee-Object" does not carry - that is
        # how its per-setting results went missing for the whole of this file's
        # existence.
        & (Join-Path $ScriptRoot 'Configure-Guest.ps1') -ConfigPath $ConfigPath -LogPath $LogPath
        $state.GuestConfigured = $true
        Save-State $state
        Write-Line "Configure-Guest.ps1 finished - read its [ ok ] and [fail] lines above"
    } catch {
        Write-Line "Configure-Guest.ps1 failed: $($_.Exception.Message)" 'warn'
        Write-Line "Continuing to the gateway role anyway - these settings are not required for it." 'warn'
        $state.GuestConfigured = $true
        Save-State $state
    }
} else {
    Write-Line "Guest configuration already applied on an earlier boot"
}

# Removing the Windows-Defender feature leaves a reboot pending, and handing a
# pending reboot to Install-WindowsFeature is how you get "a system reboot is
# required" instead of a gateway. Take it here, at most once.
if (-not $state.GuestRebootDone -and (Test-PendingReboot)) {
    $state.GuestRebootDone = $true
    Save-State $state
    Write-Line "Guest configuration left a reboot pending. Rebooting before the role install."
    Restart-Computer -Force
    exit 0
}

# --- 2. Your own System scripts ----------------------------------------------
#
# Ahead of the role install, so a script here can put something in place that
# the gateway then uses - importing a certificate into LocalMachine\My, say.
# Invoke-CustomScripts.ps1 already logs and swallows a script that fails or
# hangs; this catch is for the runner itself. Either way the gateway still
# gets built.
if (-not $state.SystemScriptsRun) {
    $customRunner = Join-Path $ScriptRoot 'Invoke-CustomScripts.ps1'
    if (Test-Path -LiteralPath $customRunner) {
        try {
            & $customRunner -Category System
        } catch {
            Write-Line "Custom System scripts failed: $($_.Exception.Message)" 'warn'
        }
        $state.SystemScriptsRun = $true
        Save-State $state
    } else {
        # Do not latch. The runner is one of the four files the CD carries as a
        # unit, so a missing one means the copy was incomplete - say so, and let
        # the next boot try again rather than silently never running the
        # operator's scripts.
        Write-Line "Invoke-CustomScripts.ps1 is missing from $ScriptRoot - System scripts skipped, will retry next boot" 'warn'
    }
}

# --- 3. The RD Gateway role --------------------------------------------------
#
# The reboot is only considered when this pass is the one that installed the
# role. If the role was already there when we started, a pending-reboot flag is
# somebody else's business and rebooting for it would risk a loop.
$installedNow = $false
$feature = Get-WindowsFeature -Name RDS-Gateway
if (-not $feature.Installed) {
    Write-Line "Installing the RDS-Gateway role. This pulls in IIS and NPS and takes a few minutes."
    try {
        $install = Install-WindowsFeature -Name RDS-Gateway -IncludeManagementTools
        if (-not $install.Success) {
            Stop-Here "Install-WindowsFeature failed with exit code $($install.ExitCode)."
        }
        $installedNow = $true
        Write-Line "RDS-Gateway installed"
    } catch {
        Stop-Here "Install-WindowsFeature threw: $($_.Exception.Message)"
    }
} else {
    Write-Line "RDS-Gateway already installed"
}
$state.RoleInstalled = $true
Save-State $state

if ($installedNow -and (Test-PendingReboot)) {
    Write-Line "Windows wants a reboot before the role is usable. Rebooting; this task runs again at startup."
    Restart-Computer -Force
    exit 0
}

# --- 4. Gateway configuration ------------------------------------------------
$setup = Join-Path $ScriptRoot 'Setup-RDGateway.ps1'
if (-not (Test-Path -LiteralPath $setup)) {
    Stop-Here "Missing $setup. The unattend ISO did not copy cleanly."
}

# The scope is whatever was picked in the builder, passed through rather than
# guessed at from whether a list happens to be present. An older config file
# without the field falls back to the narrowest setting.
$scope = if ($cfg.ResourceScope) { $cfg.ResourceScope } else { 'ThisServerOnly' }

$arguments = @{
    ExternalFqdn = $cfg.ExternalFqdn
    CertificateSource = $cfg.CertificateSource
    ResourceScope = $scope
    SkipRoleInstall = $true
}
if ($cfg.TargetMachines -and $cfg.TargetMachines.Count -gt 0) {
    $arguments['TargetMachines'] = $cfg.TargetMachines
}

Write-Line "Running Setup-RDGateway.ps1 -ExternalFqdn $($cfg.ExternalFqdn) -ResourceScope $scope -SkipRoleInstall"
switch ($scope) {
    'AnyResource' {
        Write-Line "Resource scope: any machine this server can reach."
    }
    'Listed' {
        Write-Line "Resource scope: this server plus $($cfg.TargetMachines -join ', ')"
    }
    default {
        Write-Line "Resource scope: this server only."
    }
}

try {
    # *>&1, not 2>&1. Setup-RDGateway.ps1 prints with Write-Host, which goes to
    # the information stream, and 2>&1 merges only the error stream - the exact
    # mistake that kept Configure-Guest.ps1's output out of this log for the
    # whole life of that file. And Add-LogLine rather than Tee-Object, so what
    # lands here is ASCII like everything else rather than UTF-16.
    & $setup @arguments *>&1 | ForEach-Object { Add-LogLine "  $_" }
} catch {
    Stop-Here "Setup-RDGateway.ps1 failed: $($_.Exception.Message)"
}

# --- 5. Verify ---------------------------------------------------------------
$svc = Get-Service -Name TSGateway -ErrorAction SilentlyContinue
if (-not $svc) {
    Stop-Here "The TSGateway service does not exist. Setup-RDGateway.ps1 did not complete."
}
if ($svc.Status -ne 'Running') {
    Write-Line "TSGateway is $($svc.Status). Starting it." 'warn'
    try {
        Start-Service -Name TSGateway -ErrorAction Stop
    } catch {
        Stop-Here "TSGateway would not start: $($_.Exception.Message)"
    }
}
Write-Line "TSGateway is running"

# The one thing CLAUDE.md says to check by hand after the first real run.
try {
    $cap = Get-CimInstance -Namespace root/cimv2/TerminalServices `
        -ClassName Win32_TSGatewayConnectionAuthorizationPolicy -ErrorAction Stop
    Write-Line "CAP UserGroupNames readback: $($cap.UserGroupNames -join ', ')"
} catch {
    Write-Line "Could not read the CAP back: $($_.Exception.Message)" 'warn'
}

Complete-Setup $state
