<#
    .SYNOPSIS
        Execute custom PowerShell scripts.

    .DESCRIPTION
        This script will execute custom PowerShell scripts that are found in the import folder.

    .PARAMETER Action
        When action is 'Export' example .ps1 files will be saved in the data 
        folder. When action is 'Import' the .ps1 scripts in the data folder 
        are simply executed.

    .PARAMETER DataFolder
        Folder where the PowerShell scripts can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\scripts'
        }
        & 'C:\script.ps1' @params

        Add .ps1 example files in the folder 'C:\scripts'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\scripts'
        }
        & 'C:\script.ps1' @params

        The .ps1 files found in the folder 'C:\scripts' will be executed.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder
)

Begin {
    Function Invoke-ScriptHC {
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )

        Write-Output "Invoke script '$Path'"
        & $Path
    }

    Try {
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
            If (
                (Get-ChildItem -Path $DataFolder -Filter '*.ps1' | 
                Measure-Object).Count -eq 0
            ) {
                throw "Import folder '$DataFolder' empty: No PowerShell files found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            #region Create example files
            Write-Verbose 'Create example copy file'
            $params = @{
                Path        = Join-Path $PSScriptRoot 'Examples\*'
                Destination = $DataFolder
                Recurse     = $true
                Force       = $true
            }
            Copy-Item @params
            Write-Output 'Created example script files in folder '$DataFolder'. Please update them as required or create new ones.'
            #endregion
        }
        else {
            $scriptsToExecute = Get-ChildItem -Path $DataFolder -Filter '*.ps1' 

            foreach ($script in $scriptsToExecute) {
                try {
                    Invoke-ScriptHC -Path $script.FullName
                }
                catch {
                    Write-Error "Failed to execute script '$($script.Name)': $_"
                }
            }
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}