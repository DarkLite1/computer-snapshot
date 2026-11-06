#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import the local password and account lockout policy as a
    configuration section.
.DESCRIPTION
    Import applies only the settings that differ, all at once with
    'secedit /configure', and reads the policy again to check each one:
    Windows refuses combinations such as a lockout duration shorter than
    the lockout counter reset time, and each setting that did not change is
    reported in Errors. Settings that are left out stay as they are.

    On a computer in a domain, the domain password policy applies to domain
    accounts and a domain group policy can overwrite these local settings.
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

# Configuration name, secedit name and how the setting is described
$settings = @(
    , @('MinimumPasswordLength', 'MinimumPasswordLength',
        'minimum password length')
    , @('PasswordComplexity', 'PasswordComplexity',
        'password complexity requirement')
    , @('PasswordHistorySize', 'PasswordHistorySize',
        'number of remembered passwords')
    , @('MinimumPasswordAgeDays', 'MinimumPasswordAge',
        'minimum password age in days')
    , @('MaximumPasswordAgeDays', 'MaximumPasswordAge',
        'maximum password age in days')
    , @('LockoutThreshold', 'LockoutBadCount',
        'account lockout threshold')
    , @('LockoutDurationMinutes', 'LockoutDuration',
        'account lockout duration in minutes')
    , @('ResetLockoutCounterMinutes', 'ResetLockoutCount',
        'reset lockout counter after minutes')
) | ForEach-Object {
    [pscustomobject]@{ Name = $_[0]; Policy = $_[1]; Text = $_[2] }
}

#region Windows helpers
function Invoke-SeceditHC {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # The exit code decides, not output on the error stream
    $ErrorActionPreference = 'Continue'
    $output = & secedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (
            "secedit $($Arguments[0]) failed with exit code " +
            "${LASTEXITCODE}: $($output -join ' ')"
        )
    }
}

function Get-SecurityPolicyHC {
    # The [System Access] values of the local security policy, by name
    $file = Join-Path $env:TEMP "ComputerSnapshot-$([guid]::NewGuid()).inf"
    try {
        Invoke-SeceditHC -Arguments @(
            '/export', '/cfg', $file, '/areas', 'SECURITYPOLICY', '/quiet'
        )
        $values = @{}
        $inSection = $false
        $valueLine = '^\s*(\w+)\s*=\s*(-?\d+)\s*$'
        foreach ($line in [IO.File]::ReadAllLines($file)) {
            if ($line -match '^\[(.+)\]$') {
                $inSection = $Matches[1] -eq 'System Access'
            }
            elseif ($inSection -and $line -match $valueLine) {
                $values[$Matches[1]] = [int]$Matches[2]
            }
        }
        $values
    }
    finally {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
}

function Set-SecurityPolicyHC {
    param([Parameter(Mandatory)][hashtable]$Values)
    $base = Join-Path $env:TEMP "ComputerSnapshot-$([guid]::NewGuid())"
    $files = @("$base.inf", "$base.sdb", "$base.jfm")
    try {
        $lines = @('[Unicode]', 'Unicode=yes', '[System Access]') + @(
            $Values.Keys | ForEach-Object { "$_ = $($Values[$_])" }
        ) + @('[Version]', 'signature="$CHICAGO$"', 'Revision=1')
        [IO.File]::WriteAllLines($files[0], [string[]]$lines)
        Invoke-SeceditHC -Arguments @(
            '/configure', '/db', $files[1], '/cfg', $files[0],
            '/areas', 'SECURITYPOLICY', '/quiet'
        )
    }
    finally {
        foreach ($file in $files) {
            if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
        }
    }
}
#endregion

function ConvertFrom-PolicyValueHC {
    # secedit writes -1 for 'never', the configuration uses 0 like Windows
    param($Setting, [int]$Value)
    if ($Setting.Name -eq 'PasswordComplexity') { return $Value -eq 1 }
    if ($Value -lt 0) { return 0 }
    $Value
}

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Account policy: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

try {
    $current = Get-SecurityPolicyHC

    if ($Action -eq 'Export') {
        #region Capture section
        Write-Verbose 'Export Account policy'
        $exportData = [ordered]@{}
        foreach ($setting in $settings) {
            # Lockout duration and reset time only exist with a threshold
            if ($current.ContainsKey($setting.Policy)) {
                $policyValue = $current[$setting.Policy]
                $value = ConvertFrom-PolicyValueHC $setting $policyValue
                $exportData[$setting.Name] = $value
            }
        }
        $messages.Add('Exported Account policy')
        #endregion
    }
    else {
        #region Apply section
        Write-Verbose 'Import Account policy'
        $changes = @{}
        $wanted = @{}
        foreach ($setting in $settings) {
            $value = $Data.($setting.Name)
            if ($null -eq $value) { continue }
            $wanted[$setting.Name] = $value
            $old = $current[$setting.Policy]
            if ($null -eq $old -or
                (ConvertFrom-PolicyValueHC $setting $old) -ne $value
            ) {
                $changes[$setting.Policy] = [int]$value
            }
        }

        if (-not $changes.Count) {
            $messages.Add('Account policy is already correct')
        }
        else {
            Write-Verbose (
                "Account policy: set $(@($changes.Keys) -join ', ')"
            )
            Set-SecurityPolicyHC -Values $changes
            $after = Get-SecurityPolicyHC
            foreach ($setting in $settings) {
                if (-not $changes.ContainsKey($setting.Policy)) { continue }
                $old = '(not set)'
                if ($current.ContainsKey($setting.Policy)) {
                    $old = ConvertFrom-PolicyValueHC $setting (
                        $current[$setting.Policy]
                    )
                }
                $new = '(not set)'
                if ($after.ContainsKey($setting.Policy)) {
                    $new = ConvertFrom-PolicyValueHC $setting (
                        $after[$setting.Policy]
                    )
                }
                if ($new -eq $wanted[$setting.Name]) {
                    $messages.Add(
                        "Changed the $($setting.Text) from '$old' to '$new'"
                    )
                }
                else {
                    $errors.Add(
                        "Failed to set the $($setting.Text) to " +
                        "'$($wanted[$setting.Name])': Windows kept '$new'"
                    )
                }
            }
        }
        #endregion
    }
}
catch {
    $errors.Add("Failed to $($Action.ToLower()) the account policy: $_")
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams
