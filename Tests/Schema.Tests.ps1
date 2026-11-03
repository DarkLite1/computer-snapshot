#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
    $schemaPath = Join-Path $PSScriptRoot '..\Scripts\config.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $root = Split-Path $PSScriptRoot -Parent
    $shippedConfigurations = @(Get-ChildItem -LiteralPath (Join-Path $root 'Configurations') -Filter '*.json' -File | ForEach-Object FullName)
    $shippedSharedSections = @(Get-ChildItem -LiteralPath (Join-Path $root 'Shared') -Filter '*.json' -File | ForEach-Object FullName)
    $mapping = @{
        'Folders' = 'CreateFolders'; 'Copy files folders' = 'CopyFilesFolders'; 'NTP time servers' = 'NtpTimeServers'
        'Network cards' = 'NetworkCards'; 'Regional settings' = 'RegionalSettings'; 'Software' = 'Software'
        'User accounts' = 'UserAccounts'; 'User groups' = 'UserGroups'; 'Registry keys' = 'RegistryKeys'
        'Firewall rules' = 'FirewallRules'; 'Scheduled tasks' = 'ScheduledTasks'; 'Smb shares' = 'SmbShares'
        'Start custom scripts' = 'StartCustomScriptsBefore'
    }
}
Describe 'Schema contract' {
    It 'resolves the prompted setup example into valid data without changing its file or applying settings' {
        $file = Join-Path $root 'Configurations\Example prompted setup.json'
        $before = Get-Content -LiteralPath $file -Raw
        $loaded = Read-ConfigurationHC $file $root
        @(Get-RestoreInputFieldsHC -Data $loaded.Items).Count | Should -Be 3
        $null = Resolve-RestoreInputHC -Items $loaded.Items -ReadValue {
            param($field)
            switch ($field.Kind) { 'input' { 'Example' }; 'password' { 'Test-only password!42' }; 'ipv4' { '192.0.2.10' } }
        }
        @(Test-ConfigurationHC $loaded $root).Count | Should -Be 0
        $loaded.Items.NtpTimeServers.TimeServerNames | Should -Be @('192.0.2.10')
        (Get-Content -LiteralPath $file -Raw) | Should -BeExactly $before
    }
    It 'validates every component example with the runtime shape validator' {
        foreach ($name in $mapping.Values) {
            $data = Read-SectionExampleHC (Join-Path $root "Examples\$name.json")
            $problems = @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ $name = $data } } $TestDrive)
            @($problems | Where-Object { $_ -notmatch "file '.+' not found" }).Count | Should -Be 0 -Because ($problems -join '; ')
        }
    }
    It 'validates every component example using Test-Json on PowerShell 7' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        foreach ($name in $mapping.Values) {
            $document = @{ SchemaVersion = 3; Items = @{ $name = Read-SectionExampleHC (Join-Path $root "Examples\$name.json") } }
            $document | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop | Should -BeTrue
        }
    }
    It 'rejects misspelled section properties at runtime' {
        $problems = @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Instal = @() } } } $TestDrive)
        $problems -join ';' | Should -Match 'Software.Instal: unknown property'
    }
    It 'names the choice when a task has both or neither of Xml and XmlFile' {
        $task = [ordered]@{ TaskName = 'T'; TaskPath = '\HC\'; Enabled = $true }

        $none = @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ ScheduledTasks = @($task) } } $TestDrive)
        $none -join ';' | Should -Match 'ScheduledTasks\[0\]: needs Xml or XmlFile'

        $both = @{ TaskName = 'T'; TaskPath = '\HC\'; Enabled = $true; Xml = '<Task/>'; XmlFile = 'Files\Task.xml' }
        $problems = @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ ScheduledTasks = @($both) } } $TestDrive)
        $problems -join ';' | Should -Match 'ScheduledTasks\[0\]: use either Xml or XmlFile, not both'
    }
    It 'rejects empty array entries but permits empty sections' {
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ UserAccounts = @(@{}) } } $TestDrive) -join ';' | Should -Match 'Name: required'
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ CreateFolders = @{}; ScheduledTasks = @() } } $TestDrive).Count | Should -Be 0
    }
    It 'requires schema property casing and string comments' {
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ install = @() } } } $TestDrive) -join ';' | Should -Match 'install: unknown'
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ software = @{} } } $TestDrive) -join ';' | Should -Match 'software: unknown'
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Comment = 5; Software = @{} } } $TestDrive) -join ';' | Should -Match 'Comment: expected a string'
    }
    It 'combines the shared files of the combined sections example in order, only below safe example locations' {
        $loaded = Read-ConfigurationHC (Join-Path $root 'Configurations\Example combined sections.json') $root
        $loaded.Problems.Count | Should -Be 0 -Because ($loaded.Problems -join '; ')
        @($loaded.Items.Keys) | Should -Be @('CreateFolders', 'RegistryKeys')
        @($loaded.Items.CreateFolders.FolderPaths) | Should -Be @(
            '%ProgramData%\ComputerSnapshot example\Logs'
            '%ProgramData%\ComputerSnapshot example\Scripts'
            '%ProgramData%\ComputerSnapshot example\Kiosk\Media'
        )
        $entries = @($loaded.Items.RegistryKeys.RunAsCurrentUser.RegistryKeys)
        @($entries.Name) | Should -Be @('Role', 'SupportDesk', 'StartPage', 'IdleLogoffMinutes')
        foreach ($entry in $entries) { $entry.Path | Should -BeLike 'HKCU:\Software\ComputerSnapshot\Example*' }
        $loaded.Settings.RebootComputer | Should -BeFalse
    }
    It 'validates every shipped configuration and its shared references' {
        $shippedConfigurations.Count | Should -BeGreaterOrEqual 3
        $shippedSharedSections.Count | Should -BeGreaterOrEqual 5
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
                $document = @{ SchemaVersion = 3; Items = @{ $_ = $data } }
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