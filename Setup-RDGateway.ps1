<#
.SYNOPSIS
    Installs and configures a standalone Remote Desktop Gateway on Windows Server 2025.

.DESCRIPTION
    Run this inside the VM, from an elevated Windows PowerShell prompt, after
    Windows is installed, patched and has a fixed IP address.

    It does the following, in order:
      1. Turns on Remote Desktop with Network Level Authentication.
      2. Installs the RDS-Gateway role (which pulls in IIS and NPS).
      3. Gets a TLS certificate and binds it to the gateway.
      4. Creates one RD CAP (who may use the gateway) and one RD RAP
         (what they may reach through it).
      5. Opens TCP 443 and UDP 3391 on the Windows firewall.

    The authorization policies are created through the documented
    Win32_TSGateway* WMI classes rather than the RDS: PowerShell provider,
    because the WMI method signatures are explicit about what each flag means.

.PARAMETER ExternalFqdn
    The name clients will type into the "RD Gateway server name" box, e.g.
    rdg.example.com. It must resolve from the internet to your WAN address and
    it must match the certificate.

.PARAMETER CertificateSource
    Existing   - use a certificate already in LocalMachine\My, named by -Thumbprint.
    Pfx        - import a .pfx from -PfxPath.
    SelfSigned - generate one. Fine for testing; every client has to be told to
                 trust it, and mobile RD clients make that awkward.

.PARAMETER AllowedGroups
    Groups permitted through the gateway, written "DOMAIN\Group" - which is the
    form Microsoft documents for UserGroupNames, and the only one that works.
    Built-in local groups are BUILTIN\Administrators and
    BUILTIN\Remote Desktop Users; domain groups are YOURDOMAIN\Group.

    This used to default to the "Group@BUILTIN" form taken from a published
    workgroup example, and on a real build the gateway refused it:

        Win32_TSGatewayConnectionAuthorizationPolicy.Create returned 2147943732

    2147943732 is 0x80070534, ERROR_NONE_MAPPED - "no mapping between account
    names and security IDs". The provider resolves these through
    LookupAccountName, which understands "DOMAIN\Name" and a bare "Name" but not
    the UPN-style "Name@Domain" unless it is a real domain principal. Measured:

        Administrators@BUILTIN         fails to translate
        BUILTIN\Administrators         -> S-1-5-32-544
        Remote Desktop Users@BUILTIN   fails to translate
        BUILTIN\Remote Desktop Users   -> S-1-5-32-555

    Every name is now translated to a SID before the policy is created, so a
    name that cannot resolve is reported by name instead of as a WMI error code.

.PARAMETER TargetMachines
    Other machines on your LAN you want to reach THROUGH this gateway. Give the
    names or IPs you will type into the RD client's "Computer" box. Supplying
    this switches -ResourceScope to Listed automatically.

    Those machines need nothing installed. They only need Remote Desktop turned
    on, your account in their local Remote Desktop Users group, and a name this
    gateway can resolve. Windows Pro editions are fine as targets; only the
    gateway itself has to be Server.

.PARAMETER ResourceScope
    ThisServerOnly - the gateway only proxies connections to itself.
    Listed         - this server plus everything in -TargetMachines. Recommended
                     when you want several machines behind one public hostname.
    AnyResource    - anything the gateway can reach. Convenient, but it means a
                     leaked credential opens your whole LAN, not a chosen list.

.EXAMPLE
    .\Setup-RDGateway.ps1 -ExternalFqdn rdg.example.com -CertificateSource SelfSigned

.EXAMPLE
    Several machines behind one public hostname - the usual reason to run a gateway:

    .\Setup-RDGateway.ps1 -ExternalFqdn rdg.example.com `
        -CertificateSource Existing -Thumbprint A1B2C3... `
        -TargetMachines 'DESKTOP-01','NAS01','192.168.1.60'

