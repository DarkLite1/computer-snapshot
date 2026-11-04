#Requires -Version 5.1

<#
.SYNOPSIS
    Registry helpers shared by the RegistryKeys section and the
    configuration check: value types, value data, paths and entry checks.
    They do not read or change the registry.
#>

$script:RegistryActionsHC = @(
    'Set', 'RemoveValue', 'ClearValues', 'ClearKey', 'RemoveKey'
)

function ConvertTo-RegistryTypeHC {
    # 'DWORD', 'dword' and 'REG_DWORD' all become 'DWord'
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Type
    )

    $types = [ordered]@{
        'STRING'       = 'String'
        'SZ'           = 'String'
        'EXPANDSTRING' = 'ExpandString'
        'EXPAND_SZ'    = 'ExpandString'
        'MULTISTRING'  = 'MultiString'
        'MULTI_SZ'     = 'MultiString'
        'BINARY'       = 'Binary'
        'DWORD'        = 'DWord'
        'QWORD'        = 'QWord'
    }

    $key = $Type.Trim().ToUpperInvariant() -replace '^REG_', ''

    if (-not $types.Contains($key)) {
        throw (
            "unknown registry type '$Type'; use String, ExpandString, " +
            'MultiString, Binary, DWord or QWord'
        )
    }

    $types[$key]
}

function ConvertTo-RegistryNumberHC {
    # Decimal or 0x hexadecimal, stored the way the registry API expects:
    # DWord as Int32 and QWord as Int64, so 0xFFFFFFFF becomes -1
    param(
        $Value,
        [Parameter(Mandatory)][ValidateSet('DWord', 'QWord')][string]$Type
    )

    $text = ([string]$Value).Trim()
    $isQWord = $Type -eq 'QWord'
    $style = [System.Globalization.NumberStyles]::Integer
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if ($text -match '^0x([0-9a-fA-F]+)$') {
        $text = $Matches[1]
        $style = [System.Globalization.NumberStyles]::AllowHexSpecifier
    }
    elseif ($text -notmatch '^-?\d+$') {
        throw "'$Value' is not a number; use decimal (16) or hexadecimal (0x10)"
    }

    if ($style -eq [System.Globalization.NumberStyles]::AllowHexSpecifier) {
        $unsigned = [uint64]0
        if (
            -not [uint64]::TryParse($text, $style, $culture, [ref]$unsigned) -or
            (-not $isQWord -and $unsigned -gt [uint32]::MaxValue)
        ) {
            throw "'$Value' is too large for a $Type"
        }

        $bytes = [BitConverter]::GetBytes($unsigned)

        if ($isQWord) {
            return [BitConverter]::ToInt64($bytes, 0)
        }

        return [BitConverter]::ToInt32($bytes, 0)
    }

    $number = [decimal]0
    if (-not [decimal]::TryParse($text, $style, $culture, [ref]$number)) {
        throw "'$Value' is not a number"
    }

    $minimum, $maximum = if ($isQWord) {
        [decimal][int64]::MinValue, [decimal][uint64]::MaxValue
    }
    else {
        [decimal][int32]::MinValue, [decimal][uint32]::MaxValue
    }

    if ($number -lt $minimum -or $number -gt $maximum) {
        throw "'$Value' is out of range for a $Type"
    }

    if ($number -lt 0) {
        if ($isQWord) {
            return [int64]$number
        }

        return [int32]$number
    }

    $bytes = [BitConverter]::GetBytes([uint64]$number)

    if ($isQWord) {
        return [BitConverter]::ToInt64($bytes, 0)
    }

    [BitConverter]::ToInt32($bytes, 0)
}

