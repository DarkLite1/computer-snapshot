<#
    .SYNOPSIS
        Export or import user rules.

    .DESCRIPTION
        This script should be run on a machine that has all the required
        users already created on the computer. Then run the script with action
        'Export' which will create a file containing the user accounts.
        On another machine this script can be run with action 'Import' to
        recreate the required user accounts.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the user accounts

    .EXAMPLE
        & 'C:\UserAccounts.ps1' -DataFolder 'C:\UserAccounts' -Action 'Export'

        Export all user accounts on the current computer to the folder 
        'C:\UserAccounts'

    .EXAMPLE
        & 'C:\UserAccounts.ps1' -DataFolder 'C:\UserAccounts' -Action 'Import'

        Restore all user accounts in the folder 'C:\UserAccounts' on the current computer
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'UserAccounts.csv'
)

Begin {
    Try {
        $csvFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            If (-not (Test-Path -LiteralPath $csvFile -PathType Leaf)) {
                throw "User accounts file '$csvFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action user accounts failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose "Export user accounts to file '$csvFile'"
            If ($users = Get-LocalUser | Where-Object {$_.Enabled}) {
                $users | ForEach-Object {
                    Write-Verbose "User account '$($_.Name)' description '$($_.description)'"
                }
                $exportParams = @{
                    LiteralPath       = $csvFile 
                    Encoding          = 'UTF8'
                    NoTypeInformation = $true
                    Delimiter         = ';'
                }
                Write-Verbose "Export to file '$csvFile'"
                $users | Export-Csv @exportParams
            }
            else {
                throw 'No local user accounts found'
            }
        }
        else {
            Write-Verbose "Import user accounts from file '$csvFile'"
            
        }
    }
    Catch {
        throw "$Action user accounts failed: $_"
    }
}