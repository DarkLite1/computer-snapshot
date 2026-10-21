#Requires -Version 5.1
<#
.SYNOPSIS
    Create or restore a single-file computer configuration.
.PARAMETER Action
    CreateSnapshot exports selected items. RestoreSnapshot validates and applies a configuration.
.PARAMETER ConfigurationFile
    JSON file to read or write. Relative paths are resolved from the USB root.
.PARAMETER Items
    Items to capture on export. Defaults to all supported items.
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
    [System.Collections.IDictionary]$Script = [ordered]@{
        StartCustomScriptsBefore = 'Start custom scripts import export.ps1'
        RegionalSettings = 'Regional settings import export.ps1'
        UserAccounts = 'User accounts import export.ps1'
        UserGroups = 'User groups import export.ps1'
        FirewallRules = 'Firewall rules import export.ps1'
        CreateFolders = 'Folders import export.ps1'
        SmbShares = 'Smb shares import export.ps1'
        NetworkCards = 'Network cards import export.ps1'
        NtpTimeServers = 'NTP time servers import export.ps1'
        RegistryKeys = 'Registry keys import export.ps1'
        ScheduledTasks = 'Scheduled tasks import export.ps1'
        CopyFilesFolders = 'Copy files folders import export.ps1'
        Software = 'Software import export.ps1'
        StartCustomScriptsAfter = 'Start custom scripts import export.ps1'
    }
)
Import-Module "$PSScriptRoot\Common\Execution.psm1" -Force
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