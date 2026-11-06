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

function Get-EmptySectionValueHC {
    <#
    .SYNOPSIS
        The empty value of a section, as the schema allows it: an empty
        object for the sections that are an object, otherwise an empty
        list. An export writes it for a selected section with nothing to
        export, so the section is there to fill in; a restore skips it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $objectSections = @(
        'RegionalSettings', 'CreateFolders', 'NtpTimeServers',
        'RegistryKeys', 'Software'
    )
    if ($Name -in $objectSections) {
        return , ([ordered]@{})
    }

    , @()
}

function Get-SoftwareInstallLabelHC {
    # How an install entry is shown: the installer file and its arguments
    param(
        [Parameter(Mandatory)][AllowNull()]$Entry
    )

    if ($null -eq $Entry) {
        return '(empty entry)'
    }

    $label = $null
    if ($Entry.ExecutablePath) {
        $label = Split-Path -Path ([string]$Entry.ExecutablePath) -Leaf
    }
    if (-not $label) {
        $label = '(no ExecutablePath)'
    }
    if ($Entry.Arguments) {
        $label += " $($Entry.Arguments)"
    }
    $label
}

function Skip-SoftwareInstallHC {
    <#
    .SYNOPSIS
        Take the Software.Install entries at the given positions, from 0,
        out of the configuration items, and return their labels.
    .DESCRIPTION
        Used for the entries unchecked in the wizard, before any answer is
        asked, so a placeholder of a skipped installer is not asked for.
        Throws for a position that is not an install entry.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Items,
        [Parameter(Mandatory)][int[]]$Skip
    )

    $software = $Items['Software']
    $install = @($software.Install)
    $wrong = @(
        $Skip | Where-Object { $_ -lt 0 -or $_ -ge $install.Count }
    )
    if ($null -eq $software -or $wrong.Count) {
        $position = if ($wrong.Count) {
            $wrong[0]
        }
        else {
            $Skip[0]
        }
        throw (
            'SkipSoftwareInstall: there is no Software.Install entry ' +
            "$position in this configuration"
        )
    }

    $kept = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $install.Count; $index++) {
        if ($index -in $Skip) {
            Get-SoftwareInstallLabelHC -Entry $install[$index]
        }
        else {
            $kept.Add($install[$index])
        }
    }

    # Without installers left, an otherwise empty section is skipped
    if ($software -is [System.Collections.IDictionary]) {
        if ($kept.Count) {
            $software['Install'] = $kept.ToArray()
        }
        else {
            $software.Remove('Install')
        }
    }
    elseif ($kept.Count) {
        $software.Install = $kept.ToArray()
    }
    else {
        $software.PSObject.Properties.Remove('Install')
    }
}

function Get-SnapshotSectionLabelsHC {
    # The name and description of each section, as the wizard shows them
    @{
        StartCustomScriptsBefore = @(
            'Custom scripts (before restore)',
            'Run custom scripts before the other sections.'
        )
        RegionalSettings         = @(
            'Regional settings',
            'Language, culture, home location and time zone.'
        )
        UserAccounts             = @(
            'User accounts',
            'Local user accounts to create, update or remove.'
        )
        UserGroups               = @(
            'User groups',
            'Local groups and group membership.'
        )
        FirewallRules            = @(
            'Firewall rules',
            'Windows Firewall rules and their settings.'
        )
        CreateFolders            = @(
            'Create folders',
            'Folder paths to create on the computer.'
        )
        SmbShares                = @(
            'Shared folders (SMB)',
            'Network shares, share access and NTFS permissions.'
        )
        NetworkCards             = @(
            'Network adapters',
            'Network adapter, IP address and DNS settings.'
        )
        NtpTimeServers           = @(
            'Time synchronization',
            'Domain time synchronization or NTP time servers.'
        )
        HostsFileEntries         = @(
            'Hosts file',
            'Host names and the IP addresses they point to.'
        )
        RegistryKeys             = @(
            'Registry keys',
            'Registry keys and values to apply.'
        )
        ScheduledTasks           = @(
            'Scheduled tasks',
            'Task definitions and enabled states.'
        )
        CopyFilesFolders         = @(
            'Copy files and folders',
            'Source and destination paths for file copies.'
        )
        Software                 = @(
            'Software',
            'Applications to install or remove.'
        )
        StartCustomScriptsAfter  = @(
            'Custom scripts (after restore)',
            'Run custom scripts after the other sections.'
        )
    }
}

function Test-ElevatedHC {
    <#
    .SYNOPSIS
        True when the current process runs as administrator.
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal $identity
        $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
    finally {
        $identity.Dispose()
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

    if (
        $properties -contains 'Action' -and
        $User.Action -cnotin @('Set', 'Remove')
    ) {
        "Action: expected Set or Remove"
    }

    if ($User.Action -eq 'Remove') {
        if (
            $User.Name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($User.Name) -or
            [Management.Automation.WildcardPattern]::ContainsWildcardCharacters(
                $User.Name
            ) -or
            $User.Name -match '[\\/]'
        ) {
            (
                'Name: removal requires an exact local account name, ' +
                'without wildcards or a domain prefix'
            )
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

    # Task folder names are case-insensitive; keep the first spelling
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase
    )

    $folders = @(
        $Options.TaskPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { '\' + ([string]$_).Trim().Trim('\') + '\' } |
        ForEach-Object { $_ -replace '^\\\\$', '\' } |
        Where-Object { $seen.Add($_) }
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

function New-SectionResultHC {
    <#
    .SYNOPSIS
        The one object a section script returns: Data (export only), and
        Messages and Errors as string arrays.
    #>
    param(
        $Data,
        [AllowNull()][string[]]$Messages = @(),
        [AllowNull()][string[]]$Errors = @()
    )
    if ($null -eq $Messages) {
        $Messages = @()
    }
    if ($null -eq $Errors) {
        $Errors = @()
    }
    [pscustomobject]@{
        Data     = $Data
        Messages = $Messages
        Errors   = $Errors
    }
}

function Read-SectionExampleHC {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $contentParams = @{
        LiteralPath = $Path
        Raw         = $true
        Encoding    = 'UTF8'
        ErrorAction = 'Stop'
    }
    $text = Get-Content @contentParams

    $json = '{"Data":' + $text + '}'
    $wrapper = ConvertFrom-Json -InputObject $json -ErrorAction Stop

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

function Get-WellKnownAccountHC {
    <#
    .SYNOPSIS
        The built-in accounts that have the same SID on every computer,
        with their English name.
    .DESCRIPTION
        Windows translates these names: Administrators is Administratoren
        on a German Windows. An export writes the English name so it can be
        read, and a restore finds the SID by that name and uses the name of
        the computer's own language.
    #>
    if ($null -eq $script:wellKnownAccountsHC) {
        $script:wellKnownAccountsHC = [ordered]@{
            'S-1-1-0'      = 'Everyone'
            'S-1-2-0'      = 'LOCAL'
            'S-1-2-1'      = 'CONSOLE LOGON'
            'S-1-3-0'      = 'CREATOR OWNER'
            'S-1-3-1'      = 'CREATOR GROUP'
            'S-1-3-4'      = 'OWNER RIGHTS'
            'S-1-5-1'      = 'NT AUTHORITY\DIALUP'
            'S-1-5-2'      = 'NT AUTHORITY\NETWORK'
            'S-1-5-3'      = 'NT AUTHORITY\BATCH'
            'S-1-5-4'      = 'NT AUTHORITY\INTERACTIVE'
            'S-1-5-6'      = 'NT AUTHORITY\SERVICE'
            'S-1-5-7'      = 'NT AUTHORITY\ANONYMOUS LOGON'
            'S-1-5-9'      = 'NT AUTHORITY\ENTERPRISE DOMAIN CONTROLLERS'
            'S-1-5-10'     = 'NT AUTHORITY\SELF'
            'S-1-5-11'     = 'NT AUTHORITY\Authenticated Users'
            'S-1-5-12'     = 'NT AUTHORITY\RESTRICTED'
            'S-1-5-13'     = 'NT AUTHORITY\TERMINAL SERVER USER'
            'S-1-5-14'     = 'NT AUTHORITY\REMOTE INTERACTIVE LOGON'
            'S-1-5-15'     = 'NT AUTHORITY\This Organization'
            'S-1-5-17'     = 'NT AUTHORITY\IUSR'
            'S-1-5-18'     = 'NT AUTHORITY\SYSTEM'
            'S-1-5-19'     = 'NT AUTHORITY\LOCAL SERVICE'
            'S-1-5-20'     = 'NT AUTHORITY\NETWORK SERVICE'
            'S-1-5-113'    = 'NT AUTHORITY\Local account'
            'S-1-5-114'    = (
                'NT AUTHORITY\Local account and member of Administrators group'
            )
            'S-1-5-32-544' = 'BUILTIN\Administrators'
            'S-1-5-32-545' = 'BUILTIN\Users'
            'S-1-5-32-546' = 'BUILTIN\Guests'
            'S-1-5-32-547' = 'BUILTIN\Power Users'
            'S-1-5-32-550' = 'BUILTIN\Print Operators'
            'S-1-5-32-551' = 'BUILTIN\Backup Operators'
            'S-1-5-32-552' = 'BUILTIN\Replicator'
            'S-1-5-32-555' = 'BUILTIN\Remote Desktop Users'
            'S-1-5-32-556' = 'BUILTIN\Network Configuration Operators'
            'S-1-5-32-558' = 'BUILTIN\Performance Monitor Users'
            'S-1-5-32-559' = 'BUILTIN\Performance Log Users'
            'S-1-5-32-562' = 'BUILTIN\Distributed COM Users'
            'S-1-5-32-568' = 'BUILTIN\IIS_IUSRS'
            'S-1-5-32-569' = 'BUILTIN\Cryptographic Operators'
            'S-1-5-32-573' = 'BUILTIN\Event Log Readers'
            'S-1-5-32-574' = 'BUILTIN\Certificate Service DCOM Access'
            'S-1-5-32-575' = 'BUILTIN\RDS Remote Access Servers'
            'S-1-5-32-576' = 'BUILTIN\RDS Endpoint Servers'
            'S-1-5-32-577' = 'BUILTIN\RDS Management Servers'
            'S-1-5-32-578' = 'BUILTIN\Hyper-V Administrators'
            'S-1-5-32-579' = 'BUILTIN\Access Control Assistance Operators'
            'S-1-5-32-580' = 'BUILTIN\Remote Management Users'
            'S-1-5-32-581' = 'BUILTIN\System Managed Accounts Group'
            'S-1-5-32-582' = 'BUILTIN\Storage Replica Administrators'
            'S-1-5-32-583' = 'BUILTIN\Device Owners'
            'S-1-15-2-1'   = (
                'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES'
            )
            'S-1-15-2-2'   = (
                'APPLICATION PACKAGE AUTHORITY\' +
                'ALL RESTRICTED APPLICATION PACKAGES'
            )
        }
    }

    $script:wellKnownAccountsHC
}

function Get-WellKnownAccountSidHC {
    <#
    .SYNOPSIS
        The SID of a configured built-in account: a SID as it is, or the
        English name of a built-in account, with or without its prefix,
        such as 'BUILTIN\Administrators' or 'Administrators'. Nothing for
        any other name.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )

    if ($Name -match '^S-1-\d+(-\d+)+$') {
        return $Name.ToUpperInvariant()
    }

    $accounts = Get-WellKnownAccountHC
    $short = $Name.Split('\')[-1]
    $matching = @(
        $accounts.Keys | Where-Object {
            $accounts[$_] -eq $Name -or (
                $Name -notlike '*\*' -and
                $accounts[$_].Split('\')[-1] -eq $short
            )
        }
    )

    if ($matching.Count -eq 1) {
        return $matching[0]
    }
}

function ConvertTo-PortableAccountNameHC {
    <#
    .SYNOPSIS
        The name to export for an account, so it is readable and works on
        every computer, in every Windows language.
    .DESCRIPTION
        - Local and domain accounts (S-1-5-21-...) have a SID that differs
          per computer or domain, so they keep their name.
        - Built-in accounts such as Everyone (S-1-1-0) or Administrators
          (S-1-5-32-544) have the same SID everywhere, but a name in the
          Windows language: they get their English name, which a restore
          translates.
        - Service accounts (NT SERVICE\...) have a name in every language.
        - Other built-in accounts, without an English name in the table,
          are exported by SID.
        A name that cannot be resolved, such as an orphaned account, is
        kept as it is.
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

    if ($Sid -like 'S-1-5-21-*' -or $Sid -like 'S-1-5-80-*') {
        return $Name
    }

    $accounts = Get-WellKnownAccountHC
    if ($accounts.Contains($Sid)) {
        return $accounts[$Sid]
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
        A built-in account, by SID or by its English name such as
        'BUILTIN\Administrators', becomes the account's name in this
        computer's language.

        When neither the name nor the local name can be resolved, the name
        is returned unchanged, so the error names the configured account.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )

    # A built-in account, by SID or by English name: use this computer's
    # name, in its own language
    $wellKnownSid = Get-WellKnownAccountSidHC -Name $Name
    if ($wellKnownSid) {
        try {
            $sid = [System.Security.Principal.SecurityIdentifier]$wellKnownSid

            return $sid.Translate(
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
        Write-Verbose "Account '$Name' mapped to '$localName'"
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