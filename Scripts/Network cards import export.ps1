#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Network cards as a configuration section.
.DESCRIPTION
    Each entry has two parts: FindBy finds the card, Change says what to
    change on it. FindBy has exactly one of:
    - Description: a card whose description matches exactly is used first,
      otherwise the one card whose description contains the text. The
      description comes from the driver and cannot be changed.
    - Name: the card with this current name, such as 'Ethernet'.
    Change renames the card (NewName), sets its DnsSuffix, NetworkCategory
    and IPSettings, in that order. When a step fails, the remaining steps
    for that card are skipped. Entries that match no card or more than one
    card are reported. Each problem is reported in Errors and the remaining
    cards are still processed.

    IPSettings either makes the card use DHCP ({ Dhcp = $true }), or gives it
    one static IPAddress with PrefixLength, an optional DefaultGateway and
    optional DNSServers. A static address replaces all IPv4 addresses and the
    default gateway of the card. DNSServers replaces the DNS servers; an
    empty list makes DNS automatic again and omitting it leaves DNS
    unchanged. When an IPv4 change fails, the previous DHCP setting,
    addresses, default gateway and DNS servers are restored, best effort,
    and the error says whether that worked.

    Export finds each card by its description and writes its current name
    and settings in Change, including its IPv4 settings: Dhcp true, or its
    first static address with gateway, and DNS servers that were set by
    hand. The static address is written as an {{ipv4:...}} placeholder that
    shows the exported address, so the restore asks for it; the prefix
    length, gateway and DNS servers are written as they are.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written
    here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"

#region Windows helpers
function Find-NetAdapterHC {
    # Exact description first, so identical cards such as 'Intel(R) Ethernet'
    # and 'Intel(R) Ethernet #2' are never confused; otherwise a single
    # card whose description contains the text
    param([Parameter(Mandatory)][string]$Description)
    $exact = @(
        $netAdapters |
        Where-Object { $_.InterfaceDescription -eq $Description }
    )
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) {
        throw (
            "$($exact.Count) network cards have the description " +
            "'$Description'"
        )
    }
    $partial = @($netAdapters | Where-Object {
            $_.InterfaceDescription -and
            $_.InterfaceDescription.IndexOf(
                $Description, [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        })
    if ($partial.Count -eq 0) {
        throw (
            'no network card found with a description containing ' +
            "'$Description'"
        )
    }
    if ($partial.Count -gt 1) {
        $descriptions = (
            $partial | ForEach-Object { $_.InterfaceDescription }
        ) -join ', '
        throw (
            "$($partial.Count) network cards match the description " +
            "'$Description' ($descriptions); use the full description"
        )
    }
    $partial[0]
}

function Find-CardHC {
    # The card of a configuration entry, by FindBy.Description or FindBy.Name
    param($FindBy)
    $hasDescription = -not [string]::IsNullOrWhiteSpace($FindBy.Description)
    $hasName = -not [string]::IsNullOrWhiteSpace($FindBy.Name)
    if ($hasDescription -and $hasName) {
        throw 'FindBy has both Description and Name; use one of them'
    }
    if ($hasDescription) {
        return Find-NetAdapterHC -Description $FindBy.Description
    }
    if (-not $hasName) {
        throw 'FindBy needs Description or Name to find the network card'
    }
    $named = @($netAdapters | Where-Object { $_.Name -eq $FindBy.Name })
    if (-not $named.Count) {
        $names = ($netAdapters | ForEach-Object { $_.Name }) -join ', '
        throw (
            "no network card found with Name '$($FindBy.Name)'; " +
            "names: $names"
        )
    }
    $named[0]
}

function Get-IPv4StateHC {
    # Current IPv4 settings of a card
    param([Parameter(Mandatory)]$Adapter)
    $interfaceParams = @{
        InterfaceIndex = $Adapter.InterfaceIndex
        AddressFamily  = 'IPv4'
        ErrorAction    = 'SilentlyContinue'
    }
    $interface = Get-NetIPInterface @interfaceParams
    if (-not $interface) { return $null }
    $addressParams = @{
        InterfaceIndex = $Adapter.InterfaceIndex
        AddressFamily  = 'IPv4'
        ErrorAction    = 'SilentlyContinue'
    }
    $addresses = @(
        Get-NetIPAddress @addressParams |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
    )
    $routeParams = @{
        InterfaceIndex    = $Adapter.InterfaceIndex
        DestinationPrefix = '0.0.0.0/0'
        ErrorAction       = 'SilentlyContinue'
    }
    $routes = @(
        Get-NetRoute @routeParams
    )
    # NameServer holds only DNS servers set by hand, not those from DHCP
    $dnsServers = @()
    if ($Adapter.InterfaceGuid) {
        $key = (
            'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\' +
            "Interfaces\$($Adapter.InterfaceGuid)"
        )
        $nameServerParams = @{
            LiteralPath = $key
            Name        = 'NameServer'
            ErrorAction = 'SilentlyContinue'
        }
        $nameServer = (Get-ItemProperty @nameServerParams).NameServer
        $dnsServers = @(
            [string]$nameServer -split '[,\s]+' | Where-Object { $_ }
        )
    }
    [pscustomobject]@{
        Dhcp       = [string]$interface.Dhcp -eq 'Enabled'
        Addresses  = $addresses
        Routes     = $routes
        DnsServers = $dnsServers
    }
}

function Restore-IPv4StateHC {
    # Best effort: puts back the IPv4 settings read by Get-IPv4StateHC before
    # a change, step by step, and returns the steps that failed
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$State,
        [switch]$Dns
    )
    Write-Verbose "Restore the previous IPv4 settings of '$($Adapter.Name)'"
    $index = $Adapter.InterfaceIndex
    $failures = [System.Collections.Generic.List[string]]::new()
    $restoreStep = {
        param([string]$Description, [scriptblock]$Action)
        try {
            $null = & $Action
        }
        catch {
            $failures.Add("${Description}: $($_.Exception.Message)")
        }
    }
    $getCurrent = {
        $current = Get-IPv4StateHC -Adapter $Adapter
        if (-not $current) {
            throw 'the card has no IPv4 settings'
        }
        $current
    }

    $current = $null
    try {
        $current = & $getCurrent
    }
    catch {
        $failures.Add(
            "the current settings could not be read: $($_.Exception.Message)"
        )
    }

    if ($current -and $State.Dhcp) {
        if (-not $current.Dhcp) {
            if ($current.Addresses.Count) {
                & $restoreStep 'the static addresses could not be removed' {
                    $params = @{
                        InterfaceIndex = $index
                        AddressFamily  = 'IPv4'
                        Confirm        = $false
                    }
                    Remove-NetIPAddress @params
                }
            }
            if ($current.Routes.Count) {
                & $restoreStep 'the default gateway could not be removed' {
                    $params = @{
                        InterfaceIndex    = $index
                        DestinationPrefix = '0.0.0.0/0'
                        Confirm           = $false
                    }
                    Remove-NetRoute @params
                }
            }
            & $restoreStep 'DHCP could not be enabled again' {
                $params = @{
                    InterfaceIndex = $index
                    AddressFamily  = 'IPv4'
                    Dhcp           = 'Enabled'
                }
                Set-NetIPInterface @params
            }
        }
    }
    elseif ($current) {
        if ($current.Dhcp) {
            & $restoreStep 'DHCP could not be turned off again' {
                $params = @{
                    InterfaceIndex = $index
                    AddressFamily  = 'IPv4'
                    Dhcp           = 'Disabled'
                }
                Set-NetIPInterface @params
            }
            try {
                $current = & $getCurrent
            }
            catch {
                $failures.Add(
                    'the current settings could not be read: ' +
                    "$($_.Exception.Message)"
                )
                $current = [pscustomobject]@{
                    Addresses = @()
                    Routes    = @()
                }
            }
        }

        $oldAddresses = @(
            $State.Addresses |
            ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }
        )
        $currentAddresses = @(
            $current.Addresses |
            ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }
        )
        $oldGateways = @(
            $State.Routes |
            ForEach-Object { [string]$_.NextHop } |
            Where-Object { $_ -and $_ -ne '0.0.0.0' }
        )
        $currentGateways = @(
            $current.Routes | ForEach-Object { [string]$_.NextHop }
        )

        foreach ($address in @($current.Addresses)) {
            if ($oldAddresses -notcontains
                "$($address.IPAddress)/$($address.PrefixLength)"
            ) {
                $step = "the address $($address.IPAddress) could not be removed"
                & $restoreStep $step {
                    $params = @{
                        InterfaceIndex = $index
                        IPAddress      = $address.IPAddress
                        Confirm        = $false
                    }
                    Remove-NetIPAddress @params
                }
            }
        }

        foreach ($gateway in $currentGateways) {
            if ($gateway -and $oldGateways -notcontains $gateway) {
                $step = "the default gateway $gateway could not be removed"
                & $restoreStep $step {
                    $params = @{
                        InterfaceIndex    = $index
                        DestinationPrefix = '0.0.0.0/0'
                        NextHop           = $gateway
                        Confirm           = $false
                    }
                    Remove-NetRoute @params
                }
            }
        }

        foreach ($address in @($State.Addresses)) {
            $text = "$($address.IPAddress)/$($address.PrefixLength)"
            if ($currentAddresses -notcontains $text) {
                & $restoreStep "the address $text could not be added back" {
                    $oldAddress = @{
                        InterfaceIndex = $index
                        AddressFamily  = 'IPv4'
                        IPAddress      = [string]$address.IPAddress
                        PrefixLength   = [int]$address.PrefixLength
                    }
                    New-NetIPAddress @oldAddress
                }
            }
        }

        foreach ($gateway in $oldGateways) {
            if ($currentGateways -notcontains $gateway) {
                $step = "the default gateway $gateway could not be added back"
                & $restoreStep $step {
                    $params = @{
                        InterfaceIndex    = $index
                        DestinationPrefix = '0.0.0.0/0'
                        NextHop           = $gateway
                    }
                    New-NetRoute @params
                }
            }
        }
    }

    if ($Dns) {
        if ($State.DnsServers.Count) {
            & $restoreStep 'the DNS servers could not be set back' {
                $params = @{
                    InterfaceIndex  = $index
                    ServerAddresses = @($State.DnsServers)
                }
                Set-DnsClientServerAddress @params
            }
        }
        else {
            & $restoreStep 'automatic DNS could not be set back' {
                $params = @{
                    InterfaceIndex       = $index
                    ResetServerAddresses = $true
                }
                Set-DnsClientServerAddress @params
            }
        }
    }

    $failures
}

function Set-IPv4SettingsHC {
    # Returns the messages of the changes; nothing when already correct.
    # When a change fails, the previous IPv4 settings are restored and one
    # error says what failed and whether restoring worked
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$Label
    )
    $index = $Adapter.InterfaceIndex
    $state = Get-IPv4StateHC -Adapter $Adapter
    if (-not $state) { throw 'the card has no IPv4 settings' }
    $names = @($Settings.PSObject.Properties.Name)
    if ($Settings -is [System.Collections.IDictionary]) {
        $names = @($Settings.Keys)
    }
    $dnsChanged = $false
    $failedStep = $null

    try {
        if ($Settings.Dhcp -eq $true) {
            if (-not $state.Dhcp) {
                Write-Verbose "Network card $($Label): enable DHCP"
                $failedStep = 'DHCP could not be enabled'
                if ($state.Addresses.Count) {
                    $params = @{
                        InterfaceIndex = $index
                        AddressFamily  = 'IPv4'
                        Confirm        = $false
                    }
                    Remove-NetIPAddress @params
                }
                if ($state.Routes.Count) {
                    $params = @{
                        InterfaceIndex    = $index
                        DestinationPrefix = '0.0.0.0/0'
                        Confirm           = $false
                    }
                    Remove-NetRoute @params
                }
                $params = @{
                    InterfaceIndex = $index
                    AddressFamily  = 'IPv4'
                    Dhcp           = 'Enabled'
                }
                Set-NetIPInterface @params
                "Network card $Label now gets its IPv4 address from DHCP"
                if (
                    $names -notcontains 'DNSServers' -and
                    $state.DnsServers.Count
                ) {
                    $failedStep = 'automatic DNS could not be set'
                    $dnsChanged = $true
                    $params = @{
                        InterfaceIndex       = $index
                        ResetServerAddresses = $true
                    }
                    Set-DnsClientServerAddress @params
                    "Network card $Label now gets its DNS servers from DHCP"
                }
            }
        }
        else {
            $address = [string]$Settings.IPAddress
            $prefix = [int]$Settings.PrefixLength
            $gateway = [string]$Settings.DefaultGateway
            $currentGateway = @(
                $state.Routes | ForEach-Object { $_.NextHop }
            ) -join ','
            $isCorrect = (
                -not $state.Dhcp -and
                $state.Addresses.Count -eq 1 -and
                $state.Addresses[0].IPAddress -eq $address -and
                [int]$state.Addresses[0].PrefixLength -eq $prefix -and
                $currentGateway -eq $gateway
            )
            if (-not $isCorrect) {
                Write-Verbose (
                    "Network card $($Label): set static address " +
                    "$address/$prefix"
                )
                $failedStep = (
                    "the static address $address/$prefix could not be set"
                )
                if ($state.Dhcp) {
                    $params = @{
                        InterfaceIndex = $index
                        AddressFamily  = 'IPv4'
                        Dhcp           = 'Disabled'
                    }
                    Set-NetIPInterface @params
                }
                # Read again: turning DHCP off can already remove its address
                $current = Get-IPv4StateHC -Adapter $Adapter
                if ($current.Addresses.Count) {
                    $params = @{
                        InterfaceIndex = $index
                        AddressFamily  = 'IPv4'
                        Confirm        = $false
                    }
                    Remove-NetIPAddress @params
                }
                if ($current.Routes.Count) {
                    $params = @{
                        InterfaceIndex    = $index
                        DestinationPrefix = '0.0.0.0/0'
                        Confirm           = $false
                    }
                    Remove-NetRoute @params
                }
                $newAddress = @{
                    InterfaceIndex = $index
                    AddressFamily  = 'IPv4'
                    IPAddress      = $address
                    PrefixLength   = $prefix
                }
                if ($gateway) { $newAddress.DefaultGateway = $gateway }
                $null = New-NetIPAddress @newAddress
                $text = (
                    "Network card $Label now has the static IPv4 address " +
                    "$address/$prefix"
                )
                if ($gateway) { $text += " with default gateway $gateway" }
                $text
            }
        }

        if (-not $dnsChanged -and $names -contains 'DNSServers') {
            $servers = @($Settings.DNSServers | Where-Object { $_ })
            if (($servers -join ',') -ne ($state.DnsServers -join ',')) {
                $dnsChanged = $true
                if ($servers.Count) {
                    Write-Verbose (
                        "Network card $($Label): set DNS servers " +
                        "$($servers -join ', ')"
                    )
                    $failedStep = (
                        "the DNS servers $($servers -join ', ') " +
                        'could not be set'
                    )
                    $params = @{
                        InterfaceIndex  = $index
                        ServerAddresses = $servers
                    }
                    Set-DnsClientServerAddress @params
                    (
                        "Network card $Label now uses the DNS servers " +
                        "$($servers -join ', ')"
                    )
                }
                else {
                    Write-Verbose "Network card $($Label): set automatic DNS"
                    $failedStep = 'automatic DNS could not be set'
                    $params = @{
                        InterfaceIndex       = $index
                        ResetServerAddresses = $true
                    }
                    Set-DnsClientServerAddress @params
                    (
                        "Network card $Label now gets its DNS servers " +
                        'automatically'
                    )
                }
            }
        }
    }
    catch {
        if (-not $failedStep) {
            throw
        }
        $reason = $_.Exception.Message
        Write-Verbose "Network card $($Label): $failedStep"
        $restoreParams = @{
            Adapter = $Adapter
            State   = $state
            Dns     = $dnsChanged
        }
        $restoreFailures = @(
            Restore-IPv4StateHC @restoreParams
        )
        if ($restoreFailures.Count) {
            throw (
                "${failedStep}: $reason; restoring the previous settings " +
                "failed too: $($restoreFailures -join '; ')"
            )
        }
        throw (
            "${failedStep}: $reason; " +
            'the previous IPv4 settings were restored'
        )
    }
}

function Get-IPv4SettingsHC {
    # IPSettings to export for a card, or $null without IPv4
    param(
        [Parameter(Mandatory)]$Adapter,
        # Read by Get-IPv4StateHC
        [Parameter(Mandatory)][AllowNull()]$State
    )
    if (-not $State) {
        return $null
    }
    $settings = [ordered]@{}
    if ($state.Dhcp -or -not $state.Addresses.Count) {
        $settings.Dhcp = $true
    }
    else {
        # A placeholder, so restoring on several PCs never gives them all the
        # same address; the exported address is shown when asking for it
        $cardName = [string]$Adapter.Name -replace '[{}\r\n]', ''
        $settings.IPAddress = (
            "{{ipv4:IP address of network card '$cardName' " +
            "(was $($state.Addresses[0].IPAddress))}}"
        )
        $settings.PrefixLength = [int]$state.Addresses[0].PrefixLength
        $gateway = @(
            $state.Routes |
            ForEach-Object { [string]$_.NextHop } |
            Where-Object { $_ -and $_ -ne '0.0.0.0' }
        )
        if ($gateway.Count) { $settings.DefaultGateway = $gateway[0] }
    }
    if ($state.DnsServers.Count) {
        $settings.DNSServers = @($state.DnsServers)
    }
    $settings
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Network cards: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

$netAdapters = @(Get-NetAdapter)
# A computer without a connected network has no connection profiles
$netConnectionProfiles = @(
    Get-NetConnectionProfile -ErrorAction SilentlyContinue
)
$dnsClients = @(Get-DnsClient)
Write-Verbose "Found $($netAdapters.Count) network card(s)"

# Look up the DNS client and connection profiles of a card by its index
$dnsClientByIndex = @{}
foreach ($dnsClient in $dnsClients) {
    $dnsClientByIndex[[int]$dnsClient.InterfaceIndex] = $dnsClient
}
$profilesByIndex = @{}
foreach ($connectionProfile in $netConnectionProfiles) {
    $index = [int]$connectionProfile.InterfaceIndex
    if (-not $profilesByIndex.ContainsKey($index)) {
        $profilesByIndex[$index] = (
            [System.Collections.Generic.List[object]]::new()
        )
    }
    $profilesByIndex[$index].Add($connectionProfile)
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Network cards'
    $cardsToExport = foreach ($adapter in $netAdapters) {
        Write-Verbose "Network card '$($adapter.Name)': export"
        $index = [int]$adapter.InterfaceIndex
        $networkCategory = @($profilesByIndex[$index]).NetworkCategory |
            Select-Object -First 1
        $dnsSuffix = $dnsClientByIndex[$index].ConnectionSpecificSuffix
        $change = [ordered]@{
            NewName         = $adapter.Name
            NetworkCategory = [String]$networkCategory
            DnsSuffix       = $dnsSuffix
        }
        $state = Get-IPv4StateHC -Adapter $adapter
        $ipSettings = Get-IPv4SettingsHC -Adapter $adapter -State $state
        if ($ipSettings) {
            $change.IPSettings = $ipSettings
            if ($ipSettings.IPAddress) {
                $addresses = @($state.Addresses)
                $messages.Add(
                    "Network card '$($adapter.Name)' has the static IPv4 " +
                    "address $($addresses[0].IPAddress); it was exported as " +
                    'a placeholder, so the restore asks for the address'
                )
                if ($addresses.Count -gt 1) {
                    $messages.Add(
                        "Network card '$($adapter.Name)' has " +
                        "$($addresses.Count) IPv4 addresses; only " +
                        "$($addresses[0].IPAddress) was exported"
                    )
                }
            }
        }
        [ordered]@{
            FindBy = [ordered]@{
                Description = $adapter.InterfaceDescription
            }
            Change = $change
        }
    }
    if (-not $cardsToExport) {
        Write-Verbose 'No network cards found, use the example'
        $cardsToExport = Read-SectionExampleHC (
            "$PSScriptRoot\..\Examples\NetworkCards.json"
        )
    }
    $exportData = @($cardsToExport)
    #endregion

    $messages.Insert(0, 'Exported Network cards')
}
else {
    #region Apply section
    Write-Verbose 'Import Network cards'
    foreach ($card in @($Data)) {
        $change = $card.Change
        $label = if ($change.NewName) {
            "'$($change.NewName)'"
        }
        elseif ($card.FindBy.Name) {
            "'$($card.FindBy.Name)'"
        }
        else {
            "with description '$($card.FindBy.Description)'"
        }
        try {
            Write-Verbose "Network card $($label): find and configure"
            $adapter = Find-CardHC -FindBy $card.FindBy
            $changes = 0

            #region Rename network card
            if ($change.NewName -and $adapter.Name -ne $change.NewName) {
                Write-Verbose "Network card $($label): rename"
                Rename-NetAdapter -Name $adapter.Name -NewName $change.NewName
                $messages.Add(
                    'Renamed network card ' +
                    "'$($adapter.InterfaceDescription)' from " +
                    "'$($adapter.Name)' to '$($change.NewName)'"
                )
                $changes++
            }
            #endregion

            #region Set DNS suffix
            # An empty string clears it and null leaves it unchanged
            $dnsClient = $dnsClientByIndex[[int]$adapter.InterfaceIndex]
            if (
                $null -ne $change.DnsSuffix -and
                [string]$dnsClient.ConnectionSpecificSuffix -ne
                $change.DnsSuffix
            ) {
                Write-Verbose "Network card $($label): set DNS suffix"
                $dnsClientParams = @{
                    InterfaceIndex           = $adapter.InterfaceIndex
                    ConnectionSpecificSuffix = $change.DnsSuffix
                }
                Set-DnsClient @dnsClientParams
                $messages.Add(
                    "Changed DNS suffix of network card $label from " +
                    "'$($dnsClient.ConnectionSpecificSuffix)' to " +
                    "'$($change.DnsSuffix)'"
                )
                $changes++
            }
            #endregion

            #region Set network category
            if ($change.NetworkCategory) {
                $adapterProfiles = @(
                    $profilesByIndex[[int]$adapter.InterfaceIndex] |
                    Where-Object { $_ }
                )
                if (-not $adapterProfiles.Count) {
                    # Windows only has a network category for a connected
                    # network
                    Write-Verbose (
                        "Network card $($label): no connection, " +
                        'skip network category'
                    )
                    $messages.Add(
                        "Network card $label has no network connection, " +
                        "its network category '$($change.NetworkCategory)' " +
                        'was not set'
                    )
                    $changes++
                }
                $profilesToChange = @(
                    $adapterProfiles | Where-Object {
                        $_.NetworkCategory -ne $change.NetworkCategory
                    }
                )
                foreach ($profile in $profilesToChange) {
                    Write-Verbose (
                        "Network card $($label): set network category"
                    )
                    $profileParams = @{
                        InterfaceIndex  = $profile.InterfaceIndex
                        NetworkCategory = $change.NetworkCategory
                    }
                    Set-NetConnectionProfile @profileParams
                    $messages.Add(
                        'Changed network category of network card ' +
                        "$label from '$($profile.NetworkCategory)' to " +
                        "'$($change.NetworkCategory)'"
                    )
                    $changes++
                }
            }
            #endregion

            #region Set IPv4 settings
            if ($null -ne $change.IPSettings) {
                $ipParams = @{
                    Adapter  = $adapter
                    Settings = $change.IPSettings
                    Label    = $label
                }
                foreach ($message in @(Set-IPv4SettingsHC @ipParams)) {
                    $messages.Add($message)
                    $changes++
                }
            }
            #endregion

            if (-not $changes) {
                Write-Verbose "Network card $($label): already correct"
                $messages.Add("Network card $label is already correct")
            }
        }
        catch {
            Write-Verbose "Network card $($label): failed"
            $errors.Add(
                "Failed to configure network card ${label}: " +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion
}

Write-Verbose (
    "Network cards: $(@($messages).Count) message(s), " +
    "$(@($errors).Count) error(s)"
)
$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams