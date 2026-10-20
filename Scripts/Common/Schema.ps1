#Requires -Version 5.1
<#
.SYNOPSIS
    Validate the JSON-schema keywords used by the bundled configuration contract.
#>
function Test-ShapeHC {
    param($Value, $Schema, $Definitions, [string]$Location)
    if ($Schema.'$ref') {
        $name = $Schema.'$ref' -replace '^#/\$defs/', ''
        Test-ShapeHC $Value $Definitions.$name $Definitions $Location
        return
    }
    if ($Schema.type) {
        $matches = $false
        foreach ($type in @($Schema.type)) {
            switch ($type) {
                'null' { if ($null -eq $Value) { $matches = $true } }
                'object' { if (Test-ObjectHC $Value) { $matches = $true } }
                'array' { if ($Value -is [array]) { $matches = $true } }
                'string' { if ($Value -is [string] -or $Value -is [datetime]) { $matches = $true } }
                'boolean' { if ($Value -is [bool]) { $matches = $true } }
                'integer' { if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) { $matches = $true } }
            }
        }
        if (-not $matches) { "${Location}: expected $(@($Schema.type) -join ' or ')"; return }
    }
    if ($null -ne $Schema.const -and $Value -ne $Schema.const) { "${Location}: expected $($Schema.const)" }
    if ($Schema.enum -and $Value -notin $Schema.enum) { "${Location}: invalid value '$Value'" }
    if ($null -ne $Schema.minLength -and $Value.Length -lt $Schema.minLength) { "${Location}: string is empty" }
    foreach ($keyword in @('oneOf', 'anyOf')) {
        if ($Schema.$keyword) {
            $matches = 0
            foreach ($alternative in $Schema.$keyword) {
                if (@(Test-ShapeHC $Value $alternative $Definitions $Location).Count -eq 0) { $matches++ }
            }
            if ($matches -eq 0 -or ($keyword -eq 'oneOf' -and $matches -ne 1)) { "${Location}: missing required properties or invalid section shape" }
        }
    }
    if (Test-ObjectHC $Value) {
        $names = @(Get-PropertiesHC $Value)
        if ($null -ne $Schema.maxProperties -and $names.Count -gt $Schema.maxProperties) { "${Location}: too many properties" }
        foreach ($required in $Schema.required) {
            if ($names -cnotcontains $required) { "${Location}.${required}: required property is missing" }
        }
        foreach ($name in $names) {
            if ((Get-PropertiesHC $Schema.properties) -ccontains $name) {
                Test-ShapeHC $Value.$name $Schema.properties.$name $Definitions "${Location}.${name}"
            }
            else {
                $patternMatched = $false
                foreach ($pattern in Get-PropertiesHC $Schema.patternProperties) {
                    if ($name -match $pattern) { $patternMatched = $true; Test-ShapeHC $Value.$name $Schema.patternProperties.$pattern $Definitions "${Location}.${name}" }
                }
                if (-not $patternMatched -and $Schema.additionalProperties -eq $false) { "${Location}.${name}: unknown property" }
            }
        }
    }
    elseif ($Value -is [array] -and $Schema.items) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Test-ShapeHC $Value[$index] $Schema.items $Definitions "${Location}[$index]"
        }
    }
}