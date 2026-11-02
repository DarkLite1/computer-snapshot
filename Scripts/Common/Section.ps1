#Requires -Version 5.1

<#
.SYNOPSIS
    Shared section helpers for standalone snapshot components.
#>

function Get-SnapshotScriptsHC {
    return [ordered]@{
        StartCustomScriptsBefore = 'Start custom scripts import export.ps1'
        RegionalSettings         = 'Regional settings import export.ps1'
        UserAccounts             = 'User accounts import export.ps1'
        UserGroups               = 'User groups import export.ps1'
        FirewallRules            = 'Firewall rules import export.ps1'
        CreateFolders            = 'Folders import export.ps1'
        SmbShares                = 'Smb shares import export.ps1'
        NetworkCards             = 'Network cards import export.ps1'
        NtpTimeServers           = 'NTP time servers import export.ps1'
        RegistryKeys             = 'Registry keys import export.ps1'
        ScheduledTasks           = 'Scheduled tasks import export.ps1'
        CopyFilesFolders         = 'Copy files folders import export.ps1'
        Software                 = 'Software import export.ps1'
        StartCustomScriptsAfter  = 'Start custom scripts import export.ps1'
    }
}

function Resolve-RootPathHC {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootFolder
    )
         
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)

    if ([IO.Path]::IsPathRooted($expandedPath)) {
        return $expandedPath 
    }

    return [IO.Path]::GetFullPath((Join-Path $RootFolder $expandedPath))
}

function Test-EmptySectionHC {
    param(
        $Data
    )
        
    if ($null -eq $Data) {
        return $true 
    }
        
    if ($Data -is [System.Collections.IDictionary]) { 
        return @(
            $Data.Keys | Where-Object { $_ -ne 'Comment' }
        ).Count -eq 0 
    }

    if ($Data -is [array]) { 
        return $Data.Count -eq 0 
    }

    return @(
        $Data.PSObject.Properties | Where-Object { $_.Name -ne 'Comment' }
    ).Count -eq 0
}

function Read-SectionExampleHC {
    param(
        [Parameter(Mandatory)][string]$Path
    )
        
    $text = Get-Content `
        -LiteralPath $Path -Raw -Encoding UTF8 `
        -ErrorAction Stop
    
    $wrapper = ConvertFrom-Json `
        -InputObject ('{"Data":' + $text + '}') `
        -ErrorAction Stop
        
    return , $wrapper.Data
}

function Test-AccountExistsHC {
    # Whether Windows can resolve the account name to a security ID
    param(
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $null = ([System.Security.Principal.NTAccount]$Name).Translate(
            [System.Security.Principal.SecurityIdentifier]
        )
        $true
    }
    catch {
        $false
    }
}

function Convert-AccountNameHC {
    <#
    .SYNOPSIS
        Map a local account of the exported computer to this computer.
    .DESCRIPTION
        An export contains local accounts with the name of the computer it
        was made on, such as 'PC1\bob'. On another computer that becomes
        'PC2\bob'. Other names are kept: names without a prefix, built-in
        and service accounts, and every account this computer can resolve,
        such as 'CONTOSO\Domain Admins' on a computer in that domain.

        When neither the name nor the local name can be resolved, the name
        is returned unchanged, so the error names the configured account.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )

    if ($Name -notlike '*\*') {
        return $Name
    }

    $prefix, $accountName = $Name.Split('\', 2)

    if (
        $prefix -eq $env:COMPUTERNAME -or
        $prefix -in @('BUILTIN', 'NT AUTHORITY', 'NT SERVICE')
    ) {
        return $Name
    }

    # A domain account, or any other account this computer knows
    if (Test-AccountExistsHC -Name $Name) {
        return $Name
    }

    $localName = "$env:COMPUTERNAME\$accountName"

    if (Test-AccountExistsHC -Name $localName) {
        return $localName
    }

    $Name
}