#Requires -Version 5.1
<#
.SYNOPSIS
    Create or restore a single-file computer configuration.
.PARAMETER Action
    CreateSnapshot exports selected items. RestoreSnapshot validates and applies a configuration.
.PARAMETER ConfigurationFile
    JSON file to read or write. Relative paths are resolved from the USB root.
.PARAMETER Items
    Sections to export or restore. Defaults to all supported export items or all sections in the restore configuration.
.PARAMETER ReportsFolder
    Report folder, relative to this script when not absolute.
.PARAMETER Force
    Allow replacing an existing export configuration.
.PARAMETER RebootComputer
    Restart after a restore in which nothing failed, with a countdown that
    'shutdown /a' cancels. Exports never restart. When omitted, restore
    uses Settings.RebootComputer.
.PARAMETER RestartDelaySeconds
    Countdown before the restart, 0 to 600 seconds. When omitted, restore
    uses Settings.RestartDelaySeconds (default 60).
.PARAMETER OpenReportInBrowser
    Open the report. When omitted, restore uses Settings.OpenReportInBrowser.
.PARAMETER ExportOptions
    Export only: options per section, for example
    @{ ScheduledTasks = @{ TaskPath = '\HC\', '\Vendor\' } }.
.PARAMETER AnswerFile
    Restore only: JSON answers keyed by complete placeholders. Missing answers
    are prompted for unless Unattended is set. Relative paths use the USB root.
.PARAMETER Unattended
    Restore only: fail on missing answers, suppress browser opening, and fail
    without administrator rights instead of requesting UAC.
.PARAMETER Script
    Item-to-script map; intended for testing and controlled customization.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('CreateSnapshot', 'RestoreSnapshot')][string]$Action,
    [Parameter(Mandatory)][string]$ConfigurationFile,
    [string[]]$Items,
    [string]$ReportsFolder = '..\Log',
    [bool]$RebootComputer = $false,
    [ValidateRange(0, 600)]
    [int]$RestartDelaySeconds = 60,
    [bool]$OpenReportInBrowser = $true,
    [switch]$Force,
    [System.Collections.IDictionary]$ExportOptions,
    [string]$AnswerFile,
    [switch]$Unattended,
    [System.Collections.IDictionary]$Script
)
Import-Module "$PSScriptRoot\Common\Execution.psm1" -Force
. "$PSScriptRoot\Common\Section.ps1"
if (-not $PSBoundParameters.ContainsKey('Script')) { $Script = Get-SnapshotScriptsHC }
$rootFolder = Split-Path $PSScriptRoot -Parent
$resolvedScripts = [ordered]@{}
foreach ($name in $Script.Keys) {
    $resolvedScripts[$name] = if ([IO.Path]::IsPathRooted($Script[$name])) { $Script[$name] } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Script[$name])) }
}
if (-not [IO.Path]::IsPathRooted($ReportsFolder)) { $ReportsFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $ReportsFolder)) }
$arguments = @{
    Action = $Action; ConfigurationFile = $ConfigurationFile; Items = $Items; RootFolder = $rootFolder
    Script = $resolvedScripts; ReportsFolder = $ReportsFolder; Force = $Force
}
foreach ($setting in @('RebootComputer', 'RestartDelaySeconds', 'OpenReportInBrowser', 'ExportOptions', 'AnswerFile', 'Unattended')) {
    if ($PSBoundParameters.ContainsKey($setting)) { $arguments[$setting] = $PSBoundParameters[$setting] }
}
Invoke-ComputerSnapshotHC @arguments