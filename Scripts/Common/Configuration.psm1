#Requires -Version 5.1
<#
.SYNOPSIS
    Read, validate and write version-3 computer configurations on
    PowerShell 5.1.
#>

. "$PSScriptRoot\Section.ps1"
. "$PSScriptRoot\Schema.ps1"
. "$PSScriptRoot\Registry.ps1"

$script:ItemOrder = @((Get-SnapshotScriptsHC).Keys)
$script:ArrayItems = @(
    'StartCustomScriptsBefore',
    'UserAccounts',
    'UserGroups',
    'FirewallRules',
    'NetworkCards',
    'HostsFileEntries',
    'ScheduledTasks',
    'SmbShares',
    'CopyFilesFolders',
    'StartCustomScriptsAfter'
)

function Get-PropertiesHC {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value.Keys)
    }

    if ($Value -is [pscustomobject]) {
        return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    }

    return @()
}

function Test-ObjectHC {
    param($Value)

    return (
        $Value -is [pscustomobject] -or
        $Value -is [System.Collections.IDictionary]
    )
}

function Read-JsonValueHC {
    param([string]$Path)

    $contentParams = @{
        LiteralPath = $Path
        Raw         = $true
        Encoding    = 'UTF8'
        ErrorAction = 'Stop'
    }
    $text = Get-Content @contentParams

    $jsonParams = @{
        InputObject = '{"Data":' + $text + '}'
        ErrorAction = 'Stop'
    }
    $wrapper = ConvertFrom-Json @jsonParams

    return , $wrapper.Data
}

function Test-ReferenceListHC {
    # A section given as one or more file references instead of inline data
    param($Data)

    if ($Data -is [string]) {
        return $true
    }

    $Data -is [array] -and $Data.Count -gt 0 -and
    @($Data | Where-Object { $_ -isnot [string] }).Count -eq 0
}

function Add-SectionOriginHC {
    # Remember which file set each single value, for conflict messages
    param(
        $Value,
        [string]$Path,
        [string]$Source,
        [hashtable]$Origins
    )

    if ($Value -is [array]) {
        return
    }

    if (Test-ObjectHC $Value) {
        foreach ($property in Get-PropertiesHC $Value) {
            $originParams = @{
                Value   = $Value.$property
                Path    = "$Path.$property"
                Source  = $Source
                Origins = $Origins
            }
            Add-SectionOriginHC @originParams
        }

        return
    }

    if (-not $Origins.ContainsKey($Path)) {
        $Origins[$Path] = $Source
    }
}

function Merge-SectionDataHC {
    <#
    .SYNOPSIS
        Combine the data of two files for the same section.
    .DESCRIPTION
        Lists are joined in file order and objects are combined property by
        property. A single value that both files set must be equal; when it
        differs, the files contradict each other, which is an error. Comment
        properties never conflict, the first one is kept.
    #>
    param(
        $Base,
        $Addition,
        [string]$Path,
        [string]$Source,
        [hashtable]$Origins
    )

    if ($null -eq $Base) {
        Add-SectionOriginHC $Addition $Path $Source $Origins
        return , $Addition
    }

    if ($null -eq $Addition) {
        return , $Base
    }

    if ($Base -is [array] -or $Addition -is [array]) {
        if ($Base -isnot [array] -or $Addition -isnot [array]) {
            throw "'$Path' is a list in one file and not in '$Source'"
        }

        return , @(@($Base) + @($Addition))
    }

    if ((Test-ObjectHC $Base) -or (Test-ObjectHC $Addition)) {
        if (-not ((Test-ObjectHC $Base) -and (Test-ObjectHC $Addition))) {
            throw "'$Path' is an object in one file and not in '$Source'"
        }

        $combined = [ordered]@{}

        foreach ($property in Get-PropertiesHC $Base) {
            $combined[$property] = $Base.$property
        }

        foreach ($property in Get-PropertiesHC $Addition) {
            if (-not $combined.Contains($property)) {
                $originParams = @{
                    Value   = $Addition.$property
                    Path    = "$Path.$property"
                    Source  = $Source
                    Origins = $Origins
                }
                Add-SectionOriginHC @originParams

                $combined[$property] = $Addition.$property
            }
            elseif ($property -ne 'Comment') {
                $mergeParams = @{
                    Base     = $combined[$property]
                    Addition = $Addition.$property
                    Path     = "$Path.$property"
                    Source   = $Source
                    Origins  = $Origins
                }
                $combined[$property] = Merge-SectionDataHC @mergeParams
            }
        }

        return [pscustomobject]$combined
    }

    $baseJson = ConvertTo-Json -InputObject $Base -Compress
    $additionJson = ConvertTo-Json -InputObject $Addition -Compress

    if ($baseJson -cne $additionJson) {
        throw (
            "'$Path' is $baseJson in '$($Origins[$Path])' but " +
            "$additionJson in '$Source'; set it in one file only"
        )
    }

    $Base
}

function ConvertTo-LoadedConfigurationHC {
    param(
        $Configuration,
        [string]$RootFolder,
        [string]$Source,
        [string[]]$Items
    )

    $problems = New-Object 'System.Collections.Generic.List[string]'

    $result = [pscustomobject]@{
        SchemaVersion = 3
        Description   = $Configuration.Description
        Settings      = [ordered]@{
            RebootComputer      = $false
            RestartDelaySeconds = 60
            OpenReportInBrowser = $true
            RunElevated         = $false
        }
        Items         = [ordered]@{}
        Source        = $Source
        Problems      = $problems
    }
    $result.PSObject.TypeNames.Insert(0, 'ComputerSnapshot.Configuration')

    if (-not (Test-ObjectHC $Configuration)) {
        $problems.Add("$Source > configuration: expected an object")

        return $result
    }

    foreach ($property in Get-PropertiesHC $Configuration) {
        if (
            $property -cnotin @(
                '$schema', 'SchemaVersion', 'Description', 'Settings', 'Items'
            )
        ) {
            $problems.Add("$Source > ${property}: unknown property")
        }
    }

    if (
        $Configuration.SchemaVersion -ne 3 -or
        $Configuration.SchemaVersion -is [string]
    ) {
        $problems.Add(
            "$Source > SchemaVersion: expected 3; run the configuration " +
            "converter (Scripts\Convert configuration.ps1) for an older file"
        )
    }

    foreach ($property in @('Description', '$schema')) {
        if (
            (Get-PropertiesHC $Configuration) -contains $property -and
            $Configuration.$property -isnot [string]
        ) {
            $problems.Add("$Source > ${property}: expected a string")
        }
    }

    if ((Get-PropertiesHC $Configuration) -contains 'Settings') {
        if (-not (Test-ObjectHC $Configuration.Settings)) {
            $problems.Add("$Source > Settings: expected an object")
        }
        else {
            foreach ($property in Get-PropertiesHC $Configuration.Settings) {
                $location = "$Source > Settings.${property}"

                if ($property -ceq 'Comment') {
                    if ($Configuration.Settings.Comment -isnot [string]) {
                        $problems.Add("${location}: expected a string")
                    }
                }
                elseif ($property -ceq 'RestartDelaySeconds') {
                    $delay = $Configuration.Settings.RestartDelaySeconds

                    if (
                        ($delay -isnot [int] -and $delay -isnot [long]) -or
                        $delay -lt 0 -or $delay -gt 600
                    ) {
                        $problems.Add(
                            "$Source > Settings.RestartDelaySeconds: " +
                            'expected a whole number from 0 to 600'
                        )
                    }
                    else {
                        $result.Settings.RestartDelaySeconds = [int]$delay
                    }
                }
                elseif (
                    $property -cnotin @(
                        'RebootComputer', 'OpenReportInBrowser', 'RunElevated'
                    )
                ) {
                    $problems.Add("${location}: unknown property")
                }
                elseif ($Configuration.Settings.$property -isnot [bool]) {
                    $problems.Add("${location}: expected a Boolean")
                }
                else {
                    $result.Settings[$property] = (
                        $Configuration.Settings.$property
                    )
                }
            }
        }
    }

    if (
        -not (Test-ObjectHC $Configuration.Items) -or
        @(
            Get-PropertiesHC $Configuration.Items |
            Where-Object { $_ -ne 'Comment' }
        ).Count -eq 0
    ) {
        $problems.Add(
            "$Source > Items: expected an object containing at least one item"
        )

        return $result
    }

    foreach ($name in Get-PropertiesHC $Configuration.Items) {
        if ($name -ceq 'Comment') {
            if ($Configuration.Items.Comment -isnot [string]) {
                $problems.Add("$Source > Items.Comment: expected a string")
            }
        }
        elseif ($name -cnotin $script:ItemOrder) {
            $problems.Add("$Source > Items.${name}: unknown item")
        }
    }

    if ($null -ne $Items) {
        if (-not $Items.Count) {
            $problems.Add('Select at least one item.')
        }

        foreach ($name in $Items) {
            if (
                $name -notin $script:ItemOrder -or
                $name -notin @(Get-PropertiesHC $Configuration.Items)
            ) {
                $problems.Add(
                    "$Source > Items.${name}: selected item is not " +
                    'available in this configuration'
                )
            }
        }
    }

    foreach ($name in $script:ItemOrder) {
        if ($null -ne $Items -and $name -notin $Items) {
            continue
        }

        if ((Get-PropertiesHC $Configuration.Items) -notcontains $name) {
            continue
        }

        $data = $Configuration.Items.$name

        # One file, or a list of files that are combined in order
        if (Test-ReferenceListHC $data) {
            $combined = $null
            $origins = @{}
            $isValid = $true

            foreach ($reference in @($data)) {
                try {
                    $referencePath = Resolve-RootPathHC $reference $RootFolder
                    $part = Read-JsonValueHC $referencePath

                    if (Test-ReferenceListHC $part) {
                        throw 'nested section references are not supported'
                    }

                    $mergeParams = @{
                        Base     = $combined
                        Addition = $part
                        Path     = "Items.$name"
                        Source   = $reference
                        Origins  = $origins
                    }
                    $combined = Merge-SectionDataHC @mergeParams
                }
                catch {
                    $problems.Add(
                        "$Source > Items.${name}: reference '$reference': $_"
                    )
                    $isValid = $false

                    break
                }
            }

            if (-not $isValid) {
                continue
            }

            $data = $combined
        }

        $result.Items[$name] = $data
    }

    return $result
}

function Read-ConfigurationHC {
    <#
    .SYNOPSIS
        Read a configuration file and combine its referenced section files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootFolder,
        [string[]]$Items
    )

    $fullPath = Resolve-RootPathHC $Path $RootFolder

    try {
        $configuration = Read-JsonValueHC $fullPath
    }
    catch {
        throw "${fullPath} > configuration: invalid or unreadable JSON: $_"
    }

    $loadParams = @{
        Configuration = $configuration
        RootFolder    = $RootFolder
        Source        = $fullPath
        Items         = $Items
    }

    return ConvertTo-LoadedConfigurationHC @loadParams
}

function ConvertTo-IPv4NumberHC {
    # The address as a number, or $null when it is not a plain IPv4 address
    param($Value)

    $address = $null
    $ipv4 = [Net.Sockets.AddressFamily]::InterNetwork

    if (
        $Value -isnot [string] -or
        -not [Net.IPAddress]::TryParse($Value, [ref]$address) -or
        $address.AddressFamily -ne $ipv4 -or
        $address.ToString() -cne $Value
    ) {
        return $null
    }

    $bytes = $address.GetAddressBytes()
    [uint32](
        ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor
        ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
    )
}

function Get-IPSettingsProblemHC {
    <#
    .SYNOPSIS
        Problems in NetworkCards IPSettings, each starting with the property.
    .DESCRIPTION
        Placeholders are accepted as they are; the values that replace them
        are checked again after the restore-time input.
    #>
    param($Settings)

    $names = @(Get-PropertiesHC $Settings)
    $ipv4Placeholder = '\A\{\{ipv4:[^{}\r\n]+\}\}\z'

    if ($Settings.Dhcp -eq $true) {
        foreach ($name in @('IPAddress', 'PrefixLength', 'DefaultGateway')) {
            if ($names -contains $name) {
                (
                    ".${name}: not used with Dhcp true; remove it, or Dhcp " +
                    'for a static address'
                )
            }
        }
    }
    else {
        foreach ($name in @('IPAddress', 'PrefixLength')) {
            if ($names -notcontains $name) {
                (
                    ".${name}: required for a static address; use " +
                    '{ "Dhcp": true } for an automatic address'
                )
            }
        }
    }

    $values = @{}

    foreach ($name in @('IPAddress', 'DefaultGateway')) {
        if (
            $names -notcontains $name -or
            $Settings.$name -match $ipv4Placeholder
        ) {
            continue
        }

        $values[$name] = ConvertTo-IPv4NumberHC $Settings.$name

        if ($null -eq $values[$name]) {
            (
                ".${name}: '$($Settings.$name)' is not an IPv4 address " +
                'such as 192.0.2.10'
            )
        }
    }

    $prefix = $Settings.PrefixLength

    if ($names -contains 'PrefixLength') {
        if ($prefix -is [string]) {
            if ($prefix -notmatch '\A\{\{prefix:[^{}\r\n]+\}\}\z') {
                (
                    '.PrefixLength: expected a number from 1 to 32, or ' +
                    '{{prefix:Description}}'
                )
            }

            $prefix = $null
        }
    }

    if (
        $null -ne $values.IPAddress -and
        $null -ne $values.DefaultGateway -and
        ($prefix -is [int] -or $prefix -is [long]) -and
        $prefix -ge 1 -and
        $prefix -le 32
    ) {
        $all = [uint64]4294967295
        $mask = [uint32](($all -shl (32 - [int]$prefix)) -band $all)
        $addressNetwork = $values.IPAddress -band $mask
        $gatewayNetwork = $values.DefaultGateway -band $mask

        if ($addressNetwork -ne $gatewayNetwork) {
            (
                ".DefaultGateway: '$($Settings.DefaultGateway)' is not in " +
                "the subnet of $($Settings.IPAddress)/$prefix"
            )
        }
    }

    $servers = @($Settings.DNSServers | Where-Object { $null -ne $_ })

    for ($index = 0; $index -lt $servers.Count; $index++) {
        if (
            $servers[$index] -notmatch $ipv4Placeholder -and
            $null -eq (ConvertTo-IPv4NumberHC $servers[$index])
        ) {
            (
                ".DNSServers[$index]: '$($servers[$index])' is not an " +
                'IPv4 address such as 192.0.2.10'
            )
        }
    }
}

function Test-ConfigurationHC {
    <#
    .SYNOPSIS
        Return every problem in a configuration: its shape, section-specific
        rules and asset paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$RootFolder
    )

    $loadedType = 'ComputerSnapshot.Configuration'

    if ($Configuration.PSObject.TypeNames -notcontains $loadedType) {
        $loadParams = @{
            Configuration = $Configuration
            RootFolder    = $RootFolder
            Source        = '<configuration>'
        }
        $Configuration = ConvertTo-LoadedConfigurationHC @loadParams
    }

    $problems = New-Object 'System.Collections.Generic.List[string]'

    foreach ($problem in $Configuration.Problems) {
        $problems.Add($problem)
    }

    $source = $Configuration.Source
    $schemaParams = @{
        LiteralPath = "$PSScriptRoot\..\config.schema.json"
        Raw         = $true
        Encoding    = 'UTF8'
    }
    $schema = Get-Content @schemaParams | ConvertFrom-Json

    foreach ($name in $Configuration.Items.Keys) {
        $data = $Configuration.Items[$name]
        $location = "$source > Items.$name"

        if ($name -in $script:ArrayItems) {
            if ($data -isnot [array]) {
                $problems.Add("${location}: expected an array")
                continue
            }

            foreach (
                $index in
                0..($data.Count - 1) |
                Where-Object { $_ -ge 0 -and $_ -lt $data.Count }
            ) {
                if (-not (Test-ObjectHC $data[$index])) {
                    $problems.Add("${location}[$index]: expected an object")
                }
            }
        }
        elseif (-not (Test-ObjectHC $data)) {
            $problems.Add("${location}: expected an object")
            continue
        }

        $shapeProblems = @(
            Test-ShapeHC $data $schema.'$defs'.$name $schema.'$defs' $location
        )

        foreach ($problem in $shapeProblems) {
            $problems.Add($problem)
        }

        if ($shapeProblems.Count) {
            continue
        }

        if (Test-EmptySectionHC $data) {
            continue
        }

        $assets = New-Object 'System.Collections.Generic.List[hashtable]'

        switch ($name) {
            'UserAccounts' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $entryProblems = @(Test-UserAccountEntryHC $data[$index])

                    foreach ($problem in $entryProblems) {
                        $problems.Add("${location}[$index].$problem")
                    }
                }
            }
            'Software' {
                foreach ($property in @('Remove', 'Install')) {
                    if (
                        (Get-PropertiesHC $data) -contains $property -and
                        $data.$property -isnot [array]
                    ) {
                        $problems.Add(
                            "${location}.${property}: expected an array"
                        )
                    }
                }

                $removals = @($data.Remove | Where-Object { $null -ne $_ })

                for ($index = 0; $index -lt $removals.Count; $index++) {
                    $removalProperties = @(Get-PropertiesHC $removals[$index])

                    if (
                        $removalProperties -contains 'UninstallArguments' -and
                        $removalProperties -contains 'UninstallCommand'
                    ) {
                        $problems.Add(
                            "${location}.Remove[$index]: use either " +
                            'UninstallArguments or UninstallCommand, not both'
                        )
                    }
                }

                $installs = @($data.Install | Where-Object { $null -ne $_ })

                for ($index = 0; $index -lt $installs.Count; $index++) {
                    $assets.Add(@{
                        Value    = $installs[$index].ExecutablePath
                        Property = "Install[$index].ExecutablePath"
                        Leaf     = $true
                    })
                }
            }
            'CopyFilesFolders' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $assets.Add(@{
                        Value    = $data[$index].From
                        Property = "[$index].From"
                        # Placeholders can only be filled in a file
                        Leaf     = $data[$index].FillPlaceholders -eq $true
                    })

                    if ([string]::IsNullOrWhiteSpace($data[$index].To)) {
                        $problems.Add(
                            "${location}[$index].To: expected a destination " +
                            'path'
                        )
                    }
                }
            }
            {
                $_ -in @('StartCustomScriptsBefore', 'StartCustomScriptsAfter')
            } {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $assets.Add(@{
                        Value    = $data[$index].Path
                        Property = "[$index].Path"
                        Leaf     = $true
                    })

                    if (
                        $data[$index].Arguments -and
                        -not (Test-ObjectHC $data[$index].Arguments)
                    ) {
                        $problems.Add(
                            "${location}[$index].Arguments: expected an object"
                        )
                    }
                }
            }
            'RegistryKeys' {
                # Value types, data and actions, before anything is changed
                $groups = New-Object (
                    'System.Collections.Generic.List[hashtable]'
                )

                if ($null -ne $data.RunAsCurrentUser) {
                    $groups.Add(@{
                        Location = '.RunAsCurrentUser.RegistryKeys'
                        Entries  = $data.RunAsCurrentUser.RegistryKeys
                    })
                }

                $users = @(
                    $data.RunAsOtherUser | Where-Object { $null -ne $_ }
                )

                for ($user = 0; $user -lt $users.Count; $user++) {
                    $groups.Add(@{
                        Location = ".RunAsOtherUser[$user].RegistryKeys"
                        Entries  = $users[$user].RegistryKeys
                    })
                }

                foreach ($group in $groups) {
                    $entries = @(
                        $group.Entries | Where-Object { $null -ne $_ }
                    )

                    for ($index = 0; $index -lt $entries.Count; $index++) {
                        $entryProblems = @(
                            Get-RegistryEntryProblemHC -Entry $entries[$index]
                        )

                        foreach ($problem in $entryProblems) {
                            $problems.Add(
                                "${location}$($group.Location)[$index]: " +
                                $problem
                            )
                        }
                    }
                }
            }
            'ScheduledTasks' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    # The XML is inline (Xml) or in an exported file (XmlFile)
                    $xmlProperty = 'Xml'

                    if ((Get-PropertiesHC $data[$index]) -contains 'XmlFile') {
                        $xmlProperty = 'XmlFile'

                        $assets.Add(@{
                            Value    = $data[$index].XmlFile
                            Property = "[$index].XmlFile"
                            Leaf     = $true
                        })
                    }

                    $required = @('TaskName', 'TaskPath', $xmlProperty)

                    foreach ($property in $required) {
                        $value = $data[$index].$property

                        if ([string]::IsNullOrWhiteSpace($value)) {
                            $problems.Add(
                                "${location}[$index].${property}: " +
                                'expected a nonempty string'
                            )
                        }
                    }

                    if ($data[$index].Enabled -isnot [bool]) {
                        $problems.Add(
                            "${location}[$index].Enabled: expected a Boolean"
                        )
                    }

                    try {
                        $null = [xml]$data[$index].Xml
                    }
                    catch {
                        $problems.Add("${location}[$index].Xml: invalid XML")
                    }

                    if (
                        $data[$index].RunAsPassword -and
                        [string]::IsNullOrWhiteSpace($data[$index].RunAsUser)
                    ) {
                        $problems.Add(
                            "${location}[$index].RunAsPassword: " +
                            'needs RunAsUser, the account the password is for'
                        )
                    }
                }
            }
            'SmbShares' {
                # Each share once; its permissions are part of the share
                $shareNames = @{}

                for ($index = 0; $index -lt $data.Count; $index++) {
                    $shareName = [string]$data[$index].Name

                    if ($shareNames.ContainsKey($shareName)) {
                        $problems.Add(
                            "${location}[$index].Name: share '$shareName' " +
                            'is already configured at ' +
                            "[$($shareNames[$shareName])]"
                        )
                    }
                    else {
                        $shareNames[$shareName] = $index
                    }

                    if (
                        (Get-PropertiesHC $data[$index]) -contains 'Access' -and
                        $data[$index].Access -isnot [array]
                    ) {
                        $problems.Add(
                            "${location}[$index].Access: expected an array"
                        )
                    }
                }
            }
            'NetworkCards' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $ipSettings = $data[$index].Change.IPSettings

                    if ($null -eq $ipSettings) {
                        continue
                    }

                    $settingsProblems = @(
                        Get-IPSettingsProblemHC -Settings $ipSettings
                    )

                    foreach ($problem in $settingsProblems) {
                        $problems.Add(
                            "${location}[$index].Change.IPSettings$problem"
                        )
                    }
                }
            }
            'HostsFileEntries' {
                # Each host name points to one address and is not also removed
                $addressOf = @{}
                $placeholder = '\A\{\{(?:ipv4|input):[^{}\r\n]+\}\}\z'

                for ($index = 0; $index -lt $data.Count; $index++) {
                    $entry = $data[$index]
                    $entryLocation = "${location}[$index]"
                    $isRemove = $entry.Action -eq 'Remove'
                    $names = @(
                        $entry.Hostnames | Where-Object { $null -ne $_ }
                    )

                    if (-not $names.Count) {
                        $problems.Add(
                            "${entryLocation}.Hostnames: expected at least " +
                            'one host name'
                        )
                    }

                    $hasAddress = (
                        (Get-PropertiesHC $entry) -contains 'IPAddress'
                    )

                    if ($isRemove -and $hasAddress) {
                        $problems.Add(
                            "${entryLocation}.IPAddress: not used with " +
                            'Action Remove; remove it'
                        )
                    }
                    elseif (-not $isRemove) {
                        if (
                            -not (Test-HostsIPAddressHC $entry.IPAddress) -and
                            [string]$entry.IPAddress -notmatch $placeholder
                        ) {
                            $problems.Add(
                                "${entryLocation}.IPAddress: " +
                                "'$($entry.IPAddress)' is not an IPv4 or " +
                                'IPv6 address such as 10.20.60.47 or fd00::47'
                            )
                        }
                    }

                    $address = if ($isRemove) {
                        '(removed)'
                    }
                    else {
                        [string]$entry.IPAddress
                    }

                    for (
                        $nameIndex = 0
                        $nameIndex -lt $names.Count
                        $nameIndex++
                    ) {
                        $name = [string]$names[$nameIndex]
                        $nameLocation = (
                            "${entryLocation}.Hostnames[$nameIndex]"
                        )

                        if (
                            -not (Test-HostNameHC $name) -and
                            $name -notmatch $placeholder
                        ) {
                            $problems.Add(
                                "${nameLocation}: '$name' is not a valid " +
                                'host name'
                            )
                            continue
                        }

                        $key = $name.ToLowerInvariant()

                        if (
                            $addressOf.ContainsKey($key) -and
                            $addressOf[$key] -ne $address
                        ) {
                            $problems.Add(
                                "${nameLocation}: '$name' is already used " +
                                "for $($addressOf[$key])"
                            )
                        }
                        else {
                            $addressOf[$key] = $address
                        }
                    }
                }
            }
        }

        foreach ($asset in $assets) {
            $property = $asset.Property

            if ($property -notlike '[[]*') {
                $property = '.' + $property
            }

            try {
                if (
                    $asset.Value -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($asset.Value)
                ) {
                    throw 'expected a nonempty path'
                }

                $path = Resolve-RootPathHC $asset.Value $RootFolder
                $exists = if ($asset.Leaf) {
                    Test-Path -LiteralPath $path -PathType Leaf
                }
                else {
                    Test-Path -LiteralPath $path
                }

                if (-not $exists) {
                    throw "file '$($asset.Value)' not found"
                }
            }
            catch {
                $problems.Add("${location}${property}: $_")
            }
        }
    }

    return $problems.ToArray()
}

function Format-ConfigurationJsonHC {
    <#
    .SYNOPSIS
        Format a value as readable JSON: Comment first, short lists inline.
    #>
    param(
        $Value,
        [int]$Depth = 0,
        [int]$PrefixLength = 0
    )

    if ($null -eq $Value) {
        return 'null'
    }

    $indent = '  ' * $Depth
    $childIndent = '  ' * ($Depth + 1)
    $newline = [Environment]::NewLine

    if (
        $Value -is [System.Collections.IDictionary] -or
        (
            $null -ne $Value -and
            $Value.GetType() -eq [System.Management.Automation.PSCustomObject]
        )
    ) {
        $names = @(Get-PropertiesHC $Value)

        if (-not $names.Count) {
            return '{}'
        }

        $names = @(
            @($names | Where-Object { $_ -ceq 'Comment' }) +
            @($names | Where-Object { $_ -cne 'Comment' })
        )

        $lines = foreach ($name in $names) {
            $key = ConvertTo-Json -InputObject ([string]$name) -Compress
            $formatParams = @{
                Value        = $Value.$name
                Depth        = $Depth + 1
                PrefixLength = $key.Length + 2
            }
            $formatted = Format-ConfigurationJsonHC @formatParams

            $childIndent + $key + ': ' + $formatted
        }

        return (
            '{' + $newline + ($lines -join (',' + $newline)) + $newline +
            $indent + '}'
        )
    }

    if ($Value -is [array]) {
        if (-not $Value.Count) {
            return '[]'
        }

        $entries = @(
            foreach ($entry in $Value) {
                Format-ConfigurationJsonHC -Value $entry -Depth ($Depth + 1)
            }
        )

        $inline = '[' + ($entries -join ', ') + ']'

        if (
            -not $inline.Contains($newline) -and
            ($indent.Length + $PrefixLength + $inline.Length) -le 80
        ) {
            return $inline
        }

        $separator = ',' + $newline + $childIndent

        return (
            '[' + $newline + $childIndent + ($entries -join $separator) +
            $newline + $indent + ']'
        )
    }

    return ConvertTo-Json -InputObject $Value -Depth 20 -Compress
}

function Write-ConfigurationHC {
    <#
    .SYNOPSIS
        Write a configuration as formatted JSON, replacing the file safely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Path
    )

    $document = [ordered]@{
        '$schema'     = '../Scripts/config.schema.json'
        SchemaVersion = 3
    }

    if ($null -ne $Configuration.Description) {
        $document.Description = $Configuration.Description
    }

    if ($null -ne $Configuration.Settings) {
        $document.Settings = $Configuration.Settings
    }

    $document.Items = $Configuration.Items
    $json = Format-ConfigurationJsonHC $document

    #region Write safely: only a complete new file replaces the existing one
    $fullPath = [IO.Path]::GetFullPath($Path)
    $folder = [IO.Path]::GetDirectoryName($fullPath)
    $tempName = '.{0}.{1}.tmp' -f (
        [IO.Path]::GetFileName($fullPath),
        [guid]::NewGuid().ToString('N')
    )
    $tempPath = Join-Path $folder $tempName

    try {
        $encoding = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText(
            $tempPath, $json + [Environment]::NewLine, $encoding
        )

        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($tempPath, $fullPath, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction Ignore

        throw (
            "Failed to write configuration '$fullPath': " +
            $_.Exception.Message
        )
    }
    #endregion
}

Export-ModuleMember -Function @(
    'Read-ConfigurationHC'
    'Test-ConfigurationHC'
    'Write-ConfigurationHC'
)