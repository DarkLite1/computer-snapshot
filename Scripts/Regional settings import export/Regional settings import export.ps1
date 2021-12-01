<#
    .SYNOPSIS
        Create a backup of the regional settings and or restore them.

    .DESCRIPTION
        When action is 'Export' the regional settings of the computer are 
        exported. When action is 'Import' the regional settings found in the 
        input file are restored.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER FileName
        The file containing the regional settings that will be exported or need
        to be restored.

    .PARAMETER DataFolder
        Folder where the export or import file can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\folder'
            FileName   = 'RegionalSettings.json'
        }
        & 'C:\script.ps1' @params

        Export the regional settings on the current computer to the file 
        'C:\folder\RegionalSettings.json'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\folder'
            FileName   = 'RegionalSettings.json'
        }
        & 'C:\script.ps1' @params

        Restore the regional settings found in the file 
        'C:\folder\RegionalSettings.json' on the current computer.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'RegionalSettings.json'
)

Begin {
    Try {
        $ExportFile = Join-Path -Path $DataFolder -ChildPath $FileName

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
                throw "Import file '$ExportFile' not found"
            }
        }
        #endregion
    }
    Catch {
        $errorMessage = $_
        $Error.RemoveAt(0)
        throw "$Action failed: $errorMessage"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose "Export regional settings to file '$ExportFile'"
            (
                @{
                    WinSystemLocaleName  = (Get-WinSystemLocale).Name
                    TimeZoneId           = (Get-TimeZone).Id
                    WinHomeLocationGeoId = (Get-WinHomeLocation).GeoId
                    CultureName          = (Get-Culture).Name
                }
            ) | 
            ConvertTo-Json | 
            Out-File -LiteralPath $ExportFile -Encoding utf8
        }
        else {
            $importFile = Get-Content -Path $ExportFile -Raw | 
            ConvertFrom-Json

            #region Test required fields
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
            #endregion

            #region Set WinSystemLocale
            $oldWinSystemLocaleName = (Get-WinSystemLocale).Name
            $newWinSystemLocaleName = $importFile.WinSystemLocaleName
            if ($oldWinSystemLocaleName -ne $newWinSystemLocaleName) {
                Set-WinSystemLocale -SystemLocale $newWinSystemLocaleName
                Write-Output "Changed regional format from '$oldWinSystemLocaleName' to '$newWinSystemLocaleName'"
            }
            else {
                Write-Output "Regional format '$oldWinSystemLocaleName' is already correct"
            }
            #endregion

            #region Set TimeZone
            $oldTimeZoneId = (Get-TimeZone).Id
            $newTimeZoneId = $importFile.TimeZoneId
            if ($oldTimeZoneId -ne $newTimeZoneId) {
                Set-TimeZone -Id $newTimeZoneId
                Write-Output "Changed time zone from '$oldTimeZoneId' to '$newTimeZoneId'"
            }
            else {
                Write-Output "Time zone '$oldTimeZoneId' is already correct"
            }
            #endregion

            #region Set WinHomeLocation
            $oldWinHomeLocation = Get-WinHomeLocation
            $newWinHomeLocationGeoId = $importFile.WinHomeLocationGeoId
            if ($oldWinHomeLocation.GeoId -ne $newWinHomeLocationGeoId) {
                Set-WinHomeLocation -GeoId $newWinHomeLocationGeoId
                Write-Output "Changed country/region from '$($oldWinHomeLocation.GeoId) - $($oldWinHomeLocation.HomeLocation)' to '$newWinHomeLocationGeoId'"
            }
            else {
                Write-Output "Country/region '$($oldWinHomeLocation.GeoId) - $($oldWinHomeLocation.HomeLocation)' is already correct"
            }
            #endregion

            #region Set Culture
            $oldCultureName = (Get-Culture).Name
            $newCultureName = $importFile.CultureName
            if ($oldCultureName -ne $newCultureName) {
                Set-Culture -CultureInfo $newCultureName
                Write-Output "Changed region format from '$oldCultureName' to '$newCultureName'"
            }
            else {
                Write-Output "Region format '$oldCultureName' is already correct"
            }
            #endregion

            Write-Output 'Changes take effect after the computer is restarted'
        }
    }
    Catch {
        $errorMessage = $_
        $Error.RemoveAt(0)
        throw "$Action failed: $errorMessage"
    }
}