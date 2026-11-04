#Requires -Version 5.1
<#
.SYNOPSIS
    Apply Dell driver updates after a restore without automatically
    restarting.
.DESCRIPTION
    Requires Dell Command Update to be installed, administrator rights and
    access to its configured update source. BIOS and firmware are excluded.
    Logs are kept locally under ProgramData\ComputerSnapshot\Logs.
    Exit codes 0, 1 and 500 are handled outcomes; all other codes fail the
    custom action. A required restart is reported, not performed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$programFolders = @(
    $env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}
) | Select-Object -Unique
$dcuPath = @(
    foreach ($folder in $programFolders) {
        if ($folder) {
            $candidate = Join-Path $folder 'Dell\CommandUpdate\dcu-cli.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $candidate
            }
        }
    }
) | Select-Object -First 1

if (-not $dcuPath) {
    throw (
        'Dell Command Update CLI was not found. Install Dell Command ' +
        'Update before running this action.'
    )
}
Write-Verbose "Dell Command Update CLI '$dcuPath'"

$logFolder = Join-Path $env:ProgramData 'ComputerSnapshot\Logs'
$null = New-Item -Path $logFolder -ItemType Directory -Force
$logFile = 'DellDrivers-{0}-{1}.log' -f @(
    (Get-Date -Format 'yyyyMMdd-HHmmss')
    [guid]::NewGuid().ToString('N')
)
$logPath = Join-Path $logFolder $logFile
Write-Output "Dell Command Update log: $logPath"

Write-Verbose 'Apply Dell driver updates, this can take a while'
$params = @{
    FilePath     = $dcuPath
    ArgumentList = @(
        '/applyUpdates'
        '-silent'
        '-updateType=driver'
        '-reboot=disable'
        "-outputLog=`"$logPath`""
    )
    Wait         = $true
    PassThru     = $true
}
$process = Start-Process @params
Write-Verbose "Dell Command Update exit code $($process.ExitCode)"

switch ($process.ExitCode) {
    0 { Write-Output 'Dell driver updates completed successfully.' }
    1 {
        Write-Warning (
            'Dell driver updates require a restart. Restart manually ' +
            'after the restore finishes.'
        )
    }
    500 { Write-Output 'No applicable Dell driver updates are available.' }
    5 {
        throw (
            'Dell Command Update requires a pending restart before it ' +
            "can run. Restart and rerun this action. Log: $logPath"
        )
    }
    default {
        throw (
            'Dell Command Update failed with exit code ' +
            "$($process.ExitCode). Log: $logPath"
        )
    }
}

exit 0
