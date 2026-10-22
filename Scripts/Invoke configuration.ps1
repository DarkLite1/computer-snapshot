#Requires -Version 5.1
<#
.SYNOPSIS
    Select and restore a version-2 configuration.
.PARAMETER ConfigurationFile
    Optional configuration file. Without it, show the configuration picker.
.PARAMETER ConfigurationsFolder
    Folder to list, defaulting to Configurations under the USB root.
.PARAMETER StartScript
    Main execution script. Defaults to the bundled Invoke scripts script.
.PARAMETER Confirm
    Skip the interactive confirmation question.
.PARAMETER Items
    Restore only these sections. Omit to restore all sections in the configuration.
.PARAMETER RebootComputer
    Override the saved restart setting for this run only.
.PARAMETER OpenReportInBrowser
    Override the saved report-opening setting for this run only.
#>
[CmdletBinding()]
param(
    [string]$ConfigurationFile,
    [string]$ConfigurationsFolder,
    [string]$StartScript = "$PSScriptRoot\Invoke scripts.ps1",
    [switch]$Confirm,
    [string[]]$Items,
    [bool]$RebootComputer,
    [bool]$OpenReportInBrowser
)
Import-Module "$PSScriptRoot\Common\Configuration.psm1" -Force
. "$PSScriptRoot\Common\Section.ps1"
function Test-IsStartedElevatedHC {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Invoke-ScriptHC {
    param([string]$Path, [hashtable]$Arguments)
    & $Path @Arguments
}
$rootFolder = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $StartScript -PathType Leaf)) { throw "Start script '$StartScript' not found" }
if (-not $ConfigurationFile) {
    if (-not $ConfigurationsFolder) { $ConfigurationsFolder = Join-Path $rootFolder 'Configurations' }
    $entries = @(foreach ($file in Get-ChildItem -LiteralPath $ConfigurationsFolder -Filter '*.json' -File -ErrorAction Stop | Where-Object { $_.Name -notlike '*.v1.json' }) {
        try { $description = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop).Description }
        catch { $description = 'Invalid JSON' }
        [pscustomobject]@{ Name = $file.BaseName; Description = $description; Path = $file.FullName }
    })
    if (-not $entries.Count) { throw "No configurations found in '$ConfigurationsFolder'" }
    $selected = $entries | Out-GridView -Title 'Select a configuration to restore' -OutputMode Single
    if (-not $selected) { return }
    $ConfigurationFile = $selected.Path
}
$configurationPath = Resolve-RootPathHC $ConfigurationFile $rootFolder
$configuration = Read-ConfigurationHC -Path $configurationPath -RootFolder $rootFolder -Items $Items
$problems = @(Test-ConfigurationHC $configuration $rootFolder)
if ($problems.Count) { throw ($problems -join [Environment]::NewLine) }
if (-not $Confirm -and (Read-Host "Restore '$configurationPath'? (y/n)") -ne 'y') { return }
if ($configuration.Settings.RunElevated -and -not (Test-IsStartedElevatedHC)) {
    $command = "& '{0}' -ConfigurationFile '{1}' -StartScript '{2}' -Confirm" -f $PSCommandPath.Replace("'", "''"), $configurationPath.Replace("'", "''"), $StartScript.Replace("'", "''")
    if ($null -ne $Items) {
        $itemArguments = ($Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
        $command += " -Items @($itemArguments)"
    }
    foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
        if ($PSBoundParameters.ContainsKey($setting)) {
            $command += " -{0} `${1}" -f $setting, $PSBoundParameters[$setting].ToString().ToLowerInvariant()
        }
    }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    return
}
$arguments = @{ Action = 'RestoreSnapshot'; ConfigurationFile = $configurationPath }
if ($null -ne $Items) { $arguments.Items = $Items }
foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
    if ($PSBoundParameters.ContainsKey($setting)) { $arguments[$setting] = $PSBoundParameters[$setting] }
}
Invoke-ScriptHC -Path $StartScript -Arguments $arguments