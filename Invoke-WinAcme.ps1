<#
.SYNOPSIS
    Installs win-acme on the gateway and, optionally, requests the certificate.

.DESCRIPTION
    The self-signed certificate that Setup-RDGateway.ps1 generates works, and
    every client rejects it until somebody imports it by hand. That is fine for
    proving the gateway runs and useless for the phones and locked-down laptops
    this project exists to serve, so this script fetches win-acme and points it
    at Let's Encrypt.

    It runs in one of two modes, chosen at build time:

        Stage   download win-acme, write request-certificate.cmd with the
                hostname, the email and the RD Gateway install script already
                filled in, and stop. You run one command and pass the token.

        Run     the same, and then run it, with the token that came from the
                build. Used when the operator accepted having that token on
                the unattend CD.

    Both modes write the SAME request-certificate.cmd and Run mode executes
    exactly that file, so the path the operator takes by hand is the path that
    was exercised automatically. The token is passed as argument 1 rather than
    baked into the file, so it is never written to disk here.

    This runs AFTER Setup-RDGateway.ps1, because ImportRDGateway.ps1 sets
    RDS:\GatewayServer\SSLCertificate\Thumbprint and that path does not exist
    until the RDS-Gateway role does. A failure here is a warning, never a
    failure of the build: the gateway is already listening on the self-signed
    certificate, and a gateway clients distrust beats a gateway that is down.

    Two downloads, both pinned to one version:

        win-acme.v<ver>.x64.pluggable.zip     the program
        plugin.validation.dns.cloudflare...   the Cloudflare DNS plugin

    The pluggable build is required. The trimmed build cannot load external
    plugins and every DNS provider is an external plugin, so trimmed plus
    "--validation cloudflare" fails at run time with an unhelpful message.

    Deliberately pure ASCII, targeting Windows PowerShell 5.1, matching the
    rest of this repo.

.PARAMETER Mode
    Stage or Run. See above.

.PARAMETER Hostname
    What the certificate is for. A wildcard is the default the builder offers,
    because a certificate naming the gateway publishes that name to the
    Certificate Transparency logs permanently.

.PARAMETER CloudflareToken
    Only used by Run, and only passed to win-acme as an argument.
#>

[CmdletBinding()]
param(
    [ValidateSet('Stage', 'Run')]
    [string] $Mode = 'Stage',

    [string] $Hostname = '',
    [string] $Email = '',
    [string] $CloudflareToken = '',
    [string] $Version = '2.2.9.1701',
    [string] $InstallDir = 'C:\win-acme',

    # Never a Join-Path in a param default. See CLAUDE.md: on a real build
    # $PSScriptRoot came back empty and Join-Path throws on an empty -Path,
    # from inside parameter binding, where no catch helps.
    [string] $ScriptRoot = 'C:\Windows\Setup\Scripts',
    [string] $LogPath = '',
    [string] $ConfigPath = ''
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = 'C:\Windows\Setup\Scripts' }
if ([string]::IsNullOrWhiteSpace($LogPath))    { $LogPath = Join-Path $ScriptRoot 'rdgw-setup.log' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'rdgw-config.psd1' }

$script:LogPath = $LogPath
$script:LogWritable = $true

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
function Write-Warn { param([string] $m) Write-Line "    [warn] $m" }

Write-Step "Certificate from Let's Encrypt (win-acme, mode $Mode)"

if ([string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Skip "No certificate hostname was chosen at build time - staying on the self-signed one"
    return
}

# PowerShell 5.1 still negotiates TLS 1.0 by default on some builds, and
# GitHub has not accepted that for years. One line, and it is the difference
# between a download and an unexplained "could not create SSL/TLS channel".
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warn "Could not force TLS 1.2: $($_.Exception.Message)"
}
# Invoke-WebRequest draws a progress bar that costs more than the transfer.
$ProgressPreference = 'SilentlyContinue'

$base    = "https://github.com/win-acme/win-acme/releases/download/v$Version"
$appZip  = "win-acme.v$Version.x64.pluggable.zip"
$cfZip   = "plugin.validation.dns.cloudflare.v$Version.zip"
$wacs    = Join-Path $InstallDir 'wacs.exe'
$rdScript = Join-Path $InstallDir 'Scripts\ImportRDGateway.ps1'

function Get-Zip {
    param([string] $Name, [string] $Destination)
    $url = "$base/$Name"
    $tmp = Join-Path $env:TEMP $Name
    # Print every URL before touching it. Same contract as the builder.
    Write-Line "    fetching $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        Expand-Archive -LiteralPath $tmp -DestinationPath $Destination -Force -ErrorAction Stop
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Warn "$Name failed: $($_.Exception.Message)"
        return $false
    }
}

if (Test-Path -LiteralPath $wacs) {
    Write-Good "win-acme is already in $InstallDir"
} else {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    if (-not (Get-Zip -Name $appZip -Destination $InstallDir)) {
        Write-Warn "win-acme was not installed. The gateway keeps its self-signed certificate."
        Write-Warn "Install it by hand from https://www.win-acme.com/ and see README.md Phase 4."
        return
    }
    if (-not (Get-Zip -Name $cfZip -Destination $InstallDir)) {
        Write-Warn "The Cloudflare DNS plugin did not download, so --validation cloudflare will not resolve."
        Write-Warn "Fetch $base/$cfZip by hand into $InstallDir."
    }
    Write-Good "win-acme $Version installed to $InstallDir"
}

