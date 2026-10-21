#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\Configuration.psm1" -Force
    . "$PSScriptRoot\Section.ps1"
    $schemaPath = Join-Path $PSScriptRoot '..\config.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $shippedConfigurations = @((Join-Path $root 'Configurations\Example PC1.json'))
    $shippedSharedSections = @((Join-Path $root 'Shared\UserAccounts kiosk.json'))
    $mapping = @{
        'Folders' = 'CreateFolders'; 'Copy files folders' = 'CopyFilesFolders'; 'NTP time servers' = 'NtpTimeServers'
        'Network cards' = 'NetworkCards'; 'Regional settings' = 'RegionalSettings'; 'Software' = 'Software'
        'User accounts' = 'UserAccounts'; 'User groups' = 'UserGroups'; 'Registry keys' = 'RegistryKeys'
        'Firewall rules' = 'FirewallRules'; 'Scheduled tasks' = 'ScheduledTasks'; 'Smb shares' = 'SmbShares'
        'Start custom scripts' = 'StartCustomScriptsBefore'
    }
}
Describe 'Schema contract' {
    It 'validates every component example with the runtime shape validator' {
        foreach ($file in Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot -Parent) -Filter Example.json -Recurse) {
            $name = $mapping[$file.Directory.Name -replace ' import export$', '']
            $data = Read-SectionExampleHC $file.FullName
            $problems = @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ $name = $data } } $TestDrive)
            @($problems | Where-Object { $_ -notmatch "file '.+' not found" }).Count | Should -Be 0 -Because ($problems -join '; ')
        }
    }
    It 'validates every component example using Test-Json on PowerShell 7' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        foreach ($file in Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot -Parent) -Filter Example.json -Recurse) {
            $name = $mapping[$file.Directory.Name -replace ' import export$', '']
            $document = @{ SchemaVersion = 2; Items = @{ $name = Read-SectionExampleHC $file.FullName } }
            $document | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop | Should -BeTrue
        }
    }
    It 'rejects misspelled section properties at runtime' {
        $problems = @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ Software = @{ Instal = @() } } } $TestDrive)
        $problems -join ';' | Should -Match 'Software.Instal: unknown property'
    }
    It 'rejects empty array entries but permits empty sections' {
        @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ UserAccounts = @(@{}) } } $TestDrive) -join ';' | Should -Match 'Name: required'
        @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ CreateFolders = @{}; ScheduledTasks = @() } } $TestDrive).Count | Should -Be 0
    }
    It 'requires schema property casing and string comments' {
        @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ Software = @{ install = @() } } } $TestDrive) -join ';' | Should -Match 'install: unknown'
        @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ software = @{} } } $TestDrive) -join ';' | Should -Match 'software: unknown'
        @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ Comment = 5; Software = @{} } } $TestDrive) -join ';' | Should -Match 'Comment: expected a string'
    }
    It 'validates every shipped configuration and its shared references' {
        foreach ($file in Get-Item -LiteralPath $shippedConfigurations -ErrorAction Stop) {
            $loaded = Read-ConfigurationHC $file.FullName $root
            $problems = @(Test-ConfigurationHC $loaded $root)
            $problems.Count | Should -Be 0 -Because ($problems -join '; ')
        }
    }
    It 'checks shipped configurations and Shared sections with Test-Json' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        foreach ($file in Get-Item -LiteralPath $shippedConfigurations -ErrorAction Stop) {
            Get-Content -LiteralPath $file.FullName -Raw | Test-Json -SchemaFile $schemaPath -ErrorAction Stop | Should -BeTrue
        }
        foreach ($file in Get-Item -LiteralPath $shippedSharedSections -ErrorAction Stop) {
            $data = Read-SectionExampleHC $file.FullName
            $matches = @($schema.'$defs'.PSObject.Properties.Name | Where-Object {
                $document = @{ SchemaVersion = 2; Items = @{ $_ = $data } }
                $document | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
            })
            $matches.Count | Should -BeGreaterThan 0 -Because "Shared file '$($file.Name)' must match a section shape"
        }
    }
    It 'gives descriptions to every declared property' {
        function Test-DescriptionsHC($node) {
            if ($node -is [pscustomobject] -and $node.properties -is [pscustomobject]) {
                foreach ($property in $node.properties.PSObject.Properties) {
                    $property.Value.description | Should -Not -BeNullOrEmpty -Because $property.Name
                }
            }
            if ($node -is [pscustomobject]) { foreach ($property in $node.PSObject.Properties) { Test-DescriptionsHC $property.Value } }
            elseif ($node -is [array]) { foreach ($item in $node) { Test-DescriptionsHC $item } }
        }
        Test-DescriptionsHC $schema
    }
}