#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Regional settings as a configuration section.
.DESCRIPTION
    Import sets the system locale, the time zone, the country or region and
    the regional format, each independently: a setting that fails is reported
    in Errors and the other settings are still applied. Afterwards the current
    user's regional settings are copied to the default profile, so accounts
    created later get them too.
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
Function Start-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
            [String]$Path
        )
        & $Path
    }
#endregion
$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}
$NewAccountsScript = Join-Path $PSScriptRoot 'Regional settings new accounts.ps1'
if ($Action -eq 'Export') {
    #region Capture section
    $exportData = [ordered]@{
        WinSystemLocaleName  = (Get-WinSystemLocale).Name
        TimeZoneId           = (Get-TimeZone).Id
        WinHomeLocationGeoId = (Get-WinHomeLocation).GeoId
        CultureName          = (Get-Culture).Name
    }
    #endregion
    $messages = @('Exported Regional settings')
}
else {
    #region Apply section
    # The schema requires all four settings together
    $missing = @('WinSystemLocaleName', 'TimeZoneId', 'WinHomeLocationGeoId', 'CultureName' | Where-Object { -not $Data.$_ })
    if ($missing.Count) {
        $errors += "Nothing was changed, these required fields are missing: $($missing -join ', ')"
    }
    else {
        #region System locale (language for non-Unicode programs)
        try {
            $old = (Get-WinSystemLocale).Name
            if ($old -ne $Data.WinSystemLocaleName) {
                Set-WinSystemLocale -SystemLocale $Data.WinSystemLocaleName
                $messages += "Changed the system locale from '$old' to '$($Data.WinSystemLocaleName)', this takes effect after the computer is restarted"
            }
            else { $messages += "System locale '$old' is already correct" }
        }
        catch { $errors += "Failed to set the system locale to '$($Data.WinSystemLocaleName)': $($_.Exception.Message)" }
        #endregion

        #region Time zone
        try {
            $old = (Get-TimeZone).Id
            if ($old -ne $Data.TimeZoneId) {
                Set-TimeZone -Id $Data.TimeZoneId
                $messages += "Changed the time zone from '$old' to '$($Data.TimeZoneId)'"
            }
            else { $messages += "Time zone '$old' is already correct" }
        }
        catch { $errors += "Failed to set the time zone to '$($Data.TimeZoneId)': $($_.Exception.Message)" }
        #endregion

        #region Country or region
        try {
            $old = Get-WinHomeLocation
            if ($old.GeoId -ne $Data.WinHomeLocationGeoId) {
                Set-WinHomeLocation -GeoId $Data.WinHomeLocationGeoId
                $messages += "Changed the country or region from '$($old.GeoId) - $($old.HomeLocation)' to '$($Data.WinHomeLocationGeoId)'"
            }
            else { $messages += "Country or region '$($old.GeoId) - $($old.HomeLocation)' is already correct" }
        }
        catch { $errors += "Failed to set the country or region to '$($Data.WinHomeLocationGeoId)': $($_.Exception.Message)" }
        #endregion

        #region Regional format
        try {
            $old = (Get-Culture).Name
            if ($old -ne $Data.CultureName) {
                Set-Culture -CultureInfo $Data.CultureName
                $messages += "Changed the regional format from '$old' to '$($Data.CultureName)'"
            }
            else { $messages += "Regional format '$old' is already correct" }
        }
        catch { $errors += "Failed to set the regional format to '$($Data.CultureName)': $($_.Exception.Message)" }
        #endregion

        #region Copy the current user's settings to accounts created later
        try {
            $messages += @(Start-ScriptHC -Path $NewAccountsScript)
        }
        catch { $errors += "Failed to apply the regional settings to new accounts: $($_.Exception.Message)" }
        #endregion
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }