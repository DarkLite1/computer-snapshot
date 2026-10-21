#Requires -Version 5.1
<#
.SYNOPSIS
    Read, validate and write version-2 computer configurations on PowerShell 5.1.
#>
. "$PSScriptRoot\Section.ps1"
. "$PSScriptRoot\Schema.ps1"
$script:ItemOrder = @('StartCustomScriptsBefore', 'RegionalSettings', 'UserAccounts', 'UserGroups',
    'FirewallRules', 'CreateFolders', 'SmbShares', 'NetworkCards', 'NtpTimeServers', 'RegistryKeys',
    'ScheduledTasks', 'CopyFilesFolders', 'Software', 'StartCustomScriptsAfter')
$script:ArrayItems = @('StartCustomScriptsBefore', 'UserAccounts', 'UserGroups', 'FirewallRules',
    'NetworkCards', 'ScheduledTasks', 'CopyFilesFolders', 'StartCustomScriptsAfter')

function Get-PropertiesHC {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Keys) }
    if ($Value -is [pscustomobject]) { return @($Value.PSObject.Properties | ForEach-Object { $_.Name }) }
    return @()
}

function Test-ObjectHC {
    param($Value)
    return ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary])
}

function Read-JsonValueHC {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    $wrapper = ConvertFrom-Json -InputObject ('{"Data":' + $text + '}') -ErrorAction Stop
    return ,$wrapper.Data
}

function ConvertTo-LoadedConfigurationHC {
    param($Configuration, [string]$RootFolder, [string]$Source)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $result = [pscustomobject]@{
        SchemaVersion = 2
        Description = $Configuration.Description
        Settings = [ordered]@{ RebootComputer = $false; OpenReportInBrowser = $true; RunElevated = $false }
        Items = [ordered]@{}
        Source = $Source
        Problems = $problems
    }
    $result.PSObject.TypeNames.Insert(0, 'ComputerSnapshot.Configuration')
    if (-not (Test-ObjectHC $Configuration)) {
        $problems.Add("$Source > configuration: expected an object")
        return $result
    }
    foreach ($property in Get-PropertiesHC $Configuration) {
        if ($property -cnotin @('$schema', 'SchemaVersion', 'Description', 'Settings', 'Items')) {
            $problems.Add("$Source > ${property}: unknown property")
        }
    }
    if ($Configuration.SchemaVersion -ne 2 -or $Configuration.SchemaVersion -is [string]) {
        $problems.Add("$Source > SchemaVersion: expected 2; run the configuration converter for a version-1 file")
    }
    foreach ($property in @('Description', '$schema')) {
        if ((Get-PropertiesHC $Configuration) -contains $property -and $Configuration.$property -isnot [string]) {
            $problems.Add("$Source > ${property}: expected a string")
        }
    }
    if ((Get-PropertiesHC $Configuration) -contains 'Settings') {
        if (-not (Test-ObjectHC $Configuration.Settings)) {
            $problems.Add("$Source > Settings: expected an object")
        }
        else {
            foreach ($property in Get-PropertiesHC $Configuration.Settings) {
                if ($property -ceq 'Comment') {
                    if ($Configuration.Settings.Comment -isnot [string]) { $problems.Add("$Source > Settings.Comment: expected a string") }
                }
                elseif ($property -cnotin @('RebootComputer', 'OpenReportInBrowser', 'RunElevated')) {
                    $problems.Add("$Source > Settings.${property}: unknown property")
                }
                elseif ($Configuration.Settings.$property -isnot [bool]) {
                    $problems.Add("$Source > Settings.${property}: expected a Boolean")
                }
                else { $result.Settings[$property] = $Configuration.Settings.$property }
            }
        }
    }
    if (-not (Test-ObjectHC $Configuration.Items) -or @(Get-PropertiesHC $Configuration.Items | Where-Object { $_ -ne 'Comment' }).Count -eq 0) {
        $problems.Add("$Source > Items: expected an object containing at least one item")
        return $result
    }
    foreach ($name in Get-PropertiesHC $Configuration.Items) {
        if ($name -ceq 'Comment') {
            if ($Configuration.Items.Comment -isnot [string]) { $problems.Add("$Source > Items.Comment: expected a string") }
        }
        elseif ($name -cnotin $script:ItemOrder) {
            $problems.Add("$Source > Items.${name}: unknown item")
        }
    }
    foreach ($name in $script:ItemOrder) {
        if ((Get-PropertiesHC $Configuration.Items) -notcontains $name) { continue }
        $data = $Configuration.Items.$name
        if ($data -is [string]) {
            $reference = $data
            try {
                $referencePath = Resolve-RootPathHC $reference $RootFolder
                $data = Read-JsonValueHC $referencePath
                if ($data -is [string]) { throw 'nested section references are not supported' }
            }
            catch {
                $problems.Add("$Source > Items.${name}: reference '$reference': $_")
                continue
            }
        }
        $result.Items[$name] = $data
    }
    return $result
}

function Read-ConfigurationHC {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RootFolder)
    $fullPath = Resolve-RootPathHC $Path $RootFolder
    try { $configuration = Read-JsonValueHC $fullPath }
    catch { throw "${fullPath} > configuration: invalid or unreadable JSON: $_" }
    return ConvertTo-LoadedConfigurationHC $configuration $RootFolder $fullPath
}

function Test-ConfigurationHC {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration, [Parameter(Mandatory)][string]$RootFolder)
    if ($Configuration.PSObject.TypeNames -notcontains 'ComputerSnapshot.Configuration') {
        $Configuration = ConvertTo-LoadedConfigurationHC $Configuration $RootFolder '<configuration>'
    }
    $problems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($problem in $Configuration.Problems) { $problems.Add($problem) }
    $source = $Configuration.Source
    $schema = Get-Content -LiteralPath "$PSScriptRoot\..\config.schema.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in $Configuration.Items.Keys) {
        $data = $Configuration.Items[$name]
        $location = "$source > Items.$name"
        if ($name -in $script:ArrayItems) {
            if ($data -isnot [array]) { $problems.Add("${location}: expected an array"); continue }
            foreach ($index in 0..($data.Count - 1) | Where-Object { $_ -ge 0 -and $_ -lt $data.Count }) {
                if (-not (Test-ObjectHC $data[$index])) { $problems.Add("${location}[$index]: expected an object") }
            }
        }
        elseif (-not (Test-ObjectHC $data)) { $problems.Add("${location}: expected an object"); continue }
        $shapeProblems = @(Test-ShapeHC $data $schema.'$defs'.$name $schema.'$defs' $location)
        foreach ($problem in $shapeProblems) { $problems.Add($problem) }
        if ($shapeProblems.Count) { continue }
        if (Test-EmptySectionHC $data) { continue }
        $assets = @()
        switch ($name) {
            'Software' {
                foreach ($property in @('Remove', 'Install')) {
                    if ((Get-PropertiesHC $data) -contains $property -and $data.$property -isnot [array]) {
                        $problems.Add("${location}.${property}: expected an array")
                    }
                }
                for ($index = 0; $index -lt @($data.Install).Count; $index++) {
                    if ($null -ne $data.Install[$index]) { $assets += @{ Value = $data.Install[$index].ExecutablePath; Property = "Install[$index].ExecutablePath"; Leaf = $true } }
                }
            }
            'CopyFilesFolders' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $assets += @{ Value = $data[$index].From; Property = "[$index].From"; Leaf = $false }
                    if ([string]::IsNullOrWhiteSpace($data[$index].To)) { $problems.Add("${location}[$index].To: expected a destination path") }
                }
            }
            { $_ -in @('StartCustomScriptsBefore', 'StartCustomScriptsAfter') } {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    $assets += @{ Value = $data[$index].Path; Property = "[$index].Path"; Leaf = $true }
                    if ($data[$index].Arguments -and -not (Test-ObjectHC $data[$index].Arguments)) {
                        $problems.Add("${location}[$index].Arguments: expected an object")
                    }
                }
            }
            'ScheduledTasks' {
                for ($index = 0; $index -lt $data.Count; $index++) {
                    foreach ($property in @('TaskName', 'TaskPath', 'Xml')) {
                        if ([string]::IsNullOrWhiteSpace($data[$index].$property)) { $problems.Add("${location}[$index].${property}: expected a nonempty string") }
                    }
                    if ($data[$index].Enabled -isnot [bool]) { $problems.Add("${location}[$index].Enabled: expected a Boolean") }
                    try { $null = [xml]$data[$index].Xml }
                    catch { $problems.Add("${location}[$index].Xml: invalid XML") }
                }
            }
            'SmbShares' {
                foreach ($property in @('Shares', 'Access', 'NTFS')) {
                    if ((Get-PropertiesHC $data) -contains $property -and $data.$property -isnot [array]) { $problems.Add("${location}.${property}: expected an array") }
                }
            }
        }
        foreach ($asset in $assets) {
            $property = $asset.Property
            if ($property -notlike '[[]*') { $property = '.' + $property }
            try {
                if ($asset.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($asset.Value)) { throw 'expected a nonempty path' }
                $path = Resolve-RootPathHC $asset.Value $RootFolder
                $exists = if ($asset.Leaf) { Test-Path -LiteralPath $path -PathType Leaf } else { Test-Path -LiteralPath $path }
                if (-not $exists) { throw "file '$($asset.Value)' not found" }
            }
            catch { $problems.Add("${location}${property}: $_") }
        }
    }
    return $problems.ToArray()
}

