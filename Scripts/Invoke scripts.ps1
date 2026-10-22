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
    Reboot after a successful export. Restore uses Settings.RebootComputer.
.PARAMETER OpenReportInBrowser
    Open the export report. Restore uses Settings.OpenReportInBrowser.
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
    [bool]$OpenReportInBrowser = $true,
    [switch]$Force,
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
    RebootComputer = $RebootComputer; OpenReportInBrowser = $OpenReportInBrowser
}
Invoke-ComputerSnapshotHC @arguments