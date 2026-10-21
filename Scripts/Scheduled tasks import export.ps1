#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Scheduled tasks as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers

#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$exportData = @(foreach ($task in Get-ScheduledTask -TaskPath '\HC\*') {
    [pscustomobject]@{
        TaskName = $task.TaskName
        TaskPath = $task.TaskPath
        Enabled = [bool]$task.Settings.Enabled
        Xml = [string](Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath)
    }
})
    #endregion
    $messages = @('Exported Scheduled tasks')
}
else {
    #region Apply section
    $messages = @(& {
foreach ($task in $Data) {
    $null = Register-ScheduledTask -Xml $task.Xml -TaskPath $task.TaskPath -TaskName $task.TaskName -User 'NT AUTHORITY\SYSTEM' -Force -ErrorAction Stop
    if ($task.Enabled) { $null = Enable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName }
    else { $null = Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName }
    Write-Output "Created scheduled task '$($task.TaskName)'"
}
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
