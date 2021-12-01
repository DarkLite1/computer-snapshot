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

            $WinSystemLocaleName = $importFile.WinSystemLocaleName
            Set-WinSystemLocale -SystemLocale $WinSystemLocaleName
            Write-Output "Regional format set to '$WinSystemLocaleName'"

            $TimeZoneId = $importFile.TimeZoneId
            Set-TimeZone -Id $TimeZoneId
            Write-Output "Time zone set to '$TimeZoneId'"

            $WinHomeLocationGeoId = $importFile.WinHomeLocationGeoId
            Set-WinHomeLocation -GeoId $WinHomeLocationGeoId
            Write-Output "Country/region set to GeoId '$WinHomeLocationGeoId'"

            $CultureName = $importFile.CultureName
            Set-Culture $CultureName
            Write-Output "Region format set to '$CultureName'"

            Write-Output 'Changes take effect after the computer is restarted'
        }
    }
    Catch {
        $errorMessage = $_
        $Error.RemoveAt(0)
        throw "$Action failed: $errorMessage"
    }
}