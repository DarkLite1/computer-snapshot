#Requires -Version 5.1

<#
.SYNOPSIS
    Export or import Start custom scripts as a configuration section.
.DESCRIPTION
    Import runs each PowerShell script in the list, relative to the USB root
    unless it is a full path, with Arguments as named parameters. Scripts run
    with the normal PowerShell error behavior, so an error inside a script
    does not stop that script unless the script decides so.

    Everything a script writes (output, Write-Host, warnings) is added to the
    report, prefixed with the script path. A script fails when it writes an
    error, throws, or ends with an exit code that is not in SuccessExitCodes
    (default 0). The exit code is that of 'exit <code>' or of the program the
    script ran last; a script ending with robocopy needs SuccessExitCodes
    [0, 1, 2, 3, 4, 5, 6, 7]. Each failed script is reported in Errors and
    the remaining scripts still run.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')]
    [string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"

#region Windows helpers
function Invoke-CustomScriptHC {
    param(
        [string]$Path,
        [hashtable]$Arguments
    )
    & $Path @Arguments
}

function ConvertTo-ArgumentsHC {
    # Arguments come from JSON as an object; tests may pass a hashtable
    param($Arguments)

    $result = @{}

    if ($null -eq $Arguments) {
        return $result
    }

    $names = if ($Arguments -is [System.Collections.IDictionary]) {
        @($Arguments.Keys)
    }
    else {
        @($Arguments.PSObject.Properties | ForEach-Object { $_.Name })
    }

    foreach ($name in $names) {
        if ($name -ne 'Comment') {
            $result[$name] = $Arguments.$name
        }
    }

    $result
}

function Get-SuccessExitCodesHC {
    # SuccessExitCodes from the configuration, or 0 when none are configured
    param($Item)

    $codes = @(
        $Item.SuccessExitCodes |
        Where-Object { $null -ne $_ } |
        ForEach-Object { [int]$_ }
    )

    if (-not $codes.Count) {
        $codes = @(0)
    }

    $codes
}
#endregion

$exportData = $null
# Lists, so the script block that runs a custom script can add to them
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{
        Data     = $null
        Messages = [string[]]@('Nothing to do')
        Errors   = [string[]]@()
    }
}

if ($Action -eq 'Export') {
    #region Capture section
    $exportData = Read-SectionExampleHC `
        "$PSScriptRoot\..\Examples\StartCustomScriptsBefore.json"
    #endregion
    $messages.Add('Exported Start custom scripts')
}
else {
    #region Apply section
    foreach ($item in @($Data | Where-Object { $null -ne $_ })) {
        $name = $item.Path
        $scriptErrors = New-Object 'System.Collections.Generic.List[string]'
        $exitCode = 0

        try {
            if (-not $item.Path) {
                throw "the field 'Path' is required"
            }

            $path = Resolve-RootPathHC -Path $item.Path -RootFolder $RootFolder

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "the file '$path' does not exist"
            }

            $arguments = ConvertTo-ArgumentsHC $item.Arguments
            $successExitCodes = Get-SuccessExitCodesHC -Item $item

            $global:LASTEXITCODE = 0

            & {
                # The custom script gets the normal PowerShell error behavior
                $ErrorActionPreference = 'Continue'

                Invoke-CustomScriptHC -Path $path -Arguments $arguments *>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        $scriptErrors.Add([string]$_)
                    }
                    elseif (
                        $_ -is [System.Management.Automation.WarningRecord]
                    ) {
                        $messages.Add("${name}: WARNING: $_")
                    }
                    elseif (
                        $_ -is [System.Management.Automation.VerboseRecord] -or
                        $_ -is [System.Management.Automation.DebugRecord]
                    ) {
                        # Not added to the report
                    }
                    elseif ($null -ne $_ -and "$_" -ne '') {
                        $messages.Add("${name}: $_")
                    }
                }
            }

            $exitCode = [int]$global:LASTEXITCODE

            if ($successExitCodes -notcontains $exitCode) {
                $scriptErrors.Add(
                    "the script ended with exit code $exitCode, " +
                    "success exit codes are $($successExitCodes -join ', ')"
                )
            }
        }
        catch {
            $scriptErrors.Add($_.Exception.Message)
        }

        if ($scriptErrors.Count) {
            foreach ($scriptError in $scriptErrors) {
                $errors.Add("Script '$name' failed: $scriptError")
            }
        }
        elseif ($exitCode) {
            $messages.Add("Ran script '$name' (exit code $exitCode)")
        }
        else {
            $messages.Add("Ran script '$name'")
        }
    }
    #endregion
}

[pscustomobject]@{
    Data     = $exportData
    Messages = [string[]]$messages
    Errors   = [string[]]$errors
}