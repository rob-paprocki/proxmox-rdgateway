<#
.SYNOPSIS
    Reports what the unattended build actually did, against what it was asked to do.

.DESCRIPTION
    Read-only. Run it in the guest from an elevated PowerShell prompt when a
    build has finished and you are not sure everything took:

        powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Get-RDGWStatus.ps1

    It answers, in order, the questions that split the problem fastest:

      1. Did the unattend CD's files reach C:\Windows\Setup\Scripts at all?
      2. Was the first-boot task created, and did it run?
      3. How far did it get, and what did it say?
      4. For each setting you chose, is the machine actually in that state?
      5. Were your own scripts present, and did the runner log them?

    A mismatch in section 4 with a healthy log in section 3 means the setting
    was applied and something undid it, or the write silently failed. Nothing
    in section 1 means the CD never got copied and none of the rest ran.

    Deliberately pure ASCII, targeting Windows PowerShell 5.1, matching the rest.

.PARAMETER ScriptRoot
    Where the build's files were copied. Only change this if you moved them.

.PARAMETER LogLines
    How many lines of the tail of rdgw-setup.log to print. 0 prints none.
#>

[CmdletBinding()]
param(
    [string] $ScriptRoot = 'C:\Windows\Setup\Scripts',
    [int] $LogLines = 40
)

$ErrorActionPreference = 'Continue'

function Write-Head { param([string] $m) Write-Host "`n=== $m ===" }
function Write-Ok   { param([string] $m) Write-Host "    [ ok ] $m" }
function Write-No   { param([string] $m) Write-Host "    [ NO ] $m" }
function Write-Info { param([string] $m) Write-Host "           $m" }

# Compare what was asked for with what is true, and say which.
function Compare-Setting {
    param([string] $Name, $Wanted, $Actual, [string] $Note = '')
    $w = if ($null -eq $Wanted) { '(not in config)' } else { "$Wanted" }
    $a = if ($null -eq $Actual) { '(unreadable)' } else { "$Actual" }
    $line = "{0,-28} asked={1,-14} actual={2}" -f $Name, $w, $a
    if ($null -eq $Wanted) { Write-Info $line }
    elseif ("$Wanted" -eq "$Actual") { Write-Ok $line }
    else { Write-No $line }
    if ($Note) { Write-Info "    $Note" }
}

function Get-RegValue {
    param([string] $Path, [string] $Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

Write-Host "RD Gateway build status - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME"

# ------------------------------------------------------------------ 1. files
Write-Head "1. Did the unattend CD reach $ScriptRoot"

if (-not (Test-Path -LiteralPath $ScriptRoot)) {
    Write-No "$ScriptRoot does not exist."
    Write-Info "The specialize xcopy never ran or never matched a drive. Nothing"
    Write-Info "below could have happened. Check C:\Windows\Panther\setupact.log."
} else {
    foreach ($f in 'rdgw-config.psd1', 'Invoke-GatewaySetup.ps1', 'Configure-Guest.ps1',
                   'Setup-RDGateway.ps1', 'Invoke-CustomScripts.ps1') {
        $p = Join-Path $ScriptRoot $f
        if (Test-Path -LiteralPath $p) { Write-Ok $f } else { Write-No "$f is MISSING" }
    }
    $customDir = Join-Path $ScriptRoot 'custom'
    if (Test-Path -LiteralPath $customDir) {
        $n = @(Get-ChildItem -LiteralPath $customDir -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Ok "custom\ present, $n file(s)"
        Get-ChildItem -LiteralPath $customDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $files = @(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue)
            Write-Info ("  {0}: {1}" -f $_.Name, $(if ($files) { ($files | ForEach-Object { $_.Name }) -join ', ' } else { '(empty)' }))
        }
    } else {
        Write-Info "custom\ is not present - no scripts of your own were put on the CD."
    }
}

# ------------------------------------------------------------------ 2. config
Write-Head "2. What the build was asked for"

$cfg = $null
$cfgPath = Join-Path $ScriptRoot 'rdgw-config.psd1'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Import-PowerShellDataFile -LiteralPath $cfgPath -ErrorAction Stop
        foreach ($k in ($cfg.Keys | Sort-Object)) {
            $v = $cfg[$k]
            if ($v -is [array]) { $v = if ($v.Count) { $v -join ', ' } else { '(none)' } }
            Write-Info ("{0,-22} {1}" -f $k, $v)
        }
    } catch {
        Write-No "rdgw-config.psd1 will not parse: $($_.Exception.Message)"
        Write-Info "Everything downstream of this would have died here."
    }
} else {
    Write-No "rdgw-config.psd1 is missing - nothing knew what you asked for."
}

# -------------------------------------------------------------------- 3. task
Write-Head "3. The first-boot task and how far it got"

$task = & schtasks.exe /Query /TN RDGW-FirstBoot /FO LIST /V 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "RDGW-FirstBoot is still registered - it has NOT finished cleanly"
    $task | Where-Object { $_ -match '^(Status|Last Run Time|Last Result|Task To Run|Run As User|Scheduled Task State):' } |
        ForEach-Object { Write-Info $_.Trim() }
} else {
    Write-Info "RDGW-FirstBoot is not registered."
    Write-Info "That is what success looks like - it deletes itself when it finishes."
    Write-Info "It is also what never-created looks like. Section 4 tells them apart."
}

$statePath = Join-Path $ScriptRoot 'rdgw-state.json'
if (Test-Path -LiteralPath $statePath) {
    Write-Ok "rdgw-state.json:"
    try {
        $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $st.PSObject.Properties | ForEach-Object { Write-Info ("  {0,-20} {1}" -f $_.Name, $_.Value) }
    } catch { Write-No "  unreadable: $($_.Exception.Message)" }
} else {
    Write-No "rdgw-state.json is missing - the task never ran even once."
}

# --------------------------------------------------------------------- 4. log
Write-Head "4. The log"

$logPath = Join-Path $ScriptRoot 'rdgw-setup.log'
if (-not (Test-Path -LiteralPath $logPath)) {
    Write-No "rdgw-setup.log does not exist. The task never started."
    Write-Info "Check Panther: Select-String -Path C:\Windows\Panther\setupact.log -Pattern 'RunSynchronous|xcopy'"
} else {
    $log = Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue
    Write-Ok "$($log.Count) lines, last written $((Get-Item -LiteralPath $logPath).LastWriteTime)"

    $fails = @($log | Where-Object { $_ -match '\[(fail|error|warn)\]' })
    if ($fails.Count) {
        Write-No "$($fails.Count) warning/failure line(s):"
        $fails | Select-Object -Last 25 | ForEach-Object { Write-Info $_ }
    } else {
        Write-Ok "no [fail], [error] or [warn] lines"
    }

    $custom = @($log | Where-Object { $_ -match 'custom/' })
    if ($custom.Count) {
        Write-Ok "the custom-script runner logged $($custom.Count) line(s):"
        $custom | Select-Object -First 20 | ForEach-Object { Write-Info $_ }
    } else {
        Write-No "nothing from the custom-script runner - it never ran, or found nothing to run"
    }

    if ($log -match 'First-boot setup finished\.') { Write-Ok "log ends with 'First-boot setup finished.'" }
    else { Write-No "log does not contain 'First-boot setup finished.' - it stopped early" }

    if ($LogLines -gt 0) {
        Write-Info ""
        Write-Info "--- last $LogLines lines ---"
        $log | Select-Object -Last $LogLines | ForEach-Object { Write-Info $_ }
    }
}

# ---------------------------------------------------------- 5. asked vs actual
Write-Head "5. Asked for, versus what the machine is actually doing"

$pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

# Defender. Removing the feature is the supported route on Server; the service
# start type is not, and Tamper Protection blocks writing it.
$defFeature = $null
try {
    Import-Module ServerManager -ErrorAction SilentlyContinue
    $defFeature = (Get-WindowsFeature -Name Windows-Defender -ErrorAction Stop).Installed
} catch { Write-Verbose $_.Exception.Message }
$defSvc = (Get-Service -Name WinDefend -ErrorAction SilentlyContinue)
$defMode = $null
try { $defMode = (Get-MpComputerStatus -ErrorAction Stop).AMRunningMode } catch { Write-Verbose $_.Exception.Message }

Compare-Setting 'DisableDefender' $(if ($cfg) { $cfg.DisableDefender } else { $null }) `
                $(if ($null -eq $defFeature) { $null } else { -not $defFeature }) `
                "feature installed=$defFeature  WinDefend=$(if ($defSvc) { "$($defSvc.Status)/$($defSvc.StartType)" } else { 'absent' })  AMRunningMode=$(if ($defMode) { $defMode } else { 'n/a' })"

Compare-Setting 'DisableUac' $(if ($cfg) { $cfg.DisableUac } else { $null }) `
                $((Get-RegValue $pol 'EnableLUA') -eq 0)

Compare-Setting 'DisableCad' $(if ($cfg) { $cfg.DisableCad } else { $null }) `
                $((Get-RegValue $pol 'DisableCAD') -eq 1)

$vbs = $null
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    $vbs = ($dg.SecurityServicesRunning -contains 2)
} catch { Write-Verbose $_.Exception.Message }
Compare-Setting 'DisableCoreIsolation' $(if ($cfg) { $cfg.DisableCoreIsolation } else { $null }) `
                $(if ($null -eq $vbs) { $null } else { -not $vbs }) `
                "HVCI running=$vbs"

Compare-Setting 'DisableIPv6' $(if ($cfg) { $cfg.DisableIPv6 } else { $null }) `
                $((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents') -eq 0xFF)

Compare-Setting 'BlankPassword' $(if ($cfg) { $cfg.BlankPassword } else { $null }) `
                $((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LimitBlankPasswordUse') -eq 0)

$acct = & net.exe accounts 2>&1
$thr = ($acct | Where-Object { $_ -match 'Lockout threshold' }) -replace '.*:\s*', ''
Compare-Setting 'LockoutThreshold' $(if ($cfg) { $cfg.LockoutThreshold } else { $null }) `
                $(if ($thr -match '^\d+$') { [int]$thr } elseif ($thr -match 'Never') { 0 } else { $thr })

Compare-Setting 'ApplyTweaks' $(if ($cfg) { $cfg.ApplyTweaks } else { $null }) `
                $((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') -eq 1) `
                "checked via LongPathsEnabled, one of the housekeeping settings"

if ($cfg -and $cfg.AccountName) {
    $u = Get-LocalUser -Name $cfg.AccountName -ErrorAction SilentlyContinue
    if ($u) { Write-Ok "local account '$($cfg.AccountName)' exists, enabled=$($u.Enabled)" }
    else { Write-No "local account '$($cfg.AccountName)' does not exist" }
}

# ----------------------------------------------------------------- 6. gateway
Write-Head "6. The gateway itself"

$feat = $null
try { $feat = (Get-WindowsFeature -Name RDS-Gateway -ErrorAction Stop).Installed } catch { Write-Verbose $_.Exception.Message }
if ($feat) { Write-Ok "RDS-Gateway role is installed" }
elseif ($null -eq $feat) { Write-Info "could not read the RDS-Gateway feature state" }
else { Write-No "RDS-Gateway role is NOT installed" }

$svc = Get-Service -Name TSGateway -ErrorAction SilentlyContinue
if ($svc) { Write-Ok "TSGateway service is $($svc.Status)" } else { Write-No "TSGateway service does not exist" }

try {
    $cap = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TSGatewayConnectionAuthorizationPolicy -ErrorAction Stop
    foreach ($c in $cap) { Write-Info "CAP '$($c.Name)' UserGroupNames: $($c.UserGroupNames -join ', ')" }
} catch { Write-Info "no CAP readable: $($_.Exception.Message)" }

try {
    $rap = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TSGatewayResourceAuthorizationPolicy -ErrorAction Stop
    foreach ($r in $rap) { Write-Info "RAP '$($r.Name)' type=$($r.ResourceGroupType) group=$($r.ResourceGroupName)" }
} catch { Write-Info "no RAP readable: $($_.Exception.Message)" }

Write-Host "`nDone. Lines marked [ NO ] are where what you asked for and what happened differ."
