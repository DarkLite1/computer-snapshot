#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import NTP time servers as a configuration section.
.DESCRIPTION
    Import configures the time service, restarts it and synchronizes the
    time, in that order. Each step depends on the previous one, so the first
    failure stops the import and is reported in Errors. Exit codes of w32tm
    are checked; a failing command is never reported as a success.
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
function Invoke-TimeServiceHC {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Windows PowerShell 5.1 turns output on the error stream of a program
    # into a stopping error when the preference is Stop; the exit code decides
    $ErrorActionPreference = 'Continue'
    Write-Verbose "Run 'w32tm $($Arguments -join ' ')'"
    $output = & w32tm @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw (
            "w32tm $($Arguments -join ' ') failed with exit code " +
            "${exitCode}: $($output -join [Environment]::NewLine)"
        )
    }
    $output
}

Function Get-TimeServerHC {
    # Reads the configured servers from the registry for every type: the
    # source reported by 'w32tm /query /source' is a domain controller or a
    # localized text such as 'Local CMOS Clock', not a configured server
    [CmdletBinding()]
    param()

    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $parameters = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $servers = if ($parameters.Type -ne 'NT5DS') {
        "$($parameters.NtpServer)" -split '\s+' |
        Where-Object { $_ } |
        ForEach-Object { ($_ -split ',', 2)[0] }
    }
    [pscustomobject]@{
        Type       = $parameters.Type
        TimeServer = @($servers)
    }
}

Function Set-SynchronizeTimeWithServerHC {
    Param (
        [Parameter(Mandatory)]
        [String[]]$ComputerName
    )

    $manualpeerlist = $ComputerName -join ' '

    # /reliable:NO: this computer only uses the time servers. YES would
    # announce it as a reliable time source for other computers, which
    # is meant for domain controllers and dedicated time servers
    $arguments = @(
        '/config', "/manualpeerlist:$manualpeerlist",
        '/syncfromflags:manual', '/reliable:NO', '/update'
    )
    $null = Invoke-TimeServiceHC -Arguments $arguments
}

Function Set-SynchronizeTimeWithDomainHC {
    $arguments = @(
        '/config', '/syncfromflags:domhier', '/reliable:NO', '/update'
    )
    $null = Invoke-TimeServiceHC -Arguments $arguments
}
#endregion

$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import NTP time servers: empty section, nothing to do'
    return [pscustomobject]@{
        Data     = $null
        Messages = [string[]]@('Nothing to do')
        Errors   = [string[]]@()
    }
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export NTP time servers'
    try {
        $timeServers = Get-TimeServerHC
        $exportData = [ordered]@{
            SyncTimeWithDomain = $timeServers.Type -eq 'NT5DS'
            TimeServerNames    = @(
                $timeServers.TimeServer |
                Where-Object { $_ } |
                ForEach-Object { $_.Trim() }
            )
        }
        $messages = @('Exported NTP time servers')
        if ($timeServers.Type -notin @('NT5DS', 'NTP')) {
            $messages += (
                "The time service type is '$($timeServers.Type)'; " +
                'a restore synchronizes with the exported time servers only'
            )
        }
    }
    catch {
        $errors += (
            'Failed to read the time service settings: ' +
            "$($_.Exception.Message)"
        )
    }
    #endregion
}
else {
    #region Apply section
    Write-Verbose 'Import NTP time servers'
    $step = 'configure the time service'
    try {
        if ($Data.SyncTimeWithDomain) {
            Write-Verbose 'Sync time with the domain'
            Set-SynchronizeTimeWithDomainHC
            $messages += (
                'Configured the time service to synchronize with the domain'
            )
            if (@($Data.TimeServerNames | Where-Object { $_ }).Count) {
                $messages += 'Custom time server names are disregarded'
            }
        }
        else {
            $timeServerNames = @(
                $Data.TimeServerNames |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ }
            )
            if (-not $timeServerNames.Count) {
                throw (
                    'no time server names are configured and ' +
                    'SyncTimeWithDomain is not set'
                )
            }
            Write-Verbose "Sync time with servers '$timeServerNames'"
            Set-SynchronizeTimeWithServerHC -ComputerName $timeServerNames
            $messages += (
                'Configured the time service to synchronize with ' +
                "'$($timeServerNames -join ' ')'"
            )
        }

        $step = 'restart the time service'
        Write-Verbose 'Restart the time service'
        Restart-Service w32time -ErrorAction Stop

        $step = 'synchronize the time now (the settings were applied)'
        Write-Verbose 'Synchronize the time now'
        $null = Invoke-TimeServiceHC -Arguments '/resync'
        if ($Data.SyncTimeWithDomain) {
            $messages += 'Time synchronized with the domain'
        }
        else {
            $messages += (
                'Time synchronized with custom time servers ' +
                "'$($timeServerNames -join ' ')'"
            )
        }
    }
    catch {
        $errors += "Failed to ${step}: $($_.Exception.Message)"
    }
    #endregion
}

[pscustomobject]@{
    Data     = $exportData
    Messages = [string[]]$messages
    Errors   = [string[]]$errors
}