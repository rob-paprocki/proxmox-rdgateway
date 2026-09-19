<#
.SYNOPSIS
    First-boot orchestrator for a VM built by windows-rdgw-vm.sh.

.DESCRIPTION
    Runs as SYSTEM from a scheduled task that fires at startup, and survives the
    reboot that installing the RD Gateway role demands.

    That reboot is the whole reason this file exists. Setup-RDGateway.ps1 stops
    and asks you to reboot and re-run with -SkipRoleInstall when
    Install-WindowsFeature reports RestartNeeded, and SetupComplete.cmd is not
    allowed to reboot and resume. So the work is split across boots and this
    script keeps the place:

        boot 1   apply Configure-Guest.ps1, install the RDS-Gateway role,
                 reboot if Windows asks for one
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

$TaskName = 'RDGW-FirstBoot'
$LogPath = Join-Path $ScriptRoot 'rdgw-setup.log'
$StatePath = Join-Path $ScriptRoot 'rdgw-state.json'
$ConfigPath = Join-Path $ScriptRoot 'rdgw-config.psd1'
$MaxBoots = 5

# ------------------------------------------------------------------------------
# Registration. Kept here so the schtasks arguments live next to the script they
# launch rather than buried in the answer file.
# ------------------------------------------------------------------------------
if ($Register) {
    $self = Join-Path $ScriptRoot 'Invoke-GatewaySetup.ps1'
    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`""
    & schtasks.exe /Create /TN $TaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR $action
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
function Write-Line {
    param([string] $Message, [string] $Level = 'info')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$stamp  [$Level] $Message" | Tee-Object -FilePath $LogPath -Append | Write-Host
}

function Get-State {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
        } catch {
            Write-Line "State file unreadable, starting over: $($_.Exception.Message)" 'warn'
        }
    }
    return [pscustomobject]@{
        Boots = 0
        GuestConfigured = $false
        RoleInstalled = $false
        GatewayConfigured = $false
    }
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
$cfg = Import-PowerShellDataFile -LiteralPath $ConfigPath

# --- 1. Guest settings -------------------------------------------------------
if (-not $state.GuestConfigured) {
    Write-Line "Applying guest configuration"
    try {
        & (Join-Path $ScriptRoot 'Configure-Guest.ps1') -ConfigPath $ConfigPath 2>&1 |
            Tee-Object -FilePath $LogPath -Append | Write-Host
        $state.GuestConfigured = $true
        Save-State $state
        Write-Line "Guest configuration applied"
    } catch {
        Write-Line "Configure-Guest.ps1 failed: $($_.Exception.Message)" 'warn'
        Write-Line "Continuing to the gateway role anyway - these settings are not required for it." 'warn'
        $state.GuestConfigured = $true
        Save-State $state
    }
} else {
    Write-Line "Guest configuration already applied on an earlier boot"
}

# --- 2. The RD Gateway role --------------------------------------------------
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

# --- 3. Gateway configuration ------------------------------------------------
$setup = Join-Path $ScriptRoot 'Setup-RDGateway.ps1'
if (-not (Test-Path -LiteralPath $setup)) {
    Stop-Here "Missing $setup. The unattend ISO did not copy cleanly."
}

$arguments = @{
    ExternalFqdn = $cfg.ExternalFqdn
    CertificateSource = $cfg.CertificateSource
    SkipRoleInstall = $true
}
if ($cfg.TargetMachines -and $cfg.TargetMachines.Count -gt 0) {
    $arguments['TargetMachines'] = $cfg.TargetMachines
    $arguments['ResourceScope'] = 'Listed'
}

Write-Line "Running Setup-RDGateway.ps1 -ExternalFqdn $($cfg.ExternalFqdn) -SkipRoleInstall"
if ($arguments.ContainsKey('TargetMachines')) {
    Write-Line "Target machines: $($cfg.TargetMachines -join ', ')"
} else {
    Write-Line "No target machines given - the RAP will be scoped to this server only."
}

try {
    & $setup @arguments 2>&1 | Tee-Object -FilePath $LogPath -Append | Write-Host
} catch {
    Stop-Here "Setup-RDGateway.ps1 failed: $($_.Exception.Message)"
}

# --- 4. Verify ---------------------------------------------------------------
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
