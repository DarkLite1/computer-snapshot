#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Network cards as a configuration section.
.DESCRIPTION
    Import finds the network card for each entry by NetworkCardDescription:
    a card whose description matches exactly is used first, otherwise the
    one card whose description contains the text. Then it renames the card,
    sets its DNS suffix and its network category, in that order. When a step
    fails, the remaining steps for that card are skipped. Entries that match
    no card or more than one card are reported. Each problem is reported in
    Errors and the remaining cards are still processed.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
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
    $exact = @($netAdapters | Where-Object { $_.InterfaceDescription -eq $Description })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) {
        throw "$($exact.Count) network cards have the description '$Description'"
    }
    $partial = @($netAdapters | Where-Object {
            $_.InterfaceDescription -and
            $_.InterfaceDescription.IndexOf($Description, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
    if ($partial.Count -eq 0) {
        throw "no network card found with a description containing '$Description'"
    }
    if ($partial.Count -gt 1) {
        throw "$($partial.Count) network cards match the description '$Description' ($(($partial | ForEach-Object { $_.InterfaceDescription }) -join ', ')); use the full description"
    }
    $partial[0]
}
#endregion
$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}
$netAdapters = @(Get-NetAdapter)
# A computer without a connected network has no connection profiles
$netConnectionProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
$dnsClients = @(Get-DnsClient)
if ($Action -eq 'Export') {
    #region Capture section
    $cardsToExport = foreach ($adapter in $netAdapters) {
        $networkCategory = ($netConnectionProfiles | Where-Object { $_.InterfaceAlias -eq $adapter.Name }).NetworkCategory
        @{
            NetworkCardName        = $adapter.Name
            NetworkCardDescription = $adapter.InterfaceDescription
            NetworkCategory        = [String]$networkCategory
            NetworkCardDnsSuffix   = ($dnsClients | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex }).ConnectionSpecificSuffix
        }
    }
    if (-not $cardsToExport) {
        Write-Verbose 'No network cards found, use the example'
        $cardsToExport = Read-SectionExampleHC "$PSScriptRoot\..\Examples\NetworkCards.json"
    }
    $exportData = @($cardsToExport)
    #endregion
    $messages = @('Exported Network cards')
}
else {
    #region Apply section
    foreach ($card in @($Data)) {
        $label = if ($card.NetworkCardName) { "'$($card.NetworkCardName)'" } else { "with description '$($card.NetworkCardDescription)'" }
        try {
            if ([string]::IsNullOrWhiteSpace($card.NetworkCardDescription)) {
                throw 'the field NetworkCardDescription is required to find the network card'
            }
            $adapter = Find-NetAdapterHC -Description $card.NetworkCardDescription
            $changes = 0

            #region Rename network card
            if ($card.NetworkCardName -and $adapter.Name -ne $card.NetworkCardName) {
                Rename-NetAdapter -Name $adapter.Name -NewName $card.NetworkCardName
                $messages += "Renamed network card '$($adapter.InterfaceDescription)' from '$($adapter.Name)' to '$($card.NetworkCardName)'"
                $changes++
            }
            #endregion

            #region Set DNS suffix, an empty string clears it and null leaves it unchanged
            $dnsClient = $dnsClients | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex }
            if ($null -ne $card.NetworkCardDnsSuffix -and [string]$dnsClient.ConnectionSpecificSuffix -ne $card.NetworkCardDnsSuffix) {
                Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -ConnectionSpecificSuffix $card.NetworkCardDnsSuffix
                $messages += "Changed DNS suffix of network card $label from '$($dnsClient.ConnectionSpecificSuffix)' to '$($card.NetworkCardDnsSuffix)'"
                $changes++
            }
            #endregion

            #region Set network category
            if ($card.NetworkCategory) {
                $adapterProfiles = @($netConnectionProfiles | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex })
                if (-not $adapterProfiles.Count) {
                    # Windows only has a network category for a connected network
                    $messages += "Network card $label has no network connection, its network category '$($card.NetworkCategory)' was not set"
                    $changes++
                }
                foreach ($profile in @($adapterProfiles | Where-Object { $_.NetworkCategory -ne $card.NetworkCategory })) {
                    Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory $card.NetworkCategory
                    $messages += "Changed network category of network card $label from '$($profile.NetworkCategory)' to '$($card.NetworkCategory)'"
                    $changes++
                }
            }
            #endregion

            if (-not $changes) { $messages += "Network card $label is already correct" }
        }
        catch {
            $errors += "Failed to configure network card ${label}: $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }