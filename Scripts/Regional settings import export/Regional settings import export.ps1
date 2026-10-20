#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Regional settings as a configuration section.
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
. "$PSScriptRoot\..\Common\Section.ps1"
#region Windows helpers
Function Start-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
            [String]$Path
        )
        try {
            & $Path
        }
        catch {
            throw "Failed to execute script '$Path': $_"
        }
    }
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}
$NewAccountsScript = Join-Path $PSScriptRoot 'Regional settings new accounts.ps1'
if ($Action -eq 'Export') {
    #region Capture section
$exportData = [ordered]@{
    WinSystemLocaleName = (Get-WinSystemLocale).Name
    TimeZoneId = (Get-TimeZone).Id
    WinHomeLocationGeoId = (Get-WinHomeLocation).GeoId
    CultureName = (Get-Culture).Name
}
    #endregion
    $messages = @('Exported Regional settings')
}
else {
    #region Apply section
    $messages = @(& {
$importFile = $Data
try {
                if (-not $importFile.WinSystemLocaleName) {
                    throw "The field 'WinSystemLocaleName' is required"
                }
                if (-not $importFile.TimeZoneId) {
                    throw "The field 'TimeZoneId' is required"
                }
                if (-not $importFile.CultureName) {
                    throw "The field 'CultureName' is required"
                }
                if (-not $importFile.WinHomeLocationGeoId) {
                    throw "The field 'WinHomeLocationGeoId' is required"
                }                
            }
            catch {
                $errorMessage = $_
                $Error.RemoveAt(0)
                throw "The following fields are required 'WinSystemLocaleName', 'TimeZoneId', 'CultureName' and 'WinHomeLocationGeoId': $errorMessage"
            }
$rebootRequired = $false
$oldWinSystemLocaleName = (Get-WinSystemLocale).Name
$newWinSystemLocaleName = $importFile.WinSystemLocaleName
if ($oldWinSystemLocaleName -ne $newWinSystemLocaleName) {
                Set-WinSystemLocale -SystemLocale $newWinSystemLocaleName
                Write-Output "Changed regional format from '$oldWinSystemLocaleName' to '$newWinSystemLocaleName'"
                $rebootRequired = $true
            }
            else {
                Write-Output "Regional format '$oldWinSystemLocaleName' is already correct"
            }
$oldTimeZoneId = (Get-TimeZone).Id
$newTimeZoneId = $importFile.TimeZoneId
if ($oldTimeZoneId -ne $newTimeZoneId) {
                Set-TimeZone -Id $newTimeZoneId
                Write-Output "Changed time zone from '$oldTimeZoneId' to '$newTimeZoneId'"
                $rebootRequired = $true
            }
            else {
                Write-Output "Time zone '$oldTimeZoneId' is already correct"
            }
$oldWinHomeLocation = Get-WinHomeLocation
$newWinHomeLocationGeoId = $importFile.WinHomeLocationGeoId
if ($oldWinHomeLocation.GeoId -ne $newWinHomeLocationGeoId) {
                Set-WinHomeLocation -GeoId $newWinHomeLocationGeoId
                Write-Output "Changed country/region from '$($oldWinHomeLocation.GeoId) - $($oldWinHomeLocation.HomeLocation)' to '$newWinHomeLocationGeoId'"
                $rebootRequired = $true
            }
            else {
                Write-Output "Country/region '$($oldWinHomeLocation.GeoId) - $($oldWinHomeLocation.HomeLocation)' is already correct"
            }
$oldCultureName = (Get-Culture).Name
$newCultureName = $importFile.CultureName
if ($oldCultureName -ne $newCultureName) {
                Set-Culture -CultureInfo $newCultureName
                Write-Output "Changed region format from '$oldCultureName' to '$newCultureName'"
                $rebootRequired = $true
            }
            else {
                Write-Output "Region format '$oldCultureName' is already correct"
            }
if ($rebootRequired) {
                Write-Output 'Changes take effect after the computer is restarted'
            }
Start-ScriptHC -Path $NewAccountsScript
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
