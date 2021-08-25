<#
    .SYNOPSIS
        Export or import firewall rules.

    .DESCRIPTION
        This script should be run on a machine that has its firewall rules correctly
        configured with the action 'Export'. This will save the current firewall 
        rules. On another machine this data will be used to restore the firewal rules.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when action is
        'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the firewall rules

    .EXAMPLE
        & 'C:\ImportExportFirewallRules.ps1' -DataFolder 'C:\FirewallRules' -Action 'Export'

        Export all firewall rules on the current machine to the folder 'FirewallRules'

    .EXAMPLE
        & 'C:\ImportExportFirewallRules.ps1' -DataFolder 'C:\FirewallRules' -Action 'Import'

        Restore all firewall rules in the folder 'FirewallRules' to the local machine
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$ScriptName = 'Firewall rules',
    [String]$FirewallManagerModule = "$PSScriptRoot\Firewall-Manager",
    [String]$FileName = 'FirewallRules.csv'
)

Begin {
    Try {
        Write-Verbose "Start script '$ScriptName'"

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
                throw "Firewall rules file '$smbSharesFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action firewall rules failed: $_"
    }
}

Process {
    Try {
        #region Import firewall manager module
        Try {
            Import-Module -Name $FirewallManagerModule -ErrorAction Stop -Verbose:$false -Force
        }
        Catch {
            throw "Firewall manager module folder '$FirewallManagerModule' not found"
        }
        #endregion

        If ($Action -eq 'Export') {
            Write-Verbose "Export firewal rules to file '$csvFile'"
            Export-FirewallRules -CSVFile $csvFile
        }
        else {
            Write-Verbose "Import firewal rules from file '$csvFile'"
            Import-FirewallRules -CSVFile $csvFile
        }

        Write-Verbose "End script '$ScriptName'"
    }
    Catch {
        throw "$Action firewall rules failed: $_"
    }
}