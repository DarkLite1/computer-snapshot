#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\Configuration.psm1" -Force
    . "$PSScriptRoot\Section.ps1"
    $schemaPath = Join-Path $PSScriptRoot '..\config.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
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