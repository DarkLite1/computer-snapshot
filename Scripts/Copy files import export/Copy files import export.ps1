<#
    .SYNOPSIS
        Copy files from one location to another.

    .DESCRIPTION
        When action is 'Export' the script will create an example file that can 
        be used with action set to 'Import'.

        When action is 'Import' the import file is read and all files and 
        folder in the file will be copied.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER FileName
        The file containing the paths to the files or folders to copy, with the 
        from and to fields.

    .PARAMETER DataFolder
        Folder where the export or import file can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Create the example file 'C:\copy\copy.json' that can be used later on 
        with action 'Import'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Read the file 'C:\copy\copy.json' and execute all copy actions defined 
        in the file.
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