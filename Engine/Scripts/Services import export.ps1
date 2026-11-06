#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Services as a configuration section.
.DESCRIPTION
    Each entry finds a Windows service by its exact service name, such as
    'wuauserv', and sets its StartupType: Automatic, AutomaticDelayedStart,
    Manual or Disabled. Status Running starts the service, Stopped stops it,
    together with the services that depend on it. The startup type is set
    first, so a disabled service is stopped, or an enabled one started.
    Each failed service is reported in Errors and the remaining services
    are still configured.

    Export writes an empty list: which services were changed on purpose
    cannot be read from Windows.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written
    here.
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
. "$PSScriptRoot\..\Common\Section.ps1"

#region Windows helpers
function Get-ServiceStartupTypeHC {
    # Windows PowerShell 5.1 cannot tell a delayed start, the registry can
    param([Parameter(Mandatory)][string]$Name)
    $params = @{
        LiteralPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        ErrorAction = 'Stop'
    }
    $key = Get-ItemProperty @params
    switch ([int]$key.Start) {
        2 {
            if ($key.DelayedAutostart -eq 1) { 'AutomaticDelayedStart' }
            else { 'Automatic' }
        }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { "Start $($key.Start)" }
    }
}

function Set-ServiceStartupTypeHC {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$StartupType
    )
    $start = @{
        Automatic             = 'auto'
        AutomaticDelayedStart = 'delayed-auto'
        Manual                = 'demand'
        Disabled              = 'disabled'
    }[$StartupType]
    # The exit code decides, not output on the error stream
    $ErrorActionPreference = 'Continue'
    $output = & sc.exe config $Name start= $start 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe failed with exit code ${LASTEXITCODE}: $output"
    }
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Services: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Services: an empty section to fill in'
    $exportData = @()
    $messages.Add(
        'Nothing to export: add the services to configure, see ' +
        'Examples\Services.json'
    )
    #endregion
}
else {
    #region Apply section
    Write-Verbose 'Import Services'
    foreach ($entry in @($Data)) {
        $name = [string]$entry.Name
        try {
            $service = Get-Service -Name $name -ErrorAction Ignore |
                Where-Object { $_.Name -eq $name }
            if (-not $service) {
                throw 'no service with this name'
            }
            $label = "'$name' ($($service.DisplayName))"
            $changes = 0

            if ($entry.StartupType) {
                $old = Get-ServiceStartupTypeHC -Name $name
                if ($old -ne $entry.StartupType) {
                    Write-Verbose "Service $($label): set startup type"
                    $params = @{
                        Name        = $name
                        StartupType = $entry.StartupType
                    }
                    Set-ServiceStartupTypeHC @params
                    $messages.Add(
                        "Changed the startup type of service $label from " +
                        "'$old' to '$($entry.StartupType)'"
                    )
                    $changes++
                }
            }

            if ($entry.Status -and $service.Status -ne $entry.Status) {
                Write-Verbose "Service $($label): $($entry.Status)"
                if ($entry.Status -eq 'Running') {
                    Start-Service -Name $name
                    $messages.Add("Started service $label")
                }
                else {
                    Stop-Service -Name $name -Force
                    $messages.Add("Stopped service $label")
                }
                $changes++
            }

            if (-not $changes) {
                $messages.Add("Service $label is already correct")
            }
        }
        catch {
            $errors.Add(
                "Failed to configure service '$name': " +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams
