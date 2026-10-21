#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Network cards as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers

#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}
$netAdapters = Get-NetAdapter; $netConnectionProfiles = Get-NetConnectionProfile; $dnsClients = Get-DnsClient
if ($Action -eq 'Export') {
    #region Capture section
$cardsToExport = foreach ($adapter in $netAdapters) {
                $NetworkCategory = ($netConnectionProfiles | Where-Object { 
                        $_.InterfaceAlias -eq $adapter.name
                    }).NetworkCategory
                @{
                    NetworkCardName        = $adapter.Name
                    NetworkCardDescription = $adapter.InterfaceDescription
                    NetworkCategory        = [String]$NetworkCategory
                    NetworkCardDnsSuffix   = ($dnsClients | Where-Object {
                            $_.InterfaceIndex -eq $adapter.InterfaceIndex
                        }).ConnectionSpecificSuffix
                }
            }
if (-not $cardsToExport) {
                #region Create example config file
                Write-Verbose 'No network cards found, create template'
                $getParams = @{
                    Path     = Join-Path $PSScriptRoot '..\Examples\NetworkCards.json'
                    Encoding = 'UTF8'
                    Raw      = $true
                }
                $cardsToExport = Get-Content @getParams | 
                ConvertFrom-Json -EA Stop
                #endregion
            } 
            else {
                Write-Verbose "Found $($cardsToExport.Count) network cards:"
                $cardsToExport | ForEach-Object {
                    $M = "Name '$($_.NetworkCardName)' description '$($_.NetworkCardDescription)' network profile '$($_.NetworkCategory)'"
                    Write-Verbose $M; Write-Verbose $M
                }
            }
$exportData = @($cardsToExport)
    #endregion
    $messages = @('Exported Network cards')
}
else {
    #region Apply section
    $messages = @(& {
$NetworkCards = $Data
$NetworkCards | ForEach-Object {
                if ($_.PSobject.Properties.Name -notContains "NetworkCardName") {
                    throw "The field 'NetworkCardName' is required"
                }
                if (-not $_.NetworkCardDescription) {
                    # cannot be blank like the others
                    throw "The field 'NetworkCardDescription' is required"
                }
                if ($_.PSobject.Properties.Name -notContains "NetworkCategory") {
                    throw "The field 'NetworkCategory' is required"
                }
            }
foreach ($card in $NetworkCards) {
                foreach (
                    $adapter in 
                    $netAdapters | Where-Object { 
                        ($_.InterfaceDescription -like "*$($card.NetworkCardDescription)*")
                    }
                ) {
                    #region Rename network card
                    if (
                        ($card.NetworkCardName) -and
                        ($adapter.Name -ne $card.NetworkCardName)
                    ) {
                        $renameParams = @{
                            Name    = $adapter.Name 
                            NewName = $card.NetworkCardName
                        }
                        Rename-NetAdapter @renameParams

                        Write-Output "Renamed network card with description '$($adapter.InterfaceDescription)' from '$($adapter.Name)' to '$($card.NetworkCardName)'"
                    }
                    #endregion

                    #region Set DNS suffix
                    $dnsClient = $dnsClients | Where-Object {
                        $_.InterfaceIndex -eq $adapter.InterfaceIndex
                    }
                    if (
                        ($card.NetworkCardDnsSuffix) -and
                        ($dnsClient.ConnectionSpecificSuffix -ne $card.NetworkCardDnsSuffix)
                    ) {
                        $setDnsParams = @{
                            InterfaceIndex           = $adapter.InterfaceIndex
                            ConnectionSpecificSuffix = $card.NetworkCardDnsSuffix
                        }
                        Set-DnsClient @setDnsParams

                        Write-Output "Changed DNS suffix for network card with id '$($adapter.InterfaceIndex)' and description '$($adapter.InterfaceDescription)' from '$($dnsClient.ConnectionSpecificSuffix)' to '$($card.NetworkCardDnsSuffix)'"
                    }
                    #endregion
                }
            
                #region Set network category
                foreach (
                    $profile in 
                    $netConnectionProfiles | Where-Object {
                        ($card.NetworkCategory) -and
                        ($_.InterfaceAlias -eq $card.NetworkCardName) -and
                        ($_.NetworkCategory -ne $card.NetworkCategory) 
                    }
                ) {
                    $setNetConnectionParams = @{
                        InterfaceIndex  = $profile.InterfaceIndex 
                        NetworkCategory = $card.NetworkCategory
                    }
                    Set-NetConnectionProfile @setNetConnectionParams

                    $M = "Changed network category on card '$($card.NetworkCardName)' from '$($profile.NetworkCategory)' to '$($card.NetworkCategory)'"
                    Write-Verbose $M; Write-Output $M
                }
                #endregion
            }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
