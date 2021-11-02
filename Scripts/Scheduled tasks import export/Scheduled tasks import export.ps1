<#
    .SYNOPSIS
        Export scheduled tasks.

    .DESCRIPTION
        When action is 'Export' the script will export all scheduled tasks
        in a specific folder of the Task Scheduler.

        When action is 'Import' the scheduled tasks found in the $DataFolder
        will be created on the local computer.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER ScheduledTaskFolder
        The folder in the Windows Task Scheduler where the tasks to be exported 
        are stored.

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
    [String]$ScheduledTaskFolder = 'HC'
)

Begin {
    Function Export-ScheduledTaskHC {
        <#
        .SYNOPSIS
            Export scheduled tasks.
    
        .DESCRIPTION
            Export all scheduled tasks in a specific folder to allow them to be 
            backed-up or to be recreated another computer. 
            
            The complete object and the task definition are stored in xml files.
    
        .PARAMETER TaskPath
            The folder in the Task Scheduler in which the tasks resided that 
            will be backed-up.
    
        .PARAMETER ExportFolder
            The folder on the file system where all xml files will be stored.
        #>
    
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
            [String]$ExportFolder,
            [Parameter(Mandatory)]
            [String]$TaskPath
        )
    
        Try {
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
                    $params = @{
                        LiteralPath = "$ExportFilePath.xml"
                        Force       = $true
                        ErrorAction = 'Stop'
                    }
                    $Task | Export-Clixml @params
                    
                    Write-Verbose "Create file '$ExportFileName - Definition.xml'"
                    Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath |
                    Out-File -LiteralPath "$ExportFilePath - Definition.xml" -Force
                    
                    Write-Output "Exported scheduled task '$($Task.TaskName)'"
                }
            }
            else {
                Write-Error "No scheduled tasks found in the Task Scheduler under folder '$TaskPath'"
            }
        }
        Catch {
            throw "Failed to export scheduled tasks: $_"
        }
    }
    Function Import-ScheduledTaskHC {
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
            [String]$ImportFolder
        )
    
        Try {
            $getParams = @{
                Path        = $ImportFolder 
                Filter      = '*.xml' 
                File        = $true
                ErrorAction = 'Stop'
            }
            $Tasks = Get-ChildItem @getParams | Where-Object {
                $_.Name -NotLike '* - Definition.xml'
            }
            Write-Verbose "Retrieved $($Tasks.Count) tasks in folder '$ImportFolder'"
    
            foreach ($T in $Tasks) {
                $Task = Import-Clixml -Path $T.FullName
    
                $params = @{
                    Path      = $T.Directory
                    ChildPath = "$($T.BaseName) - Definition.xml"
                }
                $Xml = Get-Content (Join-Path @params) -Raw -EA Stop
    
                $TaskPath = $Task.TaskPath
    
                Write-Verbose "Create task $(Join-Path $TaskPath $Task.TaskName)"
                $registerParams = @{
                    Xml      = $Xml
                    TaskPath = $TaskPath
                    TaskName = $Task.TaskName
                }
                Register-ScheduledTask @registerParams -Force

                Write-Output "Created scheduled task '$($Task.TaskName)'"
            }
            if (-not $Tasks) {
                Write-Error "No scheduled tasks found in folder '$ImportFolder' to create in the Task Scheduler"
            }
        }
        Catch {
            throw "Failed importing scheduled tasks: $_"
        }
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
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action scheduled tasks failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose 'Export scheduled tasks'
            $params = @{
                ExportFolder = $DataFolder 
                TaskPath     = $ScheduledTaskFolder
            }
            Export-ScheduledTaskHC @params
        }
        else {
            Write-Verbose 'Import scheduled tasks'
            Import-ScheduledTaskHC -ImportFolder $DataFolder
        }
    }
    Catch {
        throw "$Action scheduled tasks failed: $_"
    }
}