function ConvertTo-RegistryDataHC {
    <#
    .SYNOPSIS
        Convert configured data to the value the registry stores.
    .DESCRIPTION
        String, ExpandString: text.
        MultiString: a list of texts; a single text becomes a list of one.
        Binary: hexadecimal text such as '01 0A FF', or a list of numbers
        from 0 to 255.
        DWord, QWord: a number, or text in decimal (16) or hexadecimal (0x10).
    #>
    param(
        $Value,
        [Parameter(Mandatory)][string]$Type
    )

    switch ($Type) {
        { $_ -in @('String', 'ExpandString') } {
            if ($Value -is [array]) {
                throw (
                    "a $Type value is a single text, not a list; " +
                    'use MultiString'
                )
            }

            return [string]$Value
        }
        'MultiString' {
            return , [string[]]@(
                $Value | Where-Object { $null -ne $_ } | ForEach-Object {
                    [string]$_
                }
            )
        }
        'Binary' {
            if ($null -eq $Value) {
                return , [byte[]]@()
            }

            if ($Value -is [array]) {
                $bytes = foreach ($item in $Value) {
                    $number = 0
                    if (
                        -not [int]::TryParse([string]$item, [ref]$number) -or
                        $number -lt 0 -or $number -gt 255
                    ) {
                        throw "'$item' is not a byte; use numbers from 0 to 255"
                    }
                    [byte]$number
                }

                return , [byte[]]@($bytes)
            }

            $hex = ([string]$Value) -replace '[\s,]', '' -replace '^0x', ''

            if ($hex -notmatch '^([0-9a-fA-F]{2})*$') {
                throw (
                    "'$Value' is not hexadecimal binary data; " +
                    "use pairs of hex digits such as '01 0A FF'"
                )
            }

            $bytes = for ($index = 0; $index -lt $hex.Length; $index += 2) {
                [Convert]::ToByte($hex.Substring($index, 2), 16)
            }

            return , [byte[]]@($bytes)
        }
        { $_ -in @('DWord', 'QWord') } {
            if ($Value -is [array]) {
                throw "a $Type value is a single number, not a list"
            }

            return ConvertTo-RegistryNumberHC -Value $Value -Type $Type
        }
    }
}

function Test-RegistryDataEqualHC {
    # Whether two registry values are equal; texts compare case-sensitively
    param(
        $Current,
        $Desired
    )

    if ($Desired -is [array]) {
        $currentItems = @($Current)

        if ($currentItems.Count -ne $Desired.Count) {
            return $false
        }

        for ($index = 0; $index -lt $Desired.Count; $index++) {
            if ([string]$currentItems[$index] -cne [string]$Desired[$index]) {
                return $false
            }
        }

        return $true
    }

    if ($Desired -is [string]) {
        return [string]$Current -ceq $Desired
    }

    [string]$Current -eq [string]$Desired
}

function Format-RegistryDataHC {
    # Registry data as text for messages
    param(
        $Value,
        [string]$Type
    )

    if ($Type -eq 'Binary') {
        return (@($Value) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    }

    if ($Type -eq 'MultiString' -or $Value -is [array]) {
        return (@($Value) | ForEach-Object { """$_""" }) -join ', '
    }

    [string]$Value
}

function ConvertTo-RegistryPathHC {
    # 'HKEY_LOCAL_MACHINE\...' becomes 'Registry::HKEY_LOCAL_MACHINE\...'
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $trimmed = $Path.Trim().TrimEnd('\')

    if ($trimmed -match '^HKEY_') {
        return "Registry::$trimmed"
    }

    $trimmed
}

function Test-BroadRegistryKeyHC {
    <#
    .SYNOPSIS
        Whether a key is a hive root or a key directly below it, such as
        HKLM:\SOFTWARE or HKEY_USERS\<SID>, which are too broad to clear
        or remove.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $segments = @(
        ($Path -replace '^Registry::', '').Split('\') |
        Where-Object { $_ -ne '' }
    )

    $segments.Count -le 2
}

function Get-RegistryEntryProblemHC {
    <#
    .SYNOPSIS
        Problems in one RegistryKeys entry, as text; nothing when it is valid.
    #>
    param(
        [Parameter(Mandatory)]$Entry
    )

    $action = if ($Entry.Action) {
        [string]$Entry.Action
    }
    else {
        'Set'
    }

    if ($action -notin $script:RegistryActionsHC) {
        return (
            "unknown Action '$action'; use " +
            ($script:RegistryActionsHC -join ', ')
        )
    }

    if ([string]::IsNullOrWhiteSpace($Entry.Path)) {
        return 'Path is required'
    }

    $names = @($Entry.PSObject.Properties | ForEach-Object { $_.Name })
    if ($Entry -is [System.Collections.IDictionary]) {
        $names = @($Entry.Keys)
    }

    switch ($action) {
        'Set' {
            foreach ($property in @('Name', 'Type', 'Value')) {
                if ($names -notcontains $property) {
                    "$property is required for Action Set"
                }
            }

            if ($names -contains 'Type') {
                try {
                    $type = ConvertTo-RegistryTypeHC -Type ([string]$Entry.Type)
                    $dataParams = @{
                        Value = $Entry.Value
                        Type  = $type
                    }
                    $null = ConvertTo-RegistryDataHC @dataParams
                }
                catch {
                    $_.Exception.Message
                }
            }
        }
        'RemoveValue' {
            if ($names -notcontains 'Name') {
                'Name is required for Action RemoveValue'
            }
        }
        default {
            $registryPath = ConvertTo-RegistryPathHC $Entry.Path

            if (Test-BroadRegistryKeyHC -Path $registryPath) {
                (
                    "Action $action is refused for '$($Entry.Path)', a hive " +
                    'root or a key directly below it; use a more specific key'
                )
            }
        }
    }
}