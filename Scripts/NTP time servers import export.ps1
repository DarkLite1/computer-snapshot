#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import NTP time servers as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
function Invoke-TimeServiceHC {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & w32tm @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "w32tm $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    $output
}

Function Get-TimeServerHC {
    [CmdletBinding()]
    param()

    $parameters = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction Stop
    $servers = if ($parameters.Type -eq 'NTP') {
        $parameters.NtpServer -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ',', 2)[0] }
    }
    else {
        Invoke-TimeServiceHC -Arguments '/query', '/source'
    }
    [pscustomobject]@{ Type = $parameters.Type; TimeServer = @($servers) }
}
Function Set-SynchronizeTimeWithServerHC {
        Param (
            [Parameter(Mandatory)]
            [String[]]$ComputerName
        )

        $manualpeerlist = $ComputerName -join ' '

        $null = Invoke-TimeServiceHC -Arguments '/config', "/manualpeerlist:$manualpeerlist", '/syncfromflags:manual', '/reliable:YES', '/update'
    }
Function Set-SynchronizeTimeWithDomainHC {
        $null = Invoke-TimeServiceHC -Arguments '/config', '/syncfromflags:domhier', '/reliable:NO', '/update'
    }
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$timeServers = Get-TimeServerHC
$exportData = [ordered]@{
    SyncTimeWithDomain = $timeServers.Type -eq 'NT5DS'
    TimeServerNames = @($timeServers.TimeServer | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}
    #endregion
    $messages = @('Exported NTP time servers')
}
else {
    #region Apply section
    $messages = @(& {

$ntp = $Data
if ($ntp.SyncTimeWithDomain) {
                Write-Verbose 'Sync time with the domain'
                Set-SynchronizeTimeWithDomainHC
            } 
            else {
                $timeServerNames = $ntp.TimeServerNames | Where-Object { $_ } | 
                ForEach-Object { $_.trim() }
                
                if ($timeServerNames) {
                    Write-Verbose "Sync time with servers '$timeServerNames'"
                    Set-SynchronizeTimeWithServerHC -ComputerName $timeServerNames
                    
                }
                else {
                    throw 'No time server names found in the import file'
                }
            }
Restart-Service w32time -ErrorAction Stop
$null = Invoke-TimeServiceHC -Arguments '/resync'
if ($ntp.SyncTimeWithDomain) {
    Write-Output 'Time synchronized with the domain'
    Write-Output 'Custom time server names are disregarded'
}
else {
    Write-Output "Time synchronized with custom time servers '$timeServerNames'"
}
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
