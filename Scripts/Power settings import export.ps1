#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Power settings as a configuration section.
.DESCRIPTION
    Import makes ActivePlan the active power plan, then sets the timeouts of
    that plan, for AC (plugged in) and DC (on battery), in minutes where 0
    means never: MonitorTimeoutMinutes, SleepTimeoutMinutes,
    HibernateTimeoutMinutes and DiskTimeoutMinutes. HibernateEnabled turns
    hibernation, and with it fast startup, on or off. Settings that are left
    out stay as they are. Each failed setting is reported in Errors and the
    remaining settings are still applied.

    ActivePlan is Balanced, HighPerformance or PowerSaver, which work in
    every Windows language, the name of a plan as 'powercfg /list' shows it,
    or a plan GUID. Laptops with modern standby often only have Balanced.
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
. "$PSScriptRoot\Common\Section.ps1"

#region Windows helpers
function Invoke-PowerCfgHC {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # The exit code decides, not output on the error stream
    $ErrorActionPreference = 'Continue'
    $output = & powercfg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (
            "powercfg $($Arguments -join ' ') failed with exit code " +
            "${LASTEXITCODE}: $($output -join ' ')"
        )
    }
    $output | ForEach-Object { [string]$_ }
}

function Get-HibernateEnabledHC {
    $params = @{
        LiteralPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        Name        = 'HibernateEnabled'
        ErrorAction = 'SilentlyContinue'
    }
    $value = (Get-ItemProperty @params).HibernateEnabled
    if ($null -ne $value) { $value -eq 1 }
}
#endregion

$knownPlans = [ordered]@{
    Balanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    PowerSaver      = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}
# Configuration name, powercfg subgroup and setting, and description
$timeouts = @(
    , @('MonitorTimeoutMinutes', 'SUB_VIDEO', 'VIDEOIDLE', 'turn off display')
    , @('SleepTimeoutMinutes', 'SUB_SLEEP', 'STANDBYIDLE', 'sleep')
    , @('HibernateTimeoutMinutes', 'SUB_SLEEP', 'HIBERNATEIDLE', 'hibernate')
    , @('DiskTimeoutMinutes', 'SUB_DISK', 'DISKIDLE', 'turn off hard disk')
) | ForEach-Object {
    [pscustomobject]@{
        Name     = $_[0]
        Subgroup = $_[1]
        Setting  = $_[2]
        Text     = $_[3]
    }
}
$guidPattern = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

function Get-PowerPlansHC {
    # Every plan as 'powercfg /list' shows it; the active one is marked *
    foreach ($line in Invoke-PowerCfgHC -Arguments '/list') {
        if ($line -match "($guidPattern)\s+\((.+)\)(\s*\*)?\s*$") {
            [pscustomobject]@{
                Guid   = $Matches[1].ToLower()
                Name   = $Matches[3]
                Active = [bool]$Matches[4]
            }
        }
    }
}

function Get-PowerTimeoutHC {
    # AC and DC in minutes: the last two values of the query, in seconds
    param([Parameter(Mandatory)]$Timeout)
    $values = @(
        Invoke-PowerCfgHC -Arguments @(
            '/query', 'SCHEME_CURRENT', $Timeout.Subgroup, $Timeout.Setting
        ) | Where-Object { $_ -match ':\s*0x([0-9a-fA-F]+)\s*$' } |
        ForEach-Object { [Convert]::ToInt64($Matches[1], 16) }
    )
    if ($values.Count -lt 2) {
        throw "powercfg did not return the $($Timeout.Text) timeout"
    }
    [ordered]@{
        AC = [int][Math]::Floor($values[-2] / 60)
        DC = [int][Math]::Floor($values[-1] / 60)
    }
}

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Power settings: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Power settings'
    $exportData = [ordered]@{}
    try {
        $active = Get-PowerPlansHC | Where-Object { $_.Active }
        $known = $knownPlans.Keys |
            Where-Object { $knownPlans[$_] -eq $active.Guid }
        $exportData.ActivePlan = if ($known) { $known } else { $active.Name }
        foreach ($timeout in $timeouts) {
            $exportData[$timeout.Name] = Get-PowerTimeoutHC $timeout
        }
        $hibernate = Get-HibernateEnabledHC
        if ($null -ne $hibernate) {
            $exportData.HibernateEnabled = $hibernate
        }
        $messages.Add('Exported Power settings')
    }
    catch {
        $errors.Add("Failed to export the power settings: $_")
    }
    #endregion
}
else {
    #region Apply section
    Write-Verbose 'Import Power settings'

    #region Active plan
    if ($Data.ActivePlan) {
        $wanted = [string]$Data.ActivePlan
        try {
            $plans = @(Get-PowerPlansHC)
            $plan = $plans | Where-Object {
                $_.Guid -eq $knownPlans[$wanted] -or
                $_.Guid -eq $wanted.ToLower() -or
                $_.Name -eq $wanted
            } | Select-Object -First 1
            if (-not $plan) {
                throw (
                    'this computer has no such plan; plans: ' +
                    (($plans | ForEach-Object { $_.Name }) -join ', ')
                )
            }
            if ($plan.Active) {
                $messages.Add("Power plan '$($plan.Name)' is already active")
            }
            else {
                Write-Verbose "Power plan '$($plan.Name)': activate"
                $null = Invoke-PowerCfgHC -Arguments '/setactive', $plan.Guid
                $old = ($plans | Where-Object { $_.Active }).Name
                $messages.Add(
                    "Changed the active power plan from '$old' to " +
                    "'$($plan.Name)'"
                )
            }
        }
        catch {
            $errors.Add(
                "Failed to activate power plan '$wanted': " +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion

    #region Timeouts
    $timeoutChanged = $false
    foreach ($timeout in $timeouts) {
        $wanted = $Data.($timeout.Name)
        if ($null -eq $wanted) { continue }
        try {
            $current = Get-PowerTimeoutHC $timeout
            $changes = 0
            foreach ($source in @('AC', 'DC')) {
                $minutes = $wanted.$source
                if ($null -eq $minutes -or $current[$source] -eq $minutes) {
                    continue
                }
                Write-Verbose "Power $($timeout.Text) $($source): $minutes"
                $null = Invoke-PowerCfgHC -Arguments @(
                    "/set$($source.ToLower())valueindex", 'SCHEME_CURRENT',
                    $timeout.Subgroup, $timeout.Setting, ([int]$minutes * 60)
                )
                $timeoutChanged = $true
                $changes++
                $messages.Add(
                    "Changed $($timeout.Text) on $source power from " +
                    "$($current[$source]) to $minutes minutes"
                )
            }
            if (-not $changes) {
                $messages.Add(
                    "The $($timeout.Text) timeout is already correct"
                )
            }
        }
        catch {
            $errors.Add(
                "Failed to set the $($timeout.Text) timeout: " +
                "$($_.Exception.Message)"
            )
        }
    }
    if ($timeoutChanged) {
        try {
            # A changed value of the active plan applies after activating it
            $null = Invoke-PowerCfgHC -Arguments '/setactive', 'SCHEME_CURRENT'
        }
        catch {
            $errors.Add(
                'Failed to apply the changed timeouts: ' +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion

    #region Hibernation
    if ($null -ne $Data.HibernateEnabled) {
        try {
            $old = Get-HibernateEnabledHC
            if ($old -eq $Data.HibernateEnabled) {
                $messages.Add(
                    'Hibernation is already ' +
                    $(if ($old) { 'on' } else { 'off' })
                )
            }
            else {
                $state = if ($Data.HibernateEnabled) { 'on' } else { 'off' }
                Write-Verbose "Hibernation: $state"
                $null = Invoke-PowerCfgHC -Arguments '/hibernate', $state
                $messages.Add("Turned hibernation $state")
            }
        }
        catch {
            $errors.Add(
                "Failed to turn hibernation on or off: $($_.Exception.Message)"
            )
        }
    }
    #endregion
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams
