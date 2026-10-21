#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\Configuration.psm1" -Force
}
Describe 'Version 2 configuration' {
    BeforeEach {
        $path = Join-Path $TestDrive 'configuration.json'
        $configuration = [ordered]@{ SchemaVersion = 2; Items = [ordered]@{ Software = @{}; UserAccounts = @() } }
    }
    It 'loads inline sections with defaults in fixed order' {
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        @($loaded.Items.Keys) | Should -Be @('UserAccounts', 'Software')
        $loaded.Settings.RebootComputer | Should -BeFalse
        @(Test-ConfigurationHC $loaded $TestDrive).Count | Should -Be 0
    }
    It 'preserves empty and singleton arrays without a UTF8 BOM' {
        $configuration.Items.UserAccounts = @([pscustomobject]@{ Name = 'Example' })
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        $loaded.Items.UserAccounts.GetType().IsArray | Should -BeTrue
        $loaded.Items.UserAccounts.Count | Should -Be 1
        [IO.File]::ReadAllBytes($path)[0] | Should -Be 123
    }
    It 'formats with two spaces and puts comments first in every nested object without mutating input' {
        $configuration.Settings = [ordered]@{ RunElevated = $false; Comment = 'Settings note' }
        $configuration.Items = [ordered]@{
            UserAccounts = @([pscustomobject][ordered]@{ Name = 'Example'; Comment = 'Account note'; Enabled = $true })
            Comment = 'Items note'
        }
        Write-ConfigurationHC $configuration $path
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match '(?m)^  "SchemaVersion": 2,'
        $text | Should -Match '"Settings": \{\r?\n    "Comment": "Settings note",'
        $text | Should -Match '"Items": \{\r?\n    "Comment": "Items note",'
        $text | Should -Match '\{\r?\n        "Comment": "Account note",\r?\n        "Name": "Example",'
        @($configuration.Settings.Keys)[0] | Should -Be 'RunElevated'
        $text.EndsWith([Environment]::NewLine) | Should -BeTrue
    }
    It 'keeps short arrays compact and expands arrays that exceed 80 columns' {
        $configuration.Items.Software = [ordered]@{
            Remove = @('Short', 'Another')
            Install = @()
            Comment = 'Software note'
        }
        Write-ConfigurationHC $configuration $path
        [IO.File]::ReadAllText($path) | Should -Match '"Remove": \["Short", "Another"\]'
        $configuration.Items.Software.Remove = @(('A' * 35), ('B' * 35))
        Write-ConfigurationHC $configuration $path
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match '"Remove": \[\r?\n'
        @($text -split '\r?\n' | Where-Object { $_.Length -gt 80 }).Count | Should -Be 0
        (Read-ConfigurationHC $path $TestDrive).Items.Software.Remove | Should -Be $configuration.Items.Software.Remove
    }
    It 'preserves escaped text, nulls, booleans and numbers while formatting' {
        $xml = '<Task attr="quoted">' + "`r`n" + ('text { [ ] } ' * 12) + '</Task>'
        $configuration.Items.ScheduledTasks = @([ordered]@{ TaskName = 'Example'; TaskPath = '\HC\'; Enabled = $false; Xml = $xml })
        $configuration.Items.Software = @{ Install = @(@{ ExecutablePath = 'C:\Example.exe'; Arguments = $null }) }
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        $loaded.Items.ScheduledTasks[0].Xml | Should -BeExactly $xml
        $loaded.Items.ScheduledTasks[0].Enabled | Should -BeFalse
        $loaded.Items.Software.Install[0].Arguments | Should -BeNullOrEmpty
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).SchemaVersion | Should -Be 2
    }
    It 'resolves references from the USB root rather than the current directory' {
        '[{"Name":"Example"}]' | Set-Content -LiteralPath (Join-Path $TestDrive 'shared.json') -Encoding UTF8
        $configuration.Items.UserAccounts = 'shared.json'
        Write-ConfigurationHC $configuration $path
        $location = Get-Location
        try {
            Set-Location $env:TEMP
            $loaded = Read-ConfigurationHC $path $TestDrive
            $loaded.Items.UserAccounts[0].Name | Should -Be 'Example'
        }
        finally { Set-Location $location }
    }
    It 'rejects a nested reference' {
        '"another.json"' | Set-Content -LiteralPath (Join-Path $TestDrive 'shared.json')
        $configuration.Items.UserAccounts = 'shared.json'
        Write-ConfigurationHC $configuration $path
        Test-ConfigurationHC (Read-ConfigurationHC $path $TestDrive) $TestDrive | Should -Match 'nested section references'
    }
    It 'reports a missing reference' {
        $configuration.Items.UserAccounts = 'missing.json'
        @(Test-ConfigurationHC $configuration $TestDrive) | Should -Match 'Items.UserAccounts.*missing.json'
    }
    It 'reports invalid referenced JSON' {
        'not json' | Set-Content -LiteralPath (Join-Path $TestDrive 'shared.json')
        $configuration.Items.UserAccounts = 'shared.json'
        @(Test-ConfigurationHC $configuration $TestDrive) | Should -Match 'Items.UserAccounts.*shared.json'
    }
    It 'reports three independent problems together' {
        $configuration.SchemaVersion = 1
        $configuration.Items.Unknown = @{}
        $configuration.Items.Software = @(@{})
        $problems = @(Test-ConfigurationHC $configuration $TestDrive)
        $problems.Count | Should -Be 3
        $problems -join "`n" | Should -Match 'SchemaVersion'
        $problems -join "`n" | Should -Match 'Items.Unknown'
        $problems -join "`n" | Should -Match 'Items.Software'
    }
    It 'rejects unknown top-level properties' {
        $configuration.Action = 'RestoreSnapshot'
        @(Test-ConfigurationHC $configuration $TestDrive) | Should -Match 'Action: unknown property'
    }
    It 'checks asset paths relative to the root' {
        'asset' | Set-Content -LiteralPath (Join-Path $TestDrive 'app.exe')
        $configuration.Items.Software = @{ Install = @(@{ ExecutablePath = 'app.exe' }); Remove = @() }
        @(Test-ConfigurationHC $configuration $TestDrive).Count | Should -Be 0
        $configuration.Items.Software.Install[0].ExecutablePath = 'missing.exe'
        @(Test-ConfigurationHC $configuration $TestDrive) | Should -Match 'Items.Software.Install\[0\].ExecutablePath.*not found'
    }
}