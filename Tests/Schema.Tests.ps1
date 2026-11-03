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
        'Folders' = 'CreateFolders'; 'Copy files folders' = 'CopyFilesFolders'; 'NTP time servers' = 'NtpTimeServers'; 'Hosts file entries' = 'HostsFileEntries'
        'Network cards' = 'NetworkCards'; 'Regional settings' = 'RegionalSettings'; 'Software' = 'Software'
        'User accounts' = 'UserAccounts'; 'User groups' = 'UserGroups'; 'Registry keys' = 'RegistryKeys'
        'Firewall rules' = 'FirewallRules'; 'Scheduled tasks' = 'ScheduledTasks'; 'Smb shares' = 'SmbShares'
        'Start custom scripts' = 'StartCustomScriptsBefore'
        'Start custom scripts after' = 'StartCustomScriptsAfter'
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
    It 'requires objects in Software.Remove and only one of UninstallArguments and UninstallCommand' {
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Remove = @('Old App') } } } $TestDrive) -join ';' |
            Should -Match 'Software.Remove\[0\]: expected object'
        $removal = @{ DisplayName = 'Old App'; UninstallArguments = '/S'; UninstallCommand = 'x.exe' }
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Remove = @($removal) } } } $TestDrive) -join ';' |
            Should -Match 'Software.Remove\[0\]: use either UninstallArguments or UninstallCommand, not both'
        $removal.Remove('UninstallCommand')
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Remove = @($removal) } } } $TestDrive).Count | Should -Be 0
    }
    It 'accepts TimeoutMinutes from 1 to 1440 for removals and installers' {
        foreach ($minutes in @(1, 1440)) {
            @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Remove = @(@{ DisplayName = 'A'; TimeoutMinutes = $minutes }) } } } $TestDrive).Count | Should -Be 0
        }
        foreach ($minutes in @(0, 1441)) {
            @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Remove = @(@{ DisplayName = 'A'; TimeoutMinutes = $minutes }) } } } $TestDrive) -join ';' |
                Should -Match 'Remove\[0\]\.TimeoutMinutes: expected a number from 1 to 1440'
        }
        @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ Software = @{ Install = @(@{ ExecutablePath = 'C:\Windows\notepad.exe'; TimeoutMinutes = 0 }) } } } $TestDrive) -join ';' |
            Should -Match 'Install\[0\]\.TimeoutMinutes: expected a number from 1 to 1440'
    }
    It 'finds a network card by exactly one of FindBy.Description and FindBy.Name' {
        $test = { param($card) @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ NetworkCards = @($card) } } $TestDrive) -join ';' }
        & $test @{ FindBy = @{}; Change = @{ NewName = 'LAN' } } | Should -Match 'NetworkCards\[0\]\.FindBy: needs Description or Name'
        & $test @{ FindBy = @{ Description = 'Intel'; Name = 'Ethernet' }; Change = @{} } |
            Should -Match 'NetworkCards\[0\]\.FindBy: use either Description or Name, not both'
        & $test @{ FindBy = @{ Name = 'Ethernet' }; Change = @{ Description = 'New' } } | Should -Match 'Change\.Description: unknown property'
        & $test @{ Change = @{ NewName = 'LAN' } } | Should -Match 'NetworkCards\[0\]\.FindBy: required property is missing'
        & $test @{ FindBy = @{ Name = 'Ethernet' }; Change = @{ NewName = 'LAN'; DnsSuffix = '' } } | Should -BeNullOrEmpty
    }
    It 'checks IP settings, accepting placeholders before the restore asks for them' {
        $test = { param($settings) @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ NetworkCards = @(@{ FindBy = @{ Name = 'Ethernet' }; Change = @{ IPSettings = $settings } }) } } $TestDrive) -join ';' }
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = 24; DefaultGateway = '10.20.67.254'; DNSServers = @('10.75.38.23') } | Should -BeNullOrEmpty
        & $test @{ IPAddress = '{{ipv4:Address}}'; PrefixLength = '{{prefix:Prefix}}'; DefaultGateway = '{{ipv4:Gateway}}'; DNSServers = @('{{ipv4:DNS}}') } | Should -BeNullOrEmpty
        & $test @{ Dhcp = $true; DNSServers = @() } | Should -BeNullOrEmpty
        & $test @{ IPAddress = '10.20.67.2' } | Should -Match 'IPSettings.PrefixLength: required for a static address'
        & $test @{ Dhcp = $true; IPAddress = '10.20.67.2' } | Should -Match 'IPSettings.IPAddress: not used with Dhcp true'
        & $test @{ IPAddress = '10.20.67.300'; PrefixLength = 24 } | Should -Match "IPSettings.IPAddress: '10.20.67.300' is not an IPv4 address"
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = 24; DefaultGateway = '10.20.68.1' } |
            Should -Match "IPSettings.DefaultGateway: '10.20.68.1' is not in the subnet of 10.20.67.2/24"
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = 40 } | Should -Match 'IPSettings.PrefixLength: expected a number from 1 to 32'
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = '24' } | Should -Match 'IPSettings.PrefixLength: expected a number from 1 to 32, or \{\{prefix:Description\}\}'
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = 24; DNSServers = @('dns.contoso.com') } | Should -Match "IPSettings.DNSServers\[0\]: 'dns.contoso.com' is not an IPv4 address"
    }
    It 'checks hosts file entries: addresses, host names, Remove and one address per name' {
        $test = { param([object[]]$entries) @(Test-ConfigurationHC @{ SchemaVersion = 3; Items = @{ HostsFileEntries = $entries } } $TestDrive) -join ';' }
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @('a', 'a.grouphc.net') }, @{ IPAddress = 'fd00::47'; Hostnames = @('b') }) | Should -BeNullOrEmpty
        & $test @(@{ IPAddress = '{{ipv4:Address}}'; Hostnames = @('c') }, @{ Action = 'Remove'; Hostnames = @('old') }) | Should -BeNullOrEmpty
        & $test @(@{ IPAddress = '10.20.60'; Hostnames = @('a') }) | Should -Match "HostsFileEntries\[0\]\.IPAddress: '10.20.60' is not an IPv4 or IPv6 address"
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @('bad name') }) | Should -Match "Hostnames\[0\]: 'bad name' is not a valid host name"
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @() }) | Should -Match 'Hostnames: expected at least one host name'
        & $test @(@{ Action = 'Remove'; IPAddress = '10.20.60.47'; Hostnames = @('a') }) | Should -Match 'IPAddress: not used with Action Remove'
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @('a') }, @{ IPAddress = '10.20.60.48'; Hostnames = @('A') }) |
            Should -Match "HostsFileEntries\[1\]\.Hostnames\[0\]: 'A' is already used for 10.20.60.47"
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @('a') }, @{ Action = 'Remove'; Hostnames = @('a') }) |
            Should -Match "'a' is already used for 10.20.60.47"
        & $test @(@{ Action = 'Add'; IPAddress = '10.20.60.47'; Hostnames = @('a') }) | Should -Match "Action: invalid value 'Add'"
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