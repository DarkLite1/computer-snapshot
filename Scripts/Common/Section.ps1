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
        HostsFileEntries         = 'Hosts file entries import export.ps1'
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

function Test-HostsIPAddressHC {
    # A plain IPv4 address or an IPv6 address, as written in a hosts file
    param(
        $Value
    )

    $address = $null

    if (
        $Value -isnot [string] -or
        -not [Net.IPAddress]::TryParse($Value, [ref]$address)
    ) {
        return $false
    }

    if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        # TryParse also accepts shortened forms such as '10.1'
        return $address.ToString() -ceq $Value
    }

    $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and
    $Value -notmatch '%'
}

function Test-HostNameHC {
    # Labels of letters, digits, '-' and '_', separated by dots
    param(
        $Value
    )

    $Value -is [string] -and
    $Value.Length -le 253 -and
    $Value -match (
        '\A[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?' +
        '(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\z'
    )
}

function Test-UserAccountEntryHC {
    param($User)

    $properties = if ($User -is [System.Collections.IDictionary]) {
        @($User.Keys)
    }
    else {
        @($User.PSObject.Properties.Name)
    }

    if ($properties -contains 'Action' -and $User.Action -cnotin @('Set', 'Remove')) {
        "Action: expected Set or Remove"
    }

    if ($User.Action -eq 'Remove') {
        if (
            $User.Name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($User.Name) -or
            [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($User.Name) -or
            $User.Name -match '[\\/]'
        ) {
            'Name: removal requires an exact local account name, without wildcards or a domain prefix'
        }
        foreach ($property in $properties) {
            if ($property -notin @('Name', 'Action', 'Comment')) {
                "${property}: not used with Action Remove; remove it"
            }
        }
    }
}

function Get-ExportTaskFolderHC {
    # Task folders to export, each as '\Folder\'; '\HC\' when none are given
    param(
        $Options
    )

    $folders = @(
        $Options.TaskPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { '\' + ([string]$_).Trim().Trim('\') + '\' } |
        ForEach-Object { $_ -replace '^\\\\$', '\' } |
        Select-Object -Unique
    )

    if (-not $folders.Count) {
        $folders = @('\HC\')
    }

    $folders
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

function ConvertTo-PortableAccountNameHC {
    <#
    .SYNOPSIS
        The name to export for an account: its SID when that is the same on
        every computer, otherwise the account name.
    .DESCRIPTION
        Built-in accounts and groups such as Everyone (S-1-1-0) or
        Administrators (S-1-5-32-544) have a fixed SID, but their name
        depends on the Windows language. Exporting the SID makes the
        configuration work in every language. Local and domain accounts
        (S-1-5-21-...) have a SID that differs per computer or domain, so
        they keep their name. A name that cannot be resolved, such as an
        orphaned account, is kept as it is.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Sid
    )

    if (-not $Sid) {
        try {
            $Sid = ([System.Security.Principal.NTAccount]$Name).Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
        }
        catch {
            return $Name
        }
    }

    if ($Sid -like 'S-1-5-21-*') {
        return $Name
    }

    $Sid
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
        A SID, which an export writes for built-in accounts, becomes the
        account's name in this computer's language.

        When neither the name nor the local name can be resolved, the name
        is returned unchanged, so the error names the configured account.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )

    # A SID, as exported for built-in accounts: use this computer's name
    if ($Name -match '^S-1-\d+(-\d+)+$') {
        try {
            return ([System.Security.Principal.SecurityIdentifier]$Name).Translate(
                [System.Security.Principal.NTAccount]
            ).Value
        }
        catch {
            return $Name
        }
    }

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

function Expand-PathVariableHC {
    <#
    .SYNOPSIS
        Expand environment variables such as %ProgramData% in a path.
    .DESCRIPTION
        Windows leaves an unknown variable as it is, which would silently
        create a folder named '%Name%'; that throws instead.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)

    if ($expandedPath -match '%([^%\\]+)%') {
        throw "unknown environment variable '%$($Matches[1])%'"
    }

    $expandedPath
}