#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Scheduled tasks as a configuration section.
.DESCRIPTION
    Export captures the tasks in the '\HC\' task folder and its subfolders,
    each with its complete XML definition and enabled state.

    Import registers each task from its XML, replacing a task with the same
    name and path; Windows only replaces it when the new definition is valid,
    so a failed registration keeps the existing task. Tasks are registered to
    run as SYSTEM. Afterwards each task is enabled or disabled as configured.
    Each failed task is reported in Errors and the remaining tasks are still
    processed.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"
$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}

if ($Action -eq 'Export') {
    #region Capture section
    # A computer without an \HC\ folder has no tasks to export
    $tasks = @(Get-ScheduledTask -TaskPath '\HC\*' -ErrorAction SilentlyContinue)
    $exportData = @(
        foreach ($task in $tasks) {
            try {
                [pscustomobject]@{
                    TaskName = $task.TaskName
                    TaskPath = $task.TaskPath
                    Enabled  = [bool]$task.Settings.Enabled
                    Xml      = [string](Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath)
                }
            }
            catch {
                $errors += "Failed to export scheduled task '$($task.TaskPath)$($task.TaskName)': $($_.Exception.Message)"
            }
        }
    )
    #endregion
    $messages = @("Exported $($exportData.Count) scheduled task(s) from the task folder '\HC\'")
}
else {
    #region Apply section
    foreach ($task in @($Data | Where-Object { $null -ne $_ })) {
        $fullName = "$($task.TaskPath)$($task.TaskName)"
        try {
            $exists = [bool](Get-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue)
            $null = Register-ScheduledTask -Xml $task.Xml -TaskPath $task.TaskPath -TaskName $task.TaskName -User 'NT AUTHORITY\SYSTEM' -Force
            $state = if ($task.Enabled) { 'enabled' } else { 'disabled' }
            if ($task.Enabled) { $null = Enable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName }
            else { $null = Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName }
            if ($exists) { $messages += "Replaced scheduled task '$fullName' ($state)" }
            else { $messages += "Created scheduled task '$fullName' ($state)" }
        }
        catch {
            $errors += "Failed to register scheduled task '$fullName': $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }