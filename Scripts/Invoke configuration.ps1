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
.PARAMETER SkipConfirmation
    Restore without asking for confirmation first. The old name -Confirm
    still works, for existing shortcuts.
.PARAMETER Items
    Restore only these sections. Omit to restore all sections in the
    configuration.
.PARAMETER RebootComputer
    Override the saved restart setting for this run only.
.PARAMETER RestartDelaySeconds
    Override the saved restart countdown (0 to 600 seconds) for this run
    only.
.PARAMETER OpenReportInBrowser
    Override the saved report-opening setting for this run only.
.PARAMETER AnswerFile
    JSON answers keyed by complete placeholders. Missing answers are prompted
    for unless Unattended is set. Relative paths use the USB root.
.PARAMETER AnswerPipe
    The named pipe on which the wizard serves the answers of its questions
    page. When they cannot be received, the restore asks for them.
.PARAMETER SkipSoftwareInstall
    The Software.Install entries not to run, by their position from 0, such
    as the ones unchecked in the wizard.
.PARAMETER Unattended
    Skip confirmation, fail on missing answers, do not open the report
    browser, and fail without administrator rights instead of requesting
    UAC. Requires an explicit ConfigurationFile.
#>
[CmdletBinding()]
param(
    [string]$ConfigurationFile,
    [string]$ConfigurationsFolder,
    [string]$StartScript = "$PSScriptRoot\Invoke scripts.ps1",
    [Alias('Confirm')]
    [switch]$SkipConfirmation,
    [string[]]$Items,
    [bool]$RebootComputer,
    [ValidateRange(0, 600)]
    [int]$RestartDelaySeconds,
    [bool]$OpenReportInBrowser,
    [string]$AnswerFile,
    [string]$AnswerPipe,
    [int[]]$SkipSoftwareInstall,
    [switch]$Unattended
)
Import-Module "$PSScriptRoot\Common\Configuration.psm1" -Force
. "$PSScriptRoot\Common\Section.ps1"
. "$PSScriptRoot\Common\RestoreInput.ps1"

function Invoke-ScriptHC {
    param([string]$Path, [hashtable]$Arguments)
    & $Path @Arguments
}

$rootFolder = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $StartScript -PathType Leaf)) {
    throw "Start script '$StartScript' not found"
}

#region Select a configuration
if (-not $ConfigurationFile) {
    if ($Unattended) {
        throw (
            'Unattended restore requires ConfigurationFile; the ' +
            'configuration picker will not be shown.'
        )
    }
    if (-not $ConfigurationsFolder) {
        $ConfigurationsFolder = Join-Path $rootFolder 'Configurations'
    }
    Write-Verbose "List configurations in '$ConfigurationsFolder'"
    $params = @{
        LiteralPath = $ConfigurationsFolder
        Filter      = '*.json'
        File        = $true
        ErrorAction = 'Stop'
    }
    $files = Get-ChildItem @params |
    Where-Object { $_.Name -notlike '*.v1.json' }
    $entries = @(foreach ($file in $files) {
            try {
                $params = @{
                    LiteralPath = $file.FullName
                    Raw         = $true
                    Encoding    = 'UTF8'
                }
                $description = (
                    Get-Content @params | ConvertFrom-Json -ErrorAction Stop
                ).Description
            }
            catch { $description = 'Invalid JSON' }
            [pscustomobject]@{
                Name        = $file.BaseName
                Description = $description
                Path        = $file.FullName
            }
        })
    if (-not $entries.Count) {
        throw "No configurations found in '$ConfigurationsFolder'"
    }
    $selected = $entries |
    Out-GridView -Title 'Select a configuration to restore' -OutputMode Single
    if (-not $selected) {
        Write-Verbose 'No configuration selected, stop'
        return
    }
    $ConfigurationFile = $selected.Path
}
#endregion

if ($Unattended -and -not (Test-ElevatedHC)) {
    throw (
        'Unattended restore requires administrator rights. Start ' +
        'PowerShell as administrator first; UAC will not be requested.'
    )
}
$configurationPath = Resolve-RootPathHC $ConfigurationFile $rootFolder
Write-Verbose "Configuration '$configurationPath'"
if ($PSBoundParameters.ContainsKey('AnswerFile')) {
    if ([string]::IsNullOrWhiteSpace($AnswerFile)) {
        throw 'AnswerFile must not be empty.'
    }
    $AnswerFile = Resolve-RootPathHC $AnswerFile $rootFolder
    Write-Verbose "Answer file '$AnswerFile'"
}

#region Read and test the configuration
Write-Verbose 'Read and test the configuration'
$params = @{
    Path       = $configurationPath
    RootFolder = $rootFolder
    Items      = $Items
}
$configuration = Read-ConfigurationHC @params

# Placeholders are checked after the answers, in the restore itself
$problems = @(Test-ConfigurationBeforeInputHC $configuration $rootFolder)
if ($problems.Count) { throw ($problems -join [Environment]::NewLine) }
#endregion

if (
    -not $SkipConfirmation -and -not $Unattended -and
    (Read-Host "Restore '$configurationPath'? (y/n)") -ne 'y'
) {
    Write-Verbose 'Restore not confirmed, stop'
    return
}

#region Restart elevated when required
if (
    $configuration.Settings.RunElevated -and
    -not (Test-ElevatedHC)
) {
    Write-Verbose 'Administrator rights required, restart elevated'
    $format = (
        "& '{0}' -ConfigurationFile '{1}' -StartScript '{2}' " +
        '-SkipConfirmation'
    )
    $command = $format -f @(
        $PSCommandPath.Replace("'", "''"),
        $configurationPath.Replace("'", "''"),
        $StartScript.Replace("'", "''")
    )
    if ($null -ne $Items) {
        $itemArguments = (
            $Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
        ) -join ','
        $command += " -Items @($itemArguments)"
    }
    foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
        if ($PSBoundParameters.ContainsKey($setting)) {
            $value = $PSBoundParameters[$setting].ToString()
            $command += " -{0} `${1}" -f $setting, $value.ToLowerInvariant()
        }
    }
    if ($PSBoundParameters.ContainsKey('RestartDelaySeconds')) {
        $command += " -RestartDelaySeconds $RestartDelaySeconds"
    }
    if ($PSBoundParameters.ContainsKey('AnswerFile')) {
        $command += " -AnswerFile '" + $AnswerFile.Replace("'", "''") + "'"
    }
    if ($PSBoundParameters.ContainsKey('AnswerPipe')) {
        $command += " -AnswerPipe '" + $AnswerPipe.Replace("'", "''") + "'"
    }
    if ($SkipSoftwareInstall.Count) {
        $command += " -SkipSoftwareInstall @($($SkipSoftwareInstall -join ','))"
    }
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )
    $params = @{
        FilePath     = 'powershell.exe'
        Verb         = 'RunAs'
        ArgumentList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        )
    }
    Start-Process @params
    return
}
#endregion

$arguments = @{
    Action            = 'RestoreSnapshot'
    ConfigurationFile = $configurationPath
}
if ($null -ne $Items) { $arguments.Items = $Items }
if ($PSBoundParameters.ContainsKey('AnswerFile')) {
    $arguments.AnswerFile = $AnswerFile
}
$settings = @(
    'RebootComputer', 'RestartDelaySeconds', 'OpenReportInBrowser',
    'AnswerPipe', 'SkipSoftwareInstall', 'Unattended'
)
foreach ($setting in $settings) {
    if ($PSBoundParameters.ContainsKey($setting)) {
        $arguments[$setting] = $PSBoundParameters[$setting]
    }
}
Write-Verbose "Start script '$StartScript'"
Invoke-ScriptHC -Path $StartScript -Arguments $arguments