# The RD Gateway install script ships in the release zip. Fetch it if this
# build of the zip ever stops carrying it, rather than failing later with
# "script not found" from inside win-acme.
if (-not (Test-Path -LiteralPath $rdScript)) {
    $scriptDir = Split-Path -Parent $rdScript
    if (-not (Test-Path -LiteralPath $scriptDir)) {
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    }
    $src = 'https://raw.githubusercontent.com/win-acme/win-acme/main/dist/Scripts/ImportRDGateway.ps1'
    Write-Line "    fetching $src"
    try {
        Invoke-WebRequest -Uri $src -OutFile $rdScript -UseBasicParsing -ErrorAction Stop
        Write-Good "ImportRDGateway.ps1 fetched"
    } catch {
        Write-Warn "ImportRDGateway.ps1 is missing and could not be fetched: $($_.Exception.Message)"
        Write-Warn "win-acme will get a certificate but nothing will bind it to the gateway."
    }
} else {
    Write-Good "ImportRDGateway.ps1 present"
}

# One file, used by both modes. The token is argument 1, so running this by
# hand and running it from here execute the same thing and neither writes the
# token to disk.
$runner = Join-Path $InstallDir 'request-certificate.cmd'
$cmd = @(
    '@echo off',
    "REM Requests a Let's Encrypt certificate for $Hostname and binds it to the",
    'REM RD Gateway. Generated by windows-rdgw-vm.sh. Renewals are handled by the',
    'REM scheduled task win-acme registers; you do not run this again.',
    'REM',
    'REM   request-certificate.cmd <cloudflare-api-token>',
    '',
    'if "%~1"=="" (',
    '  echo Pass your Cloudflare API token ^(scoped Zone:DNS:Edit^) as argument 1.',
    '  echo   request-certificate.cmd YOUR_TOKEN_HERE',
    '  exit /b 1',
    ')',
    '',
    ('"' + $wacs + '" --source manual --host "' + $Hostname + '" --accepttos' +
     ' --emailaddress "' + $Email + '"' +
     ' --validation cloudflare --cloudflareapitoken "%~1"' +
     ' --store certificatestore' +
     ' --installation script --script "' + $rdScript + '"' +
     ' --scriptparameters "{CertThumbprint}"' +
     ' --setuptaskscheduler')
) -join "`r`n"

try {
    Set-Content -LiteralPath $runner -Value $cmd -Encoding ASCII -ErrorAction Stop
    Write-Good "Wrote $runner"
} catch {
    Write-Warn "Could not write $runner : $($_.Exception.Message)"
    return
}

if ($Mode -eq 'Stage') {
    Write-Good "Staged. One command left, from an elevated prompt on this machine:"
    Write-Line "           $runner <your-cloudflare-api-token>"
    Write-Line "           (token needs Zone:DNS:Edit on the zone holding $Hostname)"
    Write-Line "           It binds the certificate and schedules its own renewals."
    return
}

if ([string]::IsNullOrWhiteSpace($CloudflareToken)) {
    Write-Skip "Run mode with no token - staged instead. Run the command above yourself."
    return
}

Write-Line "    requesting $Hostname - DNS-01 through Cloudflare, this takes a minute"
$exit = -1
try {
    $p = Start-Process -FilePath $env:ComSpec `
        -ArgumentList '/c', ('"' + $runner + '" ' + $CloudflareToken) `
        -Wait -PassThru -NoNewWindow -ErrorAction Stop
    # Read Handle before the process is collected or ExitCode comes back empty.
    # Same trap as Invoke-CustomScripts.ps1; do not remove this line.
    $null = $p.Handle
    $exit = $p.ExitCode
} catch {
    Write-Warn "win-acme did not start: $($_.Exception.Message)"
    return
}

if ($exit -eq 0) {
    Write-Good "Certificate issued and bound. Renewal task registered."
    $bound = $null
    try {
        Import-Module RemoteDesktopServices -ErrorAction Stop
        $bound = (Get-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint' -ErrorAction Stop).CurrentValue
    } catch {
        Write-Skip "Could not read the bound thumbprint back: $($_.Exception.Message)"
    }
    if ($bound) { Write-Good "Gateway is now bound to $bound" }

    # win-acme keeps its own copy of the token for renewals, so the one on the
    # CD has done its job. Leaving a second clear-text copy in a file that
    # Get-RDGWStatus.ps1 reads back is gratuitous.
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            $scrubbed = [regex]::Replace($cfg, "(?m)^(\s*CloudflareToken\s*=\s*).*$", '$1'''' # scrubbed after use')
            if ($scrubbed -ne $cfg) {
                Set-Content -LiteralPath $ConfigPath -Value $scrubbed -Encoding ASCII -ErrorAction Stop
                Write-Good "Cloudflare token removed from rdgw-config.psd1 - win-acme holds its own copy"
            }
        } catch {
            Write-Warn "Could not scrub the token from $ConfigPath : $($_.Exception.Message)"
        }
    }
} else {
    Write-Warn "win-acme exited $exit. The gateway keeps its self-signed certificate and still works."
    Write-Warn "Common causes: the token lacks Zone:DNS:Edit, the zone does not cover $Hostname,"
    Write-Warn "or Let's Encrypt rate-limited you at 5 duplicate certificates per week."
    Write-Warn "Fix it and re-run: $runner <token>"
}
