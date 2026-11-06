#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Environment variables as a configuration section.
.DESCRIPTION
    Each entry changes one variable of the computer (Scope Machine, the
    default) or of the account running the restore (Scope User):
    - Set: give it Value. A value with %VARIABLE% stays unexpanded, so
      '%ProgramData%\Tools' keeps working when ProgramData changes.
    - Remove: delete the variable.
    - AddToList: add each of Values to a list such as Path, at the end,
      when it is not in the list yet. Case and a trailing '\' are ignored.
    - RemoveFromList: remove each of Values from such a list.

    The registry value keeps its type, so Path stays expandable. Programs
    started afterwards see the change, and so do the next sections of this
    restore. Each failed entry is reported in Errors and the remaining
    entries are still applied.

    Export writes the computer variables that are not part of Windows, as
    Set entries. List variables such as Path are not exported: add
    AddToList entries for them.
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
function Get-EnvironmentKeyHC {
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')]
        [string]$Scope,
        [switch]$Writable
    )
    if ($Scope -eq 'Machine') {
        [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
            [bool]$Writable
        )
    }
    else {
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            'Environment', [bool]$Writable
        )
    }
}

function Get-EnvironmentVariablesHC {
    # Every variable of the scope, unexpanded, with its registry type
    param([Parameter(Mandatory)][string]$Scope)
    $key = Get-EnvironmentKeyHC -Scope $Scope
    $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    try {
        foreach ($name in $key.GetValueNames()) {
            [pscustomobject]@{
                Name  = $name
                Value = [string]$key.GetValue($name, $null, $raw)
                Kind  = [string]$key.GetValueKind($name)
            }
        }
    }
    finally { $key.Dispose() }
}

function Set-EnvironmentVariableHC {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Name,
        # Without a value, the variable is removed
        [string]$Value,
        [string]$Kind = 'String'
    )
    $key = Get-EnvironmentKeyHC -Scope $Scope -Writable
    try {
        if ($Value) {
            $key.SetValue(
                $Name, $Value,
                [Microsoft.Win32.RegistryValueKind]$Kind
            )
        }
        else {
            $key.DeleteValue($Name, $false)
        }
    }
    finally { $key.Dispose() }

    # This process sees the change as a newly started program would: Path
    # joins both scopes, otherwise the user value wins
    $machine = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    $user = [Environment]::GetEnvironmentVariable($Name, 'User')
    $processValue = if ($Name -eq 'Path') {
        @($machine, $user | Where-Object { $_ }) -join ';'
    }
    elseif ($user) { $user }
    else { $machine }
    [Environment]::SetEnvironmentVariable($Name, $processValue, 'Process')
}

function Send-EnvironmentChangeHC {
    # Tells running programs, such as Explorer, to read the variables again
    if (-not ('ComputerSnapshot.NativeMethods' -as [type])) {
        Add-Type -Namespace ComputerSnapshot -Name NativeMethods `
            -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 seconds
    $null = [ComputerSnapshot.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000,
        [ref]$result
    )
}
#endregion

function Test-SameListEntryHC {
    param([string]$A, [string]$B)
    $A.TrimEnd('\') -eq $B.TrimEnd('\')
}

# Machine variables that come with Windows, by name
$windowsVariables = @(
    'ComSpec', 'DriverData', 'NUMBER_OF_PROCESSORS', 'OS', 'Path',
    'PATHEXT', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
    'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'PSModulePath', 'TEMP', 'TMP',
    'USERNAME', 'windir', 'OnlyCore'
)

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Environment variables: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Environment variables'
    # Values that look like secrets are asked for during the restore instead
    $secretName = 'pass|pwd|secret|token|key|credential'
    $exportData = @(
        Get-EnvironmentVariablesHC -Scope Machine |
        Where-Object { $windowsVariables -notcontains $_.Name } |
        Sort-Object Name |
        ForEach-Object {
            $value = $_.Value
            if ($_.Name -match $secretName) {
                $value = "{{password:Value of environment variable $($_.Name)}}"
                $messages.Add(
                    "Environment variable '$($_.Name)' looks like a secret; " +
                    'it was exported as a placeholder, so the restore asks ' +
                    'for its value'
                )
            }
            [ordered]@{ Name = $_.Name; Value = $value }
        }
    )
    $messages.Insert(0, 'Exported Environment variables')
    $messages.Add(
        'Path and PSModulePath are not exported; add AddToList entries ' +
        'for them, see Examples\EnvironmentVariables.json'
    )
    #endregion
}
else {
    #region Apply section
    Write-Verbose 'Import Environment variables'
    $variables = @{}
    $changed = $false
    foreach ($entry in @($Data)) {
        $scope = if ($entry.Scope) { [string]$entry.Scope } else { 'Machine' }
        $entryAction = if ($entry.Action) {
            [string]$entry.Action
        }
        else { 'Set' }
        $name = [string]$entry.Name
        $label = "$scope variable '$name'"
        try {
            if (-not $variables.ContainsKey($scope)) {
                $variables[$scope] = @{}
                foreach ($variable in @(
                        Get-EnvironmentVariablesHC -Scope $scope
                    )) {
                    $variables[$scope][$variable.Name] = $variable
                }
            }
            $current = $variables[$scope][$name]
            $old = if ($current) { $current.Value } else { $null }
            $kind = if ($current) { $current.Kind } else { 'String' }
            $new = $old

            switch ($entryAction) {
                'Set' {
                    $new = [string]$entry.Value
                }
                'Remove' {
                    $new = $null
                }
                'AddToList' {
                    $list = [System.Collections.Generic.List[string]]@(
                        [string]$old -split ';' | Where-Object { $_ }
                    )
                    foreach ($value in @($entry.Values)) {
                        $found = $list | Where-Object {
                            Test-SameListEntryHC $_ $value
                        }
                        if (-not $found) { $list.Add($value) }
                    }
                    $new = $list -join ';'
                }
                'RemoveFromList' {
                    $list = @(
                        [string]$old -split ';' | Where-Object {
                            $item = $_
                            $item -and -not @(
                                @($entry.Values) | Where-Object {
                                    Test-SameListEntryHC $item $_
                                }
                            ).Count
                        }
                    )
                    $new = $list -join ';'
                    # Only the entries are removed, not an emptied list
                    if (-not $new -and $current) { $new = $old }
                }
            }

            if ([string]$new -ceq [string]$old) {
                $messages.Add("$label is already correct")
                continue
            }
            if ($new -match '%[^%]+%') { $kind = 'ExpandString' }

            Write-Verbose "${label}: $entryAction"
            $setParams = @{
                Scope = $scope
                Name  = $name
                Value = $new
                Kind  = $kind
            }
            Set-EnvironmentVariableHC @setParams
            $changed = $true
            $variables[$scope][$name] = if ($new) {
                [pscustomobject]@{ Name = $name; Value = $new; Kind = $kind }
            }
            $messages.Add($(
                    if (-not $new) {
                        "Removed $label, it was '$old'"
                    }
                    elseif ($null -eq $old) {
                        "Created $label with '$new'"
                    }
                    else {
                        "Changed $label from '$old' to '$new'"
                    }
                ))
        }
        catch {
            $errors.Add("Failed to set ${label}: $($_.Exception.Message)")
        }
    }
    if ($changed) {
        try { Send-EnvironmentChangeHC }
        catch {
            $errors.Add(
                'Failed to tell running programs about the changed ' +
                "variables: $($_.Exception.Message)"
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
