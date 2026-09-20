<#
.SYNOPSIS
    Runs the scripts you supplied to windows-rdgw-vm.sh, one category at a time.

.DESCRIPTION
    windows-rdgw-vm.sh copies whatever you added during the build - written in
    its editor or imported from disk - onto the unattend CD, and the specialize
    pass lands it here:

        C:\Windows\Setup\Scripts\custom\System\
        C:\Windows\Setup\Scripts\custom\DefaultUser\
        C:\Windows\Setup\Scripts\custom\FirstLogon\
        C:\Windows\Setup\Scripts\custom\UserOnce\

    The category names and their timing come from the schneegans.de unattend
    generator, because that is the vocabulary most people arrive with:

        System       as SYSTEM on the first boot, before anyone logs on.
                     Invoke-GatewaySetup.ps1 calls this before it installs the
                     RD Gateway role, so a script here can prepare something
                     the gateway then uses - importing a certificate, say.

        DefaultUser  as SYSTEM with C:\Users\Default\NTUSER.DAT mounted.
                     Configure-Guest.ps1 calls this while it has the hive open.
                     Anything written there is inherited by profiles created
                     afterwards.

        FirstLogon   at the first interactive logon, elevated. Registered in
                     HKLM\...\RunOnce by the answer file.

        UserOnce     at each new user's first logon, in that user's own
                     context. Registered in the Default User hive's RunOnce by
                     Configure-Guest.ps1, so every profile created afterwards
                     inherits it.

    Within a category the files run in filename order, so 10-first.ps1 runs
    before 20-second.ps1. Four extensions are recognised:

        .ps1          powershell.exe -NoProfile -ExecutionPolicy Bypass -File
        .cmd  .bat    cmd.exe /c
        .reg          reg.exe import

    A script that fails, or that runs past -TimeoutSeconds, is logged and the
    rest carry on. This file always exits 0: a broken script of yours must not
    be able to strand the machine half built.

    Deliberately pure ASCII, targeting Windows PowerShell 5.1, matching the
    other three.

.PARAMETER Category
    Which of the four sets to run.

.PARAMETER HiveRoot
    Only meaningful with -Category DefaultUser. The reg.exe mount point of the
    Default User hive, for example HKU\rdgwDefault. A .reg file written for a
    logged-on user talks about HKEY_CURRENT_USER, and there is no current user
    at that point, so those lines are rewritten to point at the mounted hive
    before the file is imported.

.PARAMETER TimeoutSeconds
    How long a single script may run before it is killed. The System category
    runs inside the first-boot task that builds the gateway, so a script that
    hangs forever would otherwise stall the whole build.

.EXAMPLE
    .\Invoke-CustomScripts.ps1 -Category System

.EXAMPLE
    .\Invoke-CustomScripts.ps1 -Category DefaultUser -HiveRoot HKU\rdgwDefault
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('System', 'DefaultUser', 'FirstLogon', 'UserOnce')]
    [string] $Category,

    [string] $ScriptRoot = $PSScriptRoot,

    [string] $HiveRoot = '',

    [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Continue'

$LogPath = Join-Path $ScriptRoot 'rdgw-setup.log'
$script:LogWritable = $true

# UserOnce runs as whoever just logged on, who may have no business writing
# under C:\Windows. Say everything on the console regardless, and treat the
# shared log as a bonus - one refusal is enough to stop trying.
function Write-Line {
    param([string] $Message, [string] $Level = 'info')
    $line = "{0}  [{1}] custom/{2}: {3}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Category, $Message
    Write-Host $line
    if ($script:LogWritable) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII -ErrorAction Stop
        } catch {
            $script:LogWritable = $false
            Write-Host "        (log not writable from this account: $($_.Exception.Message))"
        }
    }
}

# Echo whatever the child wrote. Called on the normal path and on the timeout
# path, because the last thing a script printed before it hung is usually the
# line that explains the hang.
function Write-ChildOutput {
    param([string] $OutFile, [string] $ErrFile)
    foreach ($f in @($OutFile, $ErrFile)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if ((Get-Item -LiteralPath $f).Length -le 0) { continue }
        Get-Content -LiteralPath $f | ForEach-Object {
            if ($_ -ne '') { Write-Host "        $_" }
        }
    }
}

# Run one child process and wait, but not forever.
function Invoke-Child {
    param([string] $FilePath, [string[]] $ArgumentList, [string] $Label, [int] $Timeout)

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    # Start-Process joins ArgumentList with plain spaces and quotes nothing, so
    # a script at "C:\Windows\Setup\Scripts\custom\System\install cert.ps1"
    # reaches powershell.exe as -File C:\Windows\...\install and dies with
    # "does not have a '.ps1' extension". Quote what needs quoting first.
    $quoted = @()
    foreach ($a in $ArgumentList) {
        if ($a -match '\s' -and $a -notmatch '^".*"$') { $quoted += '"' + $a + '"' }
        else { $quoted += $a }
    }

    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $quoted `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -ErrorAction Stop

        # Reading Handle keeps the process handle open on the returned object.
        # Without it, Start-Process -PassThru hands back something whose
        # ExitCode reads back empty once the child is gone, and every script
        # looks like it failed.
        $null = $proc.Handle

        if (-not $proc.WaitForExit($Timeout * 1000)) {
            # Kill() on .NET Framework takes down this process only, not what it
            # started, and it returns before the OS has finished. Both matter: a
            # DefaultUser script killed while it still holds the mounted hive
            # would make Configure-Guest.ps1's reg unload fail and leave
            # NTUSER.DAT locked for the rest of setup.
            & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
            try {
                $proc.Kill()
            } catch {
                # It finished in the gap between the wait giving up and this
                # call. Nothing left to kill.
                Write-Verbose $_.Exception.Message
            }
            $null = $proc.WaitForExit(5000)
            Write-Line "$Label ran past $Timeout seconds and was killed" 'warn'
            Write-ChildOutput $outFile $errFile
            return
        }

        # The overload that takes a timeout can return before the redirected
        # streams have finished being written. The one that does not settles it.
        $proc.WaitForExit()

        Write-ChildOutput $outFile $errFile

        if ($proc.ExitCode -eq 0) {
            Write-Line "$Label ok"
        } else {
            Write-Line "$Label exited $($proc.ExitCode)" 'warn'
        }
    }
    catch {
        Write-Line "$Label could not be started: $($_.Exception.Message)" 'warn'
    }
    finally {
        foreach ($f in @($outFile, $errFile)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

# A .reg file aimed at HKEY_CURRENT_USER has to be re-aimed at the mounted
# hive, because nobody is logged on when the DefaultUser category runs. The
# rewritten copy is normalised to UTF-16, which reg.exe accepts whatever the
# original was saved as.
function Import-RegFile {
    param([System.IO.FileInfo] $File, [string] $HiveRoot, [int] $Timeout)

    $path = $File.FullName
    $label = $File.Name

    if ($Category -eq 'DefaultUser') {
        if ([string]::IsNullOrWhiteSpace($HiveRoot)) {
            Write-Line "$label wants a hive to write into but -HiveRoot was not given; importing as written" 'warn'
        }
        else {
            $target = $HiveRoot -replace '^HKU\\', 'HKEY_USERS\'
            try {
                $body = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
                # Only the bracketed key headers, including the [-HKEY...] form
                # that deletes a key. A blanket text replace would also rewrite
                # the literal string inside quoted REG_SZ data, where $target's
                # single backslashes are not the escaping .reg expects.
                $rewritten = $body -replace '(?m)^(\[-?)HKEY_CURRENT_USER', ('$1' + $target)
                $temp = Join-Path $env:TEMP ("rdgw-" + $File.BaseName + ".reg")
                Set-Content -LiteralPath $temp -Value $rewritten -Encoding Unicode -ErrorAction Stop
                Write-Line "$label rewritten for $target"
                Invoke-Child -FilePath 'reg.exe' -ArgumentList @('import', $temp) -Label $label -Timeout $Timeout
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                return
            }
            catch {
                Write-Line "$label could not be rewritten: $($_.Exception.Message)" 'warn'
                return
            }
        }
    }

    Invoke-Child -FilePath 'reg.exe' -ArgumentList @('import', $path) -Label $label -Timeout $Timeout
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
$dir = Join-Path (Join-Path $ScriptRoot 'custom') $Category

if (-not (Test-Path -LiteralPath $dir)) {
    # Nothing was supplied for this category. Not worth a line in the log.
    exit 0
}

# Sort on the leading number, not the text. Sort-Object Name puts 100- before
# 20-, which contradicts the filename-order promise as soon as a category holds
# more than nine scripts. Anything unnumbered sorts last, by name.
$files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.ps1', '.cmd', '.bat', '.reg') } |
    Sort-Object `
        @{ Expression = { if ($_.Name -match '^(\d+)') { [int]$Matches[1] } else { [int]::MaxValue } } }, `
        @{ Expression = { $_.Name } })

if ($files.Count -eq 0) {
    exit 0
}

# A DefaultUser .ps1 or .cmd runs as SYSTEM with nobody logged on, so HKCU:
# resolves to SYSTEM's own profile - the write succeeds, the log says ok, and
# nothing reaches any real profile. Only .reg files get rewritten for the hive,
# so tell the others where it is. Children inherit the environment.
if ($Category -eq 'DefaultUser' -and -not [string]::IsNullOrWhiteSpace($HiveRoot)) {
    $env:RDGW_HIVE_ROOT = $HiveRoot
    $env:RDGW_HIVE_PATH = 'Registry::' + ($HiveRoot -replace '^HKU\\', 'HKEY_USERS\')
    Write-Line "Default User hive is at $env:RDGW_HIVE_PATH - write there, not HKCU:"
}

Write-Line "running $($files.Count) script(s) from $dir"

foreach ($file in $files) {
    switch ($file.Extension) {
        '.ps1' {
            Invoke-Child -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file.FullName) `
                -Label $file.Name -Timeout $TimeoutSeconds
        }
        '.reg' {
            Import-RegFile -File $file -HiveRoot $HiveRoot -Timeout $TimeoutSeconds
        }
        default {
            Invoke-Child -FilePath 'cmd.exe' -ArgumentList @('/c', $file.FullName) -Label $file.Name -Timeout $TimeoutSeconds
        }
    }
}

Write-Line "finished"
exit 0
