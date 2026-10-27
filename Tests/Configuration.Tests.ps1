#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
}
Describe 'Restore input placeholders' {
    It 'resolves nested string values once and preserves other value types and arrays' {
        $items = '{"UserAccounts":[{"Name":"{{input:Account name}}","Password":"{{password:Account password}}","Enabled":false}],"UserGroups":[],"NetworkCards":[{"Address":"{{ipv4:IPv4 address}}"}],"CreateFolders":{"FolderPaths":["{{input:Account name}}"],"Comment":"{{input:Ignored}}"},"Number":24,"Nothing":null}' | ConvertFrom-Json
        $script:requests = @()
        $result = Resolve-RestoreInputHC -Items $items -ReadValue {
            param($field)
            $script:requests += $field.Path
            switch ($field.Kind) { 'input' { 'Example' }; 'password' { 'Test-only password!"\$' }; 'ipv4' { '192.0.2.10' } }
        }
        $requests.Count | Should -Be 3
        $items.UserAccounts[0].Name | Should -Be 'Example'
        $items.CreateFolders.FolderPaths[0] | Should -Be 'Example'
        $items.UserAccounts[0].Password | Should -BeExactly 'Test-only password!"\$'
        $items.NetworkCards[0].Address | Should -Be '192.0.2.10'
        $items.UserAccounts.GetType().IsArray | Should -BeTrue
        $items.UserGroups.Count | Should -Be 0
        $items.UserAccounts[0].Enabled | Should -BeFalse
        $items.Number | Should -Be 24
        $items.Nothing | Should -BeNullOrEmpty
        $items.CreateFolders.Comment | Should -Be '{{input:Ignored}}'
        $result.SecretValues | Should -Be @('Test-only password!"\$')
    }
    It 'leaves placeholders unchanged when any input is cancelled' {
        $items = @{ UserAccounts = @(@{ Name = '{{input:Name}}'; Password = '{{password:Password}}' }) }
        { Resolve-RestoreInputHC -Items $items -ReadValue { param($field) if ($field.Kind -eq 'input') { 'Example' } } } | Should -Throw '*cancelled*'
        $items.UserAccounts[0].Name | Should -Be '{{input:Name}}'
        $items.UserAccounts[0].Password | Should -Be '{{password:Password}}'
    }
    It 'rejects malformed or embedded placeholders before requesting values' {
        foreach ($placeholder in @('{{input: }}', '{{unknown:Name}}', 'prefix {{input:Name}}')) {
            { Get-RestoreInputFieldsHC -Data @{ UserAccounts = @(@{ Name = $placeholder }) } } | Should -Throw '*complete*'
        }
    }
    It 'validates required values and canonical IPv4 addresses without exposing the value' {
        foreach ($value in @('', ' ', '999.1.1.1', '127.1', '::1')) {
            Test-RestoreInputValueHC -Kind ipv4 -Value $value | Should -BeFalse
        }
        Test-RestoreInputValueHC -Kind ipv4 -Value '192.0.2.10' | Should -BeTrue
        $items = @{ NetworkCards = @(@{ Address = '{{ipv4:Address}}' }) }
        { Resolve-RestoreInputHC -Items $items -ReadValue { 'invalid-address' } } | Should -Throw '*supplied input is empty or invalid*'
        Protect-RestoreInputTextHC -Text 'Failed: test-secret' -SecretValues @('test-secret') | Should -Be 'Failed: [redacted]'
    }
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

Describe 'Shared snapshot catalogue' {
    It 'preserves the established order and maps every item to an existing script' {
        $scripts = Get-SnapshotScriptsHC
        @($scripts.Keys) | Should -Be @(
            'StartCustomScriptsBefore', 'RegionalSettings', 'UserAccounts', 'UserGroups',
            'FirewallRules', 'CreateFolders', 'SmbShares', 'NetworkCards', 'NtpTimeServers',
            'RegistryKeys', 'ScheduledTasks', 'CopyFilesFolders', 'Software', 'StartCustomScriptsAfter'
        )
        foreach ($script in $scripts.Values) {
            Join-Path "$PSScriptRoot\..\Scripts" $script | Should -Exist
        }
    }
    It 'returns an independent map so caller overrides cannot change the catalogue' {
        $scripts = Get-SnapshotScriptsHC
        $scripts.UserAccounts = 'custom.ps1'
        (Get-SnapshotScriptsHC).UserAccounts | Should -Be 'User accounts import export.ps1'
    }
    It 'matches the items supported by the JSON schema' {
        $schema = Get-Content -LiteralPath "$PSScriptRoot\..\Scripts\config.schema.json" -Raw | ConvertFrom-Json
        $names = @($schema.properties.Items.properties.PSObject.Properties.Name | Where-Object { $_ -ne 'Comment' } | Sort-Object)
        @((Get-SnapshotScriptsHC).Keys | Sort-Object) | Should -Be $names
    }
    It 'loads all empty sections in catalogue order regardless of JSON order' {
        $schema = Get-Content -LiteralPath "$PSScriptRoot\..\Scripts\config.schema.json" -Raw | ConvertFrom-Json
        $items = [ordered]@{}
        foreach ($name in (Get-SnapshotScriptsHC).Keys | Sort-Object -Descending) {
            $items[$name] = if ($schema.'$defs'.$name.type -eq 'array') { ,@() } else { @{} }
        }
        $path = Join-Path $TestDrive 'all-items.json'
        Write-ConfigurationHC @{ SchemaVersion = 2; Items = $items } $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        @($loaded.Items.Keys) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        @(Test-ConfigurationHC $loaded $TestDrive).Count | Should -Be 0
    }
}

Describe 'Safe configuration writing' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $folder -ItemType Directory
        $path = Join-Path $folder 'Example.json'
        $document = @{ SchemaVersion = 2; Items = [ordered]@{ CreateFolders = @{ FolderPaths = @('C:\Example') } } }
    }
    It 'creates a new configuration file' {
        Write-ConfigurationHC $document $path
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Items.CreateFolders.FolderPaths | Should -Be @('C:\Example')
    }
    It 'replaces an existing configuration file' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        Write-ConfigurationHC $document $path
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).SchemaVersion | Should -Be 2
    }
    It 'leaves no temporary files behind' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        Write-ConfigurationHC $document $path
        @(Get-ChildItem -LiteralPath $folder -Force).Name | Should -Be @('Example.json')
    }
    It 'keeps the existing file intact and cleans up when replacing fails' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        $before = Get-Content -LiteralPath $path -Raw
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            { Write-ConfigurationHC $document $path } | Should -Throw '*Failed to write configuration*'
            (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
            @(Get-ChildItem -LiteralPath $folder -Force).Name | Should -Be @('Example.json')
        }
        finally { Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false }
    }
    It 'reports a missing folder without creating anything' {
        $missing = Join-Path $folder 'Missing\Example.json'
        { Write-ConfigurationHC $document $missing } | Should -Throw '*Failed to write configuration*'
        Join-Path $folder 'Missing' | Should -Not -Exist
    }
}