.EXAMPLE
    .\Setup-RDGateway.ps1 -ExternalFqdn rdg.example.com -CertificateSource Pfx `
        -PfxPath C:\certs\rdg.pfx -ResourceScope AnyResource

.NOTES
    Run this in Windows PowerShell (powershell.exe), not pwsh. The WMI fallback
    path uses the [wmiclass] type accelerator, which PowerShell 7 removed.

    Licensing: two simultaneous administrative RDP sessions need no RDS CAL.
    Microsoft's licensing terms do call for an RDS CAL for connections made
    through an RD Gateway. There is no technical timer that will cut you off -
    the 120-day grace period applies to RD Session Host, not RD Gateway - so
    this is a compliance question, not a functional one. Decide accordingly.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ExternalFqdn,

    [ValidateSet('Existing', 'Pfx', 'SelfSigned')]
    [string] $CertificateSource = 'SelfSigned',

    [string] $Thumbprint,

    [string] $PfxPath,

    [System.Security.SecureString] $PfxPassword,

    [string[]] $AllowedGroups = @('BUILTIN\Administrators', 'BUILTIN\Remote Desktop Users'),

    # The account that will connect THROUGH the gateway. It is added to the local
    # Remote Desktop Users group - see the "Remote Desktop Users" step below for
    # why that membership, not its membership in Administrators, is what lets the
    # RAP admit it. Empty leaves group membership untouched, which is the right
    # default for an interactive admin running this by hand who is already in it.
    [string] $AccountName = '',

    [string[]] $TargetMachines = @(),

    [ValidateSet('ThisServerOnly', 'Listed', 'AnyResource')]
    [string] $ResourceScope = 'ThisServerOnly',

    [string] $CapName = 'RDG_CAP_Default',

    [string] $RapName = 'RDG_RAP_Default',

    [string] $ResourceGroupName = 'RDG_ThisServer',

    [switch] $SkipRoleInstall
)

$ErrorActionPreference = 'Stop'
$script:TSNamespace = 'root/cimv2/TerminalServices'

# Naming machines is an unambiguous statement of intent, so honour it without
# making the caller also remember to set the scope.
if ($TargetMachines.Count -gt 0 -and -not $PSBoundParameters.ContainsKey('ResourceScope')) {
    $ResourceScope = 'Listed'
}

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Good { param([string]$Message) Write-Host "    [ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [warn] $Message" -ForegroundColor Yellow }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

# ------------------------------------------------------------------------------
# WMI helpers
#
# These classes live in a dynamic WMI provider (AAGProvider). CIM handles them
# fine on current builds, but the [wmiclass] accelerator is what every RD Gateway
# script in the wild uses, so it is kept as a fallback for the transport failing.
# A non-zero WMI return value is checked *outside* the try, so a real provider
# error (duplicate name, bad group) is never mistaken for a transport problem.
# ------------------------------------------------------------------------------
function Invoke-TSGatewayMethod {
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [Parameter(Mandatory)] [string] $MethodName,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Arguments,
        [Parameter(Mandatory)] [string[]] $ArgumentOrder
    )

    $returnValue = $null

    try {
        $cim = Invoke-CimMethod -Namespace $script:TSNamespace -ClassName $ClassName `
                                -MethodName $MethodName -Arguments $Arguments -ErrorAction Stop
        $returnValue = $cim.ReturnValue
    }
    catch {
        $cimError = $_.Exception.Message
        if ($PSVersionTable.PSEdition -ne 'Desktop') {
            throw "$ClassName.$MethodName failed: $cimError`nThe [wmiclass] fallback only exists in " +
                  "Windows PowerShell 5.1 - re-run this in powershell.exe rather than pwsh."
        }
        Write-Note "CIM call failed ($cimError); retrying through [wmiclass]."
        $cls = [wmiclass]"\\.\$($script:TSNamespace.Replace('/','\')):$ClassName"
        $positional = foreach ($key in $ArgumentOrder) { $Arguments[$key] }
        $returnValue = $cls.InvokeMethod($MethodName, [object[]]$positional)
    }

    if ($null -ne $returnValue -and [uint32]$returnValue -ne 0) {
        throw "$ClassName.$MethodName returned $returnValue. See the Remote Desktop Services WMI provider error codes."
    }
}

function Remove-TSGatewayInstance {
    # The AAGProvider exposes Delete() rather than standard instance deletion,
    # so try the method first and only then fall back to Remove-CimInstance.
    param([Parameter(Mandatory)] $Instance, [string] $Label = 'object')
    try {
        Invoke-CimMethod -InputObject $Instance -MethodName 'Delete' -ErrorAction Stop | Out-Null
        return
    } catch {
        try {
            $Instance | Remove-CimInstance -ErrorAction Stop
            return
        } catch {
            throw "Could not remove the existing $Label. Delete it by hand in tsgateway.msc and re-run. ($($_.Exception.Message))"
        }
    }
}

