<#
    .SYNOPSIS
        Export a script and a scheduled task.

    .DESCRIPTION
        When action is 'Export' the script will create 2 files in the data 
        folder: one file containing the script to execute and another file
        containing the configuration for the scheduled task that will 
        trigger the script.

        When action is 'Import' a scheduled task is created and the script
        to execute is copied to the local computer.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER ScriptFileName
        The script that will be copied to the local computer and that will get
        executed when the scheduled task is triggered.

    .PARAMETER ScheduledTaskFileName
        The configuration for the scheduled task containing the path to the 
        script, when to start the script, ... .

    .PARAMETER DataFolder
        Folder where the export or import files can be found.

    .EXAMPLE
        $exportParams = @{
            Action     = 'Export'
            DataFolder = 'C:\Monitor SSD'
        }
        & 'C:\Monitor SSD.ps1' @exportParams

        Create a script file and a scheduled task configuration file in the 
        export folder.

    .EXAMPLE
        $importParams = @{
            Action     = 'Import'
            DataFolder = 'C:\Monitor SSD'
        }
        & 'C:\Monitor SSD.ps1' @exportParams

        Create the scheduled task and copy the script file to the local 
        computer.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$ScriptFileName = 'Monitor SSD.ps1',
    [String]$ScheduledTaskFileName = 'Monitor SSD scheduled task.json',
    [String]$DestinationFolder = 'C:\PowerShell'
)

Begin {
    Try {
        $ExportScriptFile = Join-Path -Path $DataFolder -ChildPath $ScriptFileName
        $ScheduledTaskFile = Join-Path -Path $DataFolder -ChildPath $ScheduledTaskFileName

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
            If (-not (Test-Path -LiteralPath $ExportScriptFile -PathType Leaf)) {
                throw "PowerShell script file '$ExportScriptFile' not found"
            }
            If (-not (Test-Path -LiteralPath $ScheduledTaskFile -PathType Leaf)) {
                throw "Scheduled task configuration file '$ScheduledTaskFile' not found"
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
            Write-Verbose "Export PowerShell script to file '$ExportScriptFile'"
            Write-Verbose "Export scheduled task file '$ScheduledTaskFile'"
        }
        else {
            Write-Verbose "Copy PowerShell script '$ExportScriptFile' to ''"
            Write-Verbose "Create scheduled task"
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}