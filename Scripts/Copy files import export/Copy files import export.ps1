<#
    .SYNOPSIS
        Export scheduled tasks.

    .DESCRIPTION
        When action is 'Export' the script will export all scheduled tasks
        in a specific folder of the Task Scheduler.

        When action is 'Import' the scheduled tasks are created the local 
        computer.

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
    [String]$ScriptFolder = 'C:\PowerShell'
)

Begin {
    Function Export-ScheduledTaskHC {
        <#
        .SYNOPSIS
            Export scheduled tasks.
    
        .DESCRIPTION
            Export all scheduled tasks in a specific folder to allow them to be 
            backed-up or to be able to import them on another machine. The complete 
            object and the task definition are stored in xml files.
    
        .PARAMETER TaskPath
            The folder in the Task Scheduler in which the tasks resided that will 
            be backed-up.
    
        .PARAMETER ExportFolder
            The folder on the file system where all xml files will be stored.
        #>
    
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [String]$ExportFolder,
            [String]$TaskPath = 'HC'
        )
    
        Try {
            $null = New-Item -Path $ExportFolder -ItemType Directory -Force -EA Ignore
    
            $Tasks = Get-ScheduledTask -TaskPath "\$TaskPath\*"
            Write-Verbose "Retrieved $($Tasks.Count) tasks in folder '$TaskPath'"
    
            if ($Tasks) {
                Write-Verbose "Export tasks to folder '$ExportFolder'"
                $i = 0
    
                Foreach ($Task in $Tasks) {
                    $i++
                    $ExportFileName = "$i - $($Task.TaskName)"
                    $ExportFilePath = Join-Path -Path $ExportFolder -ChildPath $ExportFileName
    
                    Write-Verbose "Create file '$ExportFileName.xml'"
                    $Params = @{
                        LiteralPath = "$ExportFilePath.xml"
                        Force       = $true
                        ErrorAction = 'Stop'
                    }
                    $Task | Export-Clixml @Params
    
                    Write-Verbose "Create file '$ExportFileName - Definition.xml'"
                    Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath |
                    Out-File -LiteralPath "$ExportFilePath - Definition.xml" -Force
    
                }
            }
        }
        Catch {
            throw "Failed to export scheduled tasks: $_"
        }
    }

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
            if (-not (Test-Path -Path $ScriptFolder -PathType Container)) {
                New-Item $ScriptFolder -ItemType Directory -EA Stop
            }
            Write-Verbose "Copy PowerShell script '$ExportScriptFile' to ''"
            Write-Verbose "Create scheduled task"
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}