function Get-ResourceIdentity {
    # Every name a client might plausibly hand the gateway for one machine: the
    # name as given, its resolved FQDN, and its IPv4 addresses. Microsoft's RAP
    # troubleshooting guidance is to list the short name and the FQDN separately,
    # because the policy matches on the string the client asked for.
    param([Parameter(Mandatory)] [string] $Machine)

    $Machine
    try {
        $entry = [System.Net.Dns]::GetHostEntry($Machine)
        if ($entry.HostName -and $entry.HostName -ne $Machine) { $entry.HostName }
        $entry.AddressList |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString }
    } catch {
        Write-Verbose "Could not resolve '$Machine' from this host."
    }
}

function Get-TSGatewayInstance {
    param([Parameter(Mandatory)] [string] $ClassName, [string] $Filter)
    try {
        if ($Filter) {
            Get-CimInstance -Namespace $script:TSNamespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop
        } else {
            Get-CimInstance -Namespace $script:TSNamespace -ClassName $ClassName -ErrorAction Stop
        }
    } catch {
        $null
    }
}

# ==============================================================================
Write-Host ""
Write-Host "  Remote Desktop Gateway setup" -ForegroundColor White
Write-Host "  Target name: $ExternalFqdn" -ForegroundColor White
Write-Host "  Machine:     $env:COMPUTERNAME" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------
Write-Step "Checking the environment"

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1) {
    throw "This is a client edition of Windows. The RD Gateway role only exists on Windows Server."
}
Write-Good "$($os.Caption)"

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Warn "You are in PowerShell $($PSVersionTable.PSVersion). Windows PowerShell 5.1 is safer here -"
    Write-Note "the [wmiclass] fallback does not exist in PowerShell 7. Continuing anyway."
}

$computerSystem = Get-CimInstance Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    Write-Good "Domain-joined ($($computerSystem.Domain)). Domain groups are written as DOMAIN\GroupName."
} else {
    Write-Good "Workgroup member. Local groups are written as BUILTIN\GroupName."
}

# Warn early about anything already holding 443.
$busy443 = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
if ($busy443) {
    $owners = ($busy443 | ForEach-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } |
               Sort-Object -Unique) -join ', '
    Write-Warn "Something is already listening on TCP 443: $owners. IIS will fight it for the binding."
}

# ------------------------------------------------------------------------------
# 1. Remote Desktop itself
# ------------------------------------------------------------------------------
Write-Step "Enabling Remote Desktop with Network Level Authentication"

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                 -Name 'UserAuthentication' -Value 1 -Type DWord
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Write-Good "RDP listener on, NLA required"
Write-Note "NLA means the client authenticates before a desktop is drawn. Leave it on."

# ------------------------------------------------------------------------------
# 2. The role
# ------------------------------------------------------------------------------
if (-not $SkipRoleInstall) {
    Write-Step "Installing the RD Gateway role"

    $feature = Get-WindowsFeature -Name RDS-Gateway
    if ($feature.Installed) {
        Write-Good "RDS-Gateway is already installed"
    } else {
        Write-Note "This pulls in IIS and Network Policy Server. Expect a few minutes."
        $install = Install-WindowsFeature -Name RDS-Gateway -IncludeManagementTools
        if (-not $install.Success) {
            throw "Install-WindowsFeature failed: $($install.ExitCode)"
        }
        Write-Good "Installed"
        if ($install.RestartNeeded -eq 'Yes') {
            Write-Warn "Windows wants a reboot. Reboot, then re-run this script with -SkipRoleInstall."
            return
        }
    }
} else {
    Write-Step "Skipping role install (-SkipRoleInstall)"
}

Import-Module RemoteDesktopServices -ErrorAction Stop
if (-not (Test-Path 'RDS:\GatewayServer')) {
    throw "The RDS: drive has no GatewayServer node. The role did not finish installing."
}
Write-Good "RemoteDesktopServices module loaded"

# ------------------------------------------------------------------------------
# 3. Certificate
# ------------------------------------------------------------------------------
Write-Step "Preparing the TLS certificate"

