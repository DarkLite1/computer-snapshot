#Requires -Version 5.1
<#
.SYNOPSIS
    Shared section helpers for standalone snapshot components.
#>
function Get-SnapshotScriptsHC {
    return [ordered]@{
        StartCustomScriptsBefore = 'Start custom scripts import export.ps1'
        RegionalSettings = 'Regional settings import export.ps1'
        UserAccounts = 'User accounts import export.ps1'
        UserGroups = 'User groups import export.ps1'
        FirewallRules = 'Firewall rules import export.ps1'
        CreateFolders = 'Folders import export.ps1'
        SmbShares = 'Smb shares import export.ps1'
        NetworkCards = 'Network cards import export.ps1'
        NtpTimeServers = 'NTP time servers import export.ps1'
        RegistryKeys = 'Registry keys import export.ps1'
        ScheduledTasks = 'Scheduled tasks import export.ps1'
        CopyFilesFolders = 'Copy files folders import export.ps1'
        Software = 'Software import export.ps1'
        StartCustomScriptsAfter = 'Start custom scripts import export.ps1'
    }
}

function Resolve-RootPathHC {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RootFolder)
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expandedPath)) { return $expandedPath }
    return [IO.Path]::GetFullPath((Join-Path $RootFolder $expandedPath))
}

function Test-EmptySectionHC {
    param($Data)
    if ($null -eq $Data) { return $true }
    if ($Data -is [System.Collections.IDictionary]) { return @($Data.Keys | Where-Object { $_ -ne 'Comment' }).Count -eq 0 }
    if ($Data -is [array]) { return $Data.Count -eq 0 }
    return @($Data.PSObject.Properties | Where-Object { $_.Name -ne 'Comment' }).Count -eq 0
}

function Read-SectionExampleHC {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    $wrapper = ConvertFrom-Json -InputObject ('{"Data":' + $text + '}') -ErrorAction Stop
    return ,$wrapper.Data
}