function Format-ConfigurationJsonHC {
    param($Value, [int]$Depth = 0, [int]$PrefixLength = 0)
    if ($null -eq $Value) { return 'null' }
    $indent = '  ' * $Depth
    $childIndent = '  ' * ($Depth + 1)
    $newline = [Environment]::NewLine
    if ($Value -is [System.Collections.IDictionary] -or
        ($null -ne $Value -and $Value.GetType() -eq [System.Management.Automation.PSCustomObject])) {
        $names = @(Get-PropertiesHC $Value)
        if (-not $names.Count) { return '{}' }
        $names = @($names | Where-Object { $_ -ceq 'Comment' }) + @($names | Where-Object { $_ -cne 'Comment' })
        $lines = foreach ($name in $names) {
            $key = ConvertTo-Json -InputObject ([string]$name) -Compress
            $formatted = Format-ConfigurationJsonHC -Value $Value.$name -Depth ($Depth + 1) -PrefixLength ($key.Length + 2)
            $childIndent + $key + ': ' + $formatted
        }
        return '{' + $newline + ($lines -join (',' + $newline)) + $newline + $indent + '}'
    }
    if ($Value -is [array]) {
        if (-not $Value.Count) { return '[]' }
        $entries = @(foreach ($entry in $Value) { Format-ConfigurationJsonHC -Value $entry -Depth ($Depth + 1) })
        $inline = '[' + ($entries -join ', ') + ']'
        if (-not $inline.Contains($newline) -and ($indent.Length + $PrefixLength + $inline.Length) -le 80) { return $inline }
        return '[' + $newline + $childIndent + ($entries -join (',' + $newline + $childIndent)) + $newline + $indent + ']'
    }
    return ConvertTo-Json -InputObject $Value -Depth 20 -Compress
}

function Write-ConfigurationHC {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration, [Parameter(Mandatory)][string]$Path)
    $document = [ordered]@{
        '$schema' = '../Scripts/config.schema.json'
        SchemaVersion = 2
    }
    if ($null -ne $Configuration.Description) { $document.Description = $Configuration.Description }
    if ($null -ne $Configuration.Settings) { $document.Settings = $Configuration.Settings }
    $document.Items = $Configuration.Items
    $json = Format-ConfigurationJsonHC $document
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
}

Export-ModuleMember -Function Read-ConfigurationHC, Test-ConfigurationHC, Write-ConfigurationHC