$cert = $null
switch ($CertificateSource) {

    'Existing' {
        if (-not $Thumbprint) { throw "-CertificateSource Existing requires -Thumbprint." }
        $clean = $Thumbprint -replace '[^0-9A-Fa-f]', ''
        $cert = Get-ChildItem Cert:\LocalMachine\My |
                Where-Object { $_.Thumbprint -eq $clean } | Select-Object -First 1
        if (-not $cert) { throw "No certificate with thumbprint $clean in LocalMachine\My." }
        Write-Good "Using existing certificate: $($cert.Subject)"
    }

    'Pfx' {
        if (-not $PfxPath) { throw "-CertificateSource Pfx requires -PfxPath." }
        if (-not (Test-Path $PfxPath)) { throw "No file at $PfxPath." }
        if (-not $PfxPassword) { $PfxPassword = Read-Host -AsSecureString "Password for $PfxPath" }
        $cert = Import-PfxCertificate -FilePath $PfxPath `
                                      -CertStoreLocation Cert:\LocalMachine\My `
                                      -Password $PfxPassword
        Write-Good "Imported: $($cert.Subject)"
    }

    'SelfSigned' {
        $existing = Get-ChildItem Cert:\LocalMachine\My |
                    Where-Object { $_.Subject -eq "CN=$ExternalFqdn" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
                    Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($existing) {
            $cert = $existing
            Write-Good "Reusing the self-signed certificate already present (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
        } else {
            $cert = New-SelfSignedCertificate `
                        -Subject "CN=$ExternalFqdn" `
                        -DnsName $ExternalFqdn, $env:COMPUTERNAME `
                        -CertStoreLocation Cert:\LocalMachine\My `
                        -KeyExportPolicy Exportable `
                        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
                        -NotAfter (Get-Date).AddYears(2) `
                        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1')
            Write-Good "Generated a self-signed certificate valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))"
        }

        $cerOut = Join-Path $env:PUBLIC "Documents\$ExternalFqdn.cer"
        Export-Certificate -Cert $cert -FilePath $cerOut -Force | Out-Null
        Write-Good "Public half exported to $cerOut"
        Write-Warn "Every client must import that .cer into Trusted Root Certification Authorities,"
        Write-Note "or the RD client will refuse the gateway. A real certificate avoids all of this."
    }
}

# Whatever the source, the certificate has to be usable before we try to bind it.
if (-not $cert.HasPrivateKey) {
    throw "That certificate has no private key in LocalMachine\My. A gateway cannot present it. " +
          "Re-import the .pfx (not the .cer) into the computer's Personal store."
}
if ($cert.NotAfter -lt (Get-Date)) {
    throw "That certificate expired on $($cert.NotAfter.ToString('yyyy-MM-dd'))."
}
$sans = ($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ', '
if ($sans -and ($cert.DnsNameList.Unicode -notcontains $ExternalFqdn)) {
    Write-Warn "The certificate's names ($sans) do not include $ExternalFqdn."
    Write-Note "Clients will refuse the gateway with a name-mismatch error."
}

# ------------------------------------------------------------------------------
# 4. Bind it
#
# Primary path is the RDS: provider, which is what win-acme's ImportRDGateway.ps1
# does. Fallback is the documented WMI pair: SetCertificate then Configure, both
# instance methods on the Win32_TSGatewayServerSettings singleton.
# ------------------------------------------------------------------------------
Write-Step "Binding the certificate to the gateway"

function Get-BoundThumbprint {
    try {
        $item = Get-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint' -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains 'CurrentValue') { return "$($item.CurrentValue)" }
        return "$($item.Value)"
    } catch { return '' }
}

$bound = $false
try {
    Set-Item -Path 'RDS:\GatewayServer\SSLCertificate\Thumbprint' -Value $cert.Thumbprint -ErrorAction Stop
    Start-Sleep -Seconds 2
    if ((Get-BoundThumbprint) -replace '\s', '' -ieq $cert.Thumbprint) { $bound = $true }
} catch {
    Write-Note "RDS: provider refused the thumbprint: $($_.Exception.Message)"
}

if (-not $bound) {
    Write-Note "Trying Win32_TSGatewayServerSettings.SetCertificate + Configure instead."
    try {
        $gwSettings = Get-CimInstance -Namespace $script:TSNamespace -ClassName 'Win32_TSGatewayServerSettings' -ErrorAction Stop
        $setResult = Invoke-CimMethod -InputObject $gwSettings -MethodName 'SetCertificate' `
                                      -Arguments @{ CertHash = [byte[]]$cert.GetCertHash() } -ErrorAction Stop
        if ($setResult.ReturnValue -ne 0) { throw "SetCertificate returned $($setResult.ReturnValue)." }

        # The docs are explicit: Configure() must follow SetCertificate() to
        # finish wiring up the IIS and RPC settings. It takes no parameters.
        $gwSettings = Get-CimInstance -Namespace $script:TSNamespace -ClassName 'Win32_TSGatewayServerSettings' -ErrorAction Stop
        $cfgResult = Invoke-CimMethod -InputObject $gwSettings -MethodName 'Configure' -ErrorAction Stop
        if ($cfgResult.ReturnValue -ne 0) { throw "Configure returned $($cfgResult.ReturnValue)." }

        Start-Sleep -Seconds 2
        if ((Get-BoundThumbprint) -replace '\s', '' -ieq $cert.Thumbprint) { $bound = $true }
    } catch {
        Write-Note "WMI fallback failed too: $($_.Exception.Message)"
    }
}

if ($bound) {
    Write-Good "Certificate bound ($($cert.Thumbprint))"
} else {
    Write-Warn "Could not bind the certificate from PowerShell."
    Write-Note "Do it by hand: run tsgateway.msc, right-click the server, Properties,"
    Write-Note "SSL Certificate tab, 'Select an existing certificate', pick $($cert.Subject)."
    Write-Note "Everything below still applies. Continuing."
}

# ------------------------------------------------------------------------------
# 5. Connection Authorization Policy - who may use the gateway
# ------------------------------------------------------------------------------
Write-Step "Creating the connection authorization policy (RD CAP)"

# Resolve every group before handing it to the provider.
#
# The WMI provider resolves these through LookupAccountName and, when that
# fails, returns 2147943732 (0x80070534, ERROR_NONE_MAPPED) from Create - a
# number that says nothing about which name was wrong. On a real build that is
# exactly what happened, and the whole gateway configuration stopped on it.
# Translating here turns an opaque WMI code into "this group does not exist".
$resolved = @()
foreach ($g in $AllowedGroups) {
    try {
        $sid = ([System.Security.Principal.NTAccount] $g).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        Write-Good "$g resolves to $sid"
        $resolved += $g
    } catch {
        Write-Warn "$g does not resolve on this machine and would fail the policy with ERROR_NONE_MAPPED."
        Write-Note "Built-in groups are written BUILTIN\Administrators, not Administrators@BUILTIN."
    }
}
if ($resolved.Count -eq 0) {
    Write-Warn "None of the requested groups resolved: $($AllowedGroups -join ', ')"
    Write-Note "Re-run with -AllowedGroups 'BUILTIN\Administrators','BUILTIN\Remote Desktop Users'"
    exit 1
}

$userGroupString = ($resolved -join ';')
Write-Note "Allowed groups: $userGroupString"

$existingCap = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayConnectionAuthorizationPolicy' `
                                     -Filter "Name='$CapName'"
if ($existingCap) {
    Write-Note "A CAP named $CapName already exists. Removing it so this run is repeatable."
    Remove-TSGatewayInstance -Instance $existingCap -Label "CAP '$CapName'"
}

# Win32_TSGatewayConnectionAuthorizationPolicy::Create takes 18 parameters, in
# exactly this order. All of them are required; leaving the trailing five off
# breaks the call.
#   DeviceRedirectionType 0        = redirect everything
#   IdleTimeout / SessionTimeout 0 = no timeout
#   SessionTimeoutAction 0         = disconnect (moot while SessionTimeout is 0)
#   CookieAuthentication           = what RD Gateway Manager sets for a new CAP
$capArgs = [ordered]@{
    Name                       = $CapName
    UserGroupNames             = $userGroupString
    ComputerGroupNames         = ''
    SmartCard                  = $false
    Password                   = $true
    SecureId                   = $false
    Enabled                    = $true
    DeviceRedirectionType      = [uint32]0
    DiskDrivesDisabled         = $false
    PrintersDisabled           = $false
    SerialPortsDisabled        = $false
    ClipboardDisabled          = $false
    PlugAndPlayDevicesDisabled = $false
    IdleTimeout                = [uint32]0
    SessionTimeout             = [uint32]0
    SessionTimeoutAction       = [uint32]0
    AllowOnlySDRServers        = $false
    CookieAuthentication       = $true
}
Invoke-TSGatewayMethod -ClassName 'Win32_TSGatewayConnectionAuthorizationPolicy' `
                       -MethodName 'Create' `
                       -Arguments $capArgs `
                       -ArgumentOrder @($capArgs.Keys)
Write-Good "CAP '$CapName' created - password authentication, all device redirection allowed"

# ------------------------------------------------------------------------------
# 6. Resource Authorization Policy - what they may reach
# ------------------------------------------------------------------------------
Write-Step "Creating the resource authorization policy (RD RAP)"

$existingRap = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayResourceAuthorizationPolicy' `
                                     -Filter "Name='$RapName'"
if ($existingRap) {
    Write-Note "A RAP named $RapName already exists. Removing it."
    Remove-TSGatewayInstance -Instance $existingRap -Label "RAP '$RapName'"
}

$resourceGroupType = 'ALL'
$resourceGroup     = ''

if ($ResourceScope -in @('ThisServerOnly', 'Listed')) {

    # The gateway box itself is always reachable - you will want a way in even
    # when the machine you were actually after is off. Its own hostname and IPs
    # come from Get-ResourceIdentity below. The external FQDN is deliberately NOT
    # added here: it is this gateway's PUBLIC name, never an internal tunnel
    # target, and on a real build it resolves to the WAN address, which the
    # resource-group Create rejects with 0x80075A42 (measured 2026-09-23) - which
    # took the whole Listed/ThisServerOnly path down with it.
    $names = New-Object System.Collections.Generic.List[string]
    Get-ResourceIdentity -Machine $env:COMPUTERNAME | ForEach-Object { $names.Add($_) }

    if ($computerSystem.PartOfDomain -and $computerSystem.Domain) {
        $names.Add("$env:COMPUTERNAME.$($computerSystem.Domain)")
    }
    Get-DnsClient -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ConnectionSpecificSuffix } |
        Where-Object { $_ } | Sort-Object -Unique |
        ForEach-Object { $names.Add("$env:COMPUTERNAME.$_") }

    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
        ForEach-Object { $names.Add($_.IPAddress) }

    # ...plus anything else you asked to reach through it.
    $unresolved = @()
    foreach ($machine in $TargetMachines) {
        if ([string]::IsNullOrWhiteSpace($machine)) { continue }
        $ids = @(Get-ResourceIdentity -Machine $machine)
        $ids | ForEach-Object { $names.Add($_) }
        if ($ids.Count -le 1) { $unresolved += $machine }
    }

    $resourceList = ($names | Where-Object { $_ } | Sort-Object -Unique) -join ';'
    Write-Note "Resources: $resourceList"

    if ($unresolved.Count -gt 0) {
        Write-Warn "These did not resolve from this server: $($unresolved -join ', ')"
        Write-Note "They are in the policy by name, but the gateway resolves the target at"
        Write-Note "connect time - if it still cannot, you get event 301 and a refused connection."
        Write-Note "Add them to DNS, to this machine's hosts file, or list them by IP instead."
    }

    try {
        $existingRg = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayResourceGroup' `
                                            -Filter "Name='$ResourceGroupName'"
        if ($existingRg) {
            Remove-TSGatewayInstance -Instance $existingRg -Label "resource group '$ResourceGroupName'"
        }

        # Win32_TSGatewayResourceGroup::Create(Name, Description, Resources)
        $rgDescription = if ($ResourceScope -eq 'Listed') {
            "This gateway plus $($TargetMachines.Count) listed machine(s)"
        } else {
            'This gateway server only'
        }
        $rgArgs = [ordered]@{
            Name        = $ResourceGroupName
            Description = $rgDescription
            Resources   = $resourceList
        }
        Invoke-TSGatewayMethod -ClassName 'Win32_TSGatewayResourceGroup' `
                               -MethodName 'Create' `
                               -Arguments $rgArgs `
                               -ArgumentOrder @($rgArgs.Keys)
        $resourceGroupType = 'RG'
        $resourceGroup     = $ResourceGroupName
        Write-Good "Resource group '$ResourceGroupName' created"
    }
    catch {
        Write-Warn "Could not create the resource group: $($_.Exception.Message)"
        Write-Warn "Falling back to 'any network resource'. Tighten this in tsgateway.msc afterwards."
        $resourceGroupType = 'ALL'
        $resourceGroup     = ''
    }
}
else {
    Write-Warn "ResourceScope is AnyResource. Anyone who passes the CAP can RDP to any"
    Write-Note "machine this server can reach. That is a jump host. If you only want a few"
    Write-Note "machines, -TargetMachines gives you the same reach with a named list."
}

# Win32_TSGatewayResourceAuthorizationPolicy::Create(Name, Description, Enabled,
#   ResourceGroupType, ResourceGroupName, UserGroupNames, ProtocolNames, PortNumbers)
# ProtocolNames must match Win32_TSGatewayServerSettings::GetProtocolName; only
# one protocol is supported. PortNumbers is a semicolon list, '*' meaning any.
$rapArgs = [ordered]@{
    Name              = $RapName
    Description       = "Created by Setup-RDGateway.ps1 on $(Get-Date -Format 'yyyy-MM-dd')"
    Enabled           = $true
    ResourceGroupType = $resourceGroupType
    ResourceGroupName = $resourceGroup
    UserGroupNames    = $userGroupString
    ProtocolNames     = 'RDP'
    PortNumbers       = '3389'
}
Invoke-TSGatewayMethod -ClassName 'Win32_TSGatewayResourceAuthorizationPolicy' `
                       -MethodName 'Create' `
                       -Arguments $rapArgs `
                       -ArgumentOrder @($rapArgs.Keys)
Write-Good "RAP '$RapName' created - scope: $ResourceScope"

# ------------------------------------------------------------------------------
# 6b. Put the connecting account in Remote Desktop Users
# ------------------------------------------------------------------------------
# This is the step whose absence made every connection fail with error 23002 -
# an event 301 RAP denial - while the CAP passed with event 200, for days.
#
# The two gates read group membership by different mechanisms:
#
#   CAP  NPS evaluates it against the account database, so it sees the account
#        in BUILTIN\Administrators and passes.
#   RAP  the gateway service evaluates it against the ACCESS TOKEN of the
#        incoming connection.
#
# On a workgroup gateway the connecting account is local, and UAC remote token
# filtering - EnableLUA=1 with LocalAccountTokenFilterPolicy unset, the default -
# strips BUILTIN\Administrators out of a local account's network logon token,
# leaving it deny-only. So the RAP, checking the token, does not count the
# account as an administrator and refuses every resource, even one named
# explicitly in a resource group. Remote Desktop Users (S-1-5-32-555) is not an
# administrative group, so UAC does not filter it, and the RAP admits it. The
# default AllowedGroups already lists Remote Desktop Users; this makes the
# account a member of it. See CLAUDE.md, "Why the RAP denied every connection".
#
# Confirmed 2026-09-23: a remote, external client connected through the gateway
# to the gateway itself and to a second LAN machine only after this was added.
if ($AccountName) {
    Write-Step "Adding '$AccountName' to Remote Desktop Users"
    $already = @(Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "*\$AccountName" -or $_.Name -eq $AccountName })
    if ($already.Count -gt 0) {
        Write-Good "'$AccountName' is already in Remote Desktop Users"
    }
    else {
        try {
            Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $AccountName -ErrorAction Stop
            Write-Good "'$AccountName' added to Remote Desktop Users"
        }
        catch {
            Write-Warn "Could not add '$AccountName' to Remote Desktop Users: $($_.Exception.Message)"
            Write-Note "Without this, connections fail with error 23002 (a RAP denial). Add it by hand:"
            Write-Note "  Add-LocalGroupMember -Group 'Remote Desktop Users' -Member '$AccountName'"
        }
    }
}
else {
    Write-Note "No -AccountName was given, so Remote Desktop Users membership is unchanged."
    Write-Note "The account you CONNECT WITH must be in this gateway's Remote Desktop Users"
    Write-Note "group, or every connection fails with error 23002. See the runbook."
}

# ------------------------------------------------------------------------------
# 7. Firewall
# ------------------------------------------------------------------------------
Write-Step "Opening the firewall"

function Add-RuleIfMissing {
    param([string]$Name, [string]$Protocol, [int]$Port)
    if (Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue) {
        Write-Good "$Name already present"
        return
    }
    New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow `
                        -Protocol $Protocol -LocalPort $Port -Profile Any | Out-Null
    Write-Good "$Name added"
}

Add-RuleIfMissing -Name 'RD Gateway - HTTPS (TCP 443)'    -Protocol TCP -Port 443
Add-RuleIfMissing -Name 'RD Gateway - UDP transport 3391' -Protocol UDP -Port 3391
Write-Note "UDP 3391 is optional. It carries the graphics stream and makes a laggy link feel much better."

# ------------------------------------------------------------------------------
# 8. Restart and verify
# ------------------------------------------------------------------------------
Write-Step "Restarting the gateway service"
Restart-Service -Name TSGateway -Force
Start-Sleep -Seconds 3
$svc = Get-Service TSGateway
if ($svc.Status -ne 'Running') { throw "TSGateway did not come back up (status: $($svc.Status))." }
Write-Good "TSGateway is running"

Write-Step "Verifying"

# Property names on these classes differ from the Create parameter names:
# Password -> PasswordAllowed, SmartCard -> SmartcardAllowed.
$caps = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayConnectionAuthorizationPolicy'
$raps = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayResourceAuthorizationPolicy'

Write-Good "Connection authorization policies:"
$caps | Select-Object Name, Order, Enabled, PasswordAllowed, SmartcardAllowed, UserGroupNames |
    Format-List | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host

Write-Good "Resource authorization policies:"
$raps | Select-Object Name, Enabled, ResourceGroupType, ResourceGroupName, UserGroupNames, ProtocolNames, PortNumbers |
    Format-List | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host

Write-Note "Check UserGroupNames above actually resolved. If it is blank or mangled, the"
Write-Note "group@domain form was wrong for this machine - fix it in tsgateway.msc."

if ($resourceGroupType -eq 'RG') {
    $rg = Get-TSGatewayInstance -ClassName 'Win32_TSGatewayResourceGroup' -Filter "Name='$ResourceGroupName'"
    if ($rg) { Write-Good "Resource group '$ResourceGroupName' contains: $($rg.Resources)" }
    else     { Write-Warn "Resource group '$ResourceGroupName' is not readable back. Check tsgateway.msc." }
}

$finalThumb = Get-BoundThumbprint
if ($finalThumb) { Write-Good "Bound certificate: $finalThumb" } else { Write-Warn "No certificate is bound yet." }

$listening = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
if ($listening) { Write-Good "Listening on TCP 443" } else { Write-Warn "Nothing is listening on TCP 443 yet." }

# ------------------------------------------------------------------------------
# What is left for you
# ------------------------------------------------------------------------------
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
          Select-Object -First 1).IPAddress

Write-Host @"

------------------------------------------------------------------------
 Done on this box. The rest is outside it.

 1. DNS
    $ExternalFqdn must resolve to your WAN address from the internet.

 2. Port forward, on your router
    TCP 443  -> ${lanIp} : 443
    UDP 3391 -> ${lanIp} : 3391
    Do NOT forward 3389. The whole point of the gateway is that 3389
    never touches the internet.

 3. Connect
    In the Remote Desktop client:
      Computer        : $env:COMPUTERNAME   <- or any machine in the RAP above
      Gateway server  : $ExternalFqdn
      Bypass gateway for local addresses: off
    Tick "use my gateway credentials for the remote computer".

    One gateway, many targets: change only the Computer field to reach a
    different machine. The gateway name stays the same for all of them.

 3b. On each OTHER machine you listed
    Nothing gets installed. Each one needs:
      - Remote Desktop enabled  (Settings > System > Remote Desktop, or
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0)
      - your account in its local Remote Desktop Users group
      - its firewall allowing 3389 from this gateway
      - a name this gateway can resolve
    Windows Pro is fine. Home editions cannot accept RDP at all.

 4. Watch it work
    Get-WinEvent -LogName Microsoft-Windows-TerminalServices-Gateway/Operational -MaxEvents 20
    200 = client reached the gateway. 300 = resource authorized.
    302 = through to the target. 301 = the RAP refused the name asked for.
------------------------------------------------------------------------
"@ -ForegroundColor White
