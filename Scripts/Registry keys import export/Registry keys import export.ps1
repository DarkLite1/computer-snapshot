<#
    .SYNOPSIS
        Create registry keys.

    .DESCRIPTION
        Read the registry keys from an input file on one machine and set the 
        registry keys from the same file on another machine.
        
    .PARAMETER Action
        When action is 'Export' a template file is created that can be edited 
        by the user to contain the required registry keys. 
        When action is 'Import' the registry keys in the import file will be 
        created or updated on the current machine. 

    .PARAMETER DataFolder
        Folder where the file can be found that contains the registry keys.

    .PARAMETER RegistryKeysFileName
        File containing the registry keys.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$RegistryKeysFileName = 'registryKeys.json'
)

Begin {
    Try {
        $RegistryKeysFile = Join-Path -Path $DataFolder -ChildPath $RegistryKeysFileName

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
            If (-not (Test-Path -LiteralPath $RegistryKeysFile -PathType Leaf)) {
                throw "Registry keys file '$RegistryKeysFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action NTP servers failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            @(
                @{
                    Path  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
                    Name  = 'dontdisplaylastusername'
                    Value = '1'
                    Type  = 'DWORD'
                }
            ) | 
            ConvertTo-Json | Out-File -LiteralPath $RegistryKeysFile -Encoding utf8

            Write-Output 'Exported registry keys example'
        }
        else {            
            Write-Verbose "Import registry keys from file '$RegistryKeysFile'"
            $ntp = Get-Content -LiteralPath $RegistryKeysFile -Encoding UTF8 -Raw | 
            ConvertFrom-Json -EA Stop
     
        }
    }
    Catch {
        throw "$Action NTP servers failed: $_"
    }
}