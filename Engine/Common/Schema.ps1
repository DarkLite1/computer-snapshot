#Requires -Version 5.1

<#
.SYNOPSIS
    Validate the JSON-schema keywords used by the bundled configuration
    contract.
#>

function Test-ShapeHC {
    param(
        $Value,
        $Schema,
        $Definitions,
        [string]$Location
    )

    if ($Schema.'$ref') {
        $name = $Schema.'$ref' -replace '^#/\$defs/', ''

        Test-ShapeHC $Value $Definitions.$name $Definitions $Location

        return
    }

    if ($Schema.type) {
        $typeMatched = $false

        foreach ($type in @($Schema.type)) {
            switch ($type) {
                'null' {
                    if ($null -eq $Value) {
                        $typeMatched = $true
                    }
                }
                'object' {
                    if (Test-ObjectHC $Value) {
                        $typeMatched = $true
                    }
                }
                'array' {
                    if ($Value -is [array]) {
                        $typeMatched = $true
                    }
                }
                'string' {
                    if ($Value -is [string] -or $Value -is [datetime]) {
                        $typeMatched = $true
                    }
                }
                'boolean' {
                    if ($Value -is [bool]) {
                        $typeMatched = $true
                    }
                }
                'integer' {
                    if (
                        $Value -is [int] -or
                        $Value -is [long] -or
                        $Value -is [uint32] -or
                        $Value -is [uint64]
                    ) {
                        $typeMatched = $true
                    }
                }
            }
        }

        if (-not $typeMatched) {
            "${Location}: expected $(@($Schema.type) -join ' or ')"
            return
        }
    }

    if ($null -ne $Schema.const -and $Value -ne $Schema.const) {
        "${Location}: expected $($Schema.const)"
    }

    if ($Schema.enum -and $Value -notin $Schema.enum) {
        "${Location}: invalid value '$Value'"
    }

    if (
        $null -ne $Schema.minLength -and $Value.Length -lt $Schema.minLength
    ) {
        "${Location}: string is empty"
    }

    if (
        $Schema.pattern -and
        $Value -is [string] -and
        $Value -cnotmatch $Schema.pattern
    ) {
        if ($Schema.description) {
            "${Location}: expected $($Schema.description)"
        }
        else {
            "${Location}: '$Value' does not match '$($Schema.pattern)'"
        }
    }

    $isNumber = $Value -is [int] -or $Value -is [long] -or $Value -is [double]

    if (
        $isNumber -and
        (
            ($null -ne $Schema.minimum -and $Value -lt $Schema.minimum) -or
            ($null -ne $Schema.maximum -and $Value -gt $Schema.maximum)
        )
    ) {
        (
            "${Location}: expected a number from " +
            "$($Schema.minimum) to $($Schema.maximum)"
        )
    }

    foreach ($keyword in @('oneOf', 'anyOf')) {
        if ($Schema.$keyword) {
            $matchCount = 0
            foreach ($alternative in $Schema.$keyword) {
                if (
                    @(
                        Test-ShapeHC $Value $alternative $Definitions $Location
                    ).Count -eq 0
                ) {
                    $matchCount++
                }
            }
            if (
                $matchCount -eq 0 -or
                ($keyword -eq 'oneOf' -and $matchCount -ne 1)
            ) {
                # Alternatives that only name one required property each
                $choices = [System.Collections.Generic.List[string]]::new()

                foreach ($alternative in $Schema.$keyword) {
                    if (
                        @(Get-PropertiesHC $alternative) -ceq 'required' -and
                        @(Get-PropertiesHC $alternative).Count -eq 1 -and
                        @($alternative.required).Count -eq 1
                    ) {
                        $choices.Add($alternative.required[0])
                    }
                }

                if (
                    $keyword -eq 'oneOf' -and
                    $choices.Count -eq @($Schema.$keyword).Count
                ) {
                    if ($choices.Count -eq 2) {
                        $list = $choices -join ' or '

                        if ($matchCount -eq 0) {
                            "${Location}: needs $list"
                        }
                        else {
                            "${Location}: use either $list, not both"
                        }
                    }
                    else {
                        $list = (
                            ($choices[0..($choices.Count - 2)] -join ', ') +
                            ' and ' + $choices[-1]
                        )

                        if ($matchCount -eq 0) {
                            "${Location}: needs one of $list"
                        }
                        else {
                            "${Location}: use only one of $list"
                        }
                    }
                }
                elseif (
                    $matchCount -eq 0 -and
                    @($Schema.$keyword | Where-Object { $_.type }).Count -eq
                    @($Schema.$keyword).Count
                ) {
                    # Alternatives by type: explain the one of the value's type
                    $sameType = @(
                        $Schema.$keyword | Where-Object {
                            $typeOnly = [pscustomobject]@{ type = $_.type }
                            $shapeParams = @{
                                Value       = $Value
                                Schema      = $typeOnly
                                Definitions = $Definitions
                                Location    = $Location
                            }
                            @(Test-ShapeHC @shapeParams).Count -eq 0
                        }
                    )

                    if ($sameType.Count -eq 1) {
                        Test-ShapeHC $Value $sameType[0] $Definitions $Location
                    }
                    else {
                        $types = $Schema.$keyword | ForEach-Object { $_.type }
                        "${Location}: expected $(@($types) -join ' or ')"
                    }
                }
                else {
                    (
                        "${Location}: missing required properties " +
                        'or invalid section shape'
                    )
                }
            }
        }
    }

    if (Test-ObjectHC $Value) {
        $names = @(Get-PropertiesHC $Value)

        if (
            $null -ne $Schema.maxProperties -and
            $names.Count -gt $Schema.maxProperties
        ) {
            "${Location}: too many properties"
        }

        foreach ($required in $Schema.required) {
            if ($names -cnotcontains $required) {
                "${Location}.${required}: required property is missing"
            }
        }

        foreach ($name in $names) {
            if ((Get-PropertiesHC $Schema.properties) -ccontains $name) {
                $shapeParams = @{
                    Value       = $Value.$name
                    Schema      = $Schema.properties.$name
                    Definitions = $Definitions
                    Location    = "${Location}.${name}"
                }
                Test-ShapeHC @shapeParams
            }
            else {
                $patternMatched = $false
                foreach (
                    $pattern in
                    Get-PropertiesHC $Schema.patternProperties
                ) {
                    if ($name -match $pattern) {
                        $patternMatched = $true

                        $shapeParams = @{
                            Value       = $Value.$name
                            Schema      = $Schema.patternProperties.$pattern
                            Definitions = $Definitions
                            Location    = "${Location}.${name}"
                        }
                        Test-ShapeHC @shapeParams
                    }
                }
                if (
                    -not $patternMatched -and
                    $Schema.additionalProperties -eq $false
                ) {
                    "${Location}.${name}: unknown property"
                }
            }
        }
    }
    elseif ($Value -is [array] -and $Schema.items) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $shapeParams = @{
                Value       = $Value[$index]
                Schema      = $Schema.items
                Definitions = $Definitions
                Location    = "${Location}[$index]"
            }
            Test-ShapeHC @shapeParams
        }
    }
}