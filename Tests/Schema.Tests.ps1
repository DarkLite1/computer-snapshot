#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
    . "$PSScriptRoot\Common\Restore input.ps1"

    $schemaPath = Join-Path $PSScriptRoot '..\Scripts\config.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $root = Split-Path $PSScriptRoot -Parent

    $configFolder = Join-Path $root 'Configurations'
    $shippedConfigurations = @(
        Get-ChildItem -LiteralPath $configFolder -Filter '*.json' -File |
        ForEach-Object FullName
    )
    $sharedFolder = Join-Path $root 'Shared'
    $shippedSharedSections = @(
        Get-ChildItem -LiteralPath $sharedFolder -Filter '*.json' -File |
        ForEach-Object FullName
    )

    $mapping = @{
        'Folders'                    = 'CreateFolders'
        'Copy files folders'         = 'CopyFilesFolders'
        'NTP time servers'           = 'NtpTimeServers'
        'Hosts file entries'         = 'HostsFileEntries'
        'Network cards'              = 'NetworkCards'
        'Regional settings'          = 'RegionalSettings'
        'Account policy'             = 'AccountPolicy'
        'Environment variables'      = 'EnvironmentVariables'
        'Software'                   = 'Software'
        'User accounts'              = 'UserAccounts'
        'User groups'                = 'UserGroups'
        'Registry keys'              = 'RegistryKeys'
        'Firewall rules'             = 'FirewallRules'
        'Scheduled tasks'            = 'ScheduledTasks'
        'Smb shares'                 = 'SmbShares'
        'Start custom scripts'       = 'StartCustomScriptsBefore'
        'Start custom scripts after' = 'StartCustomScriptsAfter'
    }
}

Describe 'Schema contract' {
    It ('resolves the prompted setup example into valid data without ' +
        'changing its file or applying settings') {
        $file = Join-Path $root 'Configurations\Example prompted setup.json'
        $before = Get-Content -LiteralPath $file -Raw

        $loaded = Read-ConfigurationHC $file $root

        @(Get-RestoreInputFieldsHC -Data $loaded.Items).Count | Should -Be 3
        $readValues = New-FakeReadValuesHC {
            param($field)
            switch ($field.Kind) {
                'input' { 'Example' }
                'password' { 'Test-only password!42' }
                'ipv4' { '192.0.2.10' }
            }
        }
        $resolveParams = @{
            Items      = $loaded.Items
            ReadValues = $readValues
        }
        $null = Resolve-RestoreInputHC @resolveParams
        @(Test-ConfigurationHC $loaded $root).Count | Should -Be 0
        $loaded.Items.NtpTimeServers.TimeServerNames |
        Should -Be @('192.0.2.10')
        (Get-Content -LiteralPath $file -Raw) | Should -BeExactly $before
    }
    It 'validates every component example with the runtime shape validator' {
        foreach ($name in $mapping.Values) {
            $examplePath = Join-Path $root "Examples\$name.json"
            $data = Read-SectionExampleHC $examplePath
            $document = @{ SchemaVersion = 3; Items = @{ $name = $data } }

            $problems = @(Test-ConfigurationHC $document $TestDrive)

            @(
                $problems | Where-Object { $_ -notmatch "file '.+' not found" }
            ).Count | Should -Be 0 -Because ($problems -join '; ')
        }
    }
    It ('fills the number placeholders of the examples in as numbers that ' +
        'pass the check') {
        $numberFields = 0
        foreach ($name in $mapping.Values | Select-Object -Unique) {
            $examplePath = Join-Path $root "Examples\$name.json"
            $data = Read-SectionExampleHC $examplePath
            $document = @{ SchemaVersion = 3; Items = @{ $name = $data } }
            $fields = @(
                Get-RestoreInputFieldsHC -Data $document.Items |
                Where-Object { $_.Kind -eq 'number' }
            )
            if (-not $fields.Count) {
                continue
            }
            $numberFields += $fields.Count

            $readValues = New-FakeReadValuesHC {
                param($field)
                switch ($field.Kind) {
                    'number' { '30' }
                    'password' { 'Test-only password!42' }
                    'ipv4' { '192.0.2.10' }
                    'prefix' { '24' }
                    default { 'Example' }
                }
            }
            $resolveParams = @{
                Items      = $document.Items
                ReadValues = $readValues
            }
            $null = Resolve-RestoreInputHC @resolveParams
            $problems = @(Test-ConfigurationHC $document $TestDrive)

            foreach ($field in $fields) {
                $value = if (
                    $field.Container -is [System.Collections.IDictionary] -or
                    $field.Container -is [array]
                ) {
                    $field.Container[$field.Key]
                }
                else {
                    $field.Container.($field.Key)
                }
                $value | Should -BeOfType [int] -Because $field.Path
                $value | Should -Be 30
            }
            @(
                $problems | Where-Object { $_ -notmatch "file '.+' not found" }
            ).Count | Should -Be 0 -Because "$name; $($problems -join '; ')"
        }
        $numberFields | Should -BeGreaterOrEqual 4
    }
    It ('validates every component example using Test-Json on ' +
        'PowerShell 7') -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        foreach ($name in $mapping.Values) {
            $examplePath = Join-Path $root "Examples\$name.json"
            $document = @{
                SchemaVersion = 3
                Items         = @{ $name = Read-SectionExampleHC $examplePath }
            }

            $document | ConvertTo-Json -Depth 20 |
            Test-Json -SchemaFile $schemaPath -ErrorAction Stop |
            Should -BeTrue
        }
    }
    It 'rejects misspelled section properties at runtime' {
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Instal = @() } }
        }

        $problems = @(Test-ConfigurationHC $document $TestDrive)

        $problems -join ';' | Should -Match 'Software.Instal: unknown property'
    }
    It 'accepts native user removal alongside existing account settings' {
        $document = @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(
                    @{ Name = 'Existing'; Enabled = $true }
                    @{
                        Name     = 'New'
                        Action   = 'Set'
                        Password = '{{password:New account password}}'
                    }
                    @{
                        Name    = 'bob'
                        Action  = 'Remove'
                        Comment = 'Keep profile files'
                    }
                )
            }
        }

        @(Test-ConfigurationHC $document $TestDrive).Count | Should -Be 0
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $document | ConvertTo-Json -Depth 20 |
            Test-Json -SchemaFile $schemaPath -ErrorAction Stop |
            Should -BeTrue
        }
    }
    It 'rejects account settings on removal entries and unsafe removal names' {
        foreach ($property in @(
                'Password', 'FullName', 'Description', 'Enabled',
                'PasswordExpires', 'AccountExpires', 'UserMayChangePassword'
            )) {
            $entry = @{ Name = 'bob'; Action = 'Remove' }
            $isBoolean = $property -in @('Enabled', 'UserMayChangePassword')
            $entry[$property] = if ($isBoolean) { $false } else { '' }
            $document = @{
                SchemaVersion = 3
                Items         = @{ UserAccounts = @($entry) }
            }

            $problems = @(Test-ConfigurationHC $document $TestDrive)

            $problems -join ';' |
            Should -Match "$property`: not used with Action Remove"
        }
        foreach ($name in @('', ' ', '*', 'b?b', 'DOMAIN\bob')) {
            $document = @{
                SchemaVersion = 3
                Items         = @{
                    UserAccounts = @(@{ Name = $name; Action = 'Remove' })
                }
            }

            $problems = @(Test-ConfigurationHC $document $TestDrive)

            $problems -join ';' |
            Should -Match 'removal requires an exact local account name'
        }
        foreach ($action in @('Delete', 'remove', $null)) {
            $document = @{
                SchemaVersion = 3
                Items         = @{
                    UserAccounts = @(@{ Name = 'bob'; Action = $action })
                }
            }

            @(Test-ConfigurationHC $document $TestDrive).Count |
            Should -BeGreaterThan 0
        }
    }
    It 'names the choice when a task has both or neither of Xml and XmlFile' {
        $task = [ordered]@{ TaskName = 'T'; TaskPath = '\HC\'; Enabled = $true }
        $document = @{
            SchemaVersion = 3
            Items         = @{ ScheduledTasks = @($task) }
        }

        $none = @(Test-ConfigurationHC $document $TestDrive)

        $none -join ';' |
        Should -Match 'ScheduledTasks\[0\]: needs Xml or XmlFile'

        $both = @{
            TaskName = 'T'
            TaskPath = '\HC\'
            Enabled  = $true
            Xml      = '<Task/>'
            XmlFile  = 'Files\Task.xml'
        }
        $document = @{
            SchemaVersion = 3
            Items         = @{ ScheduledTasks = @($both) }
        }

        $problems = @(Test-ConfigurationHC $document $TestDrive)

        $problems -join ';' | Should -Match (
            'ScheduledTasks\[0\]: use either Xml or XmlFile, not both'
        )
    }
    It 'names every choice when there are three or more alternatives' {
        InModuleScope Configuration {
            $choiceSchema = (
                '{"type":"object","oneOf":[{"required":["A"]},' +
                '{"required":["B"]},{"required":["C"]}]}'
            ) | ConvertFrom-Json

            $none = [pscustomobject]@{}
            $two = [pscustomobject]@{
                A = 1
                B = 2
            }
            $one = [pscustomobject]@{ C = 3 }

            Test-ShapeHC $none $choiceSchema $null 'X' |
            Should -BeExactly 'X: needs one of A, B and C'
            Test-ShapeHC $two $choiceSchema $null 'X' |
            Should -BeExactly 'X: use only one of A, B and C'
            Test-ShapeHC $one $choiceSchema $null 'X' |
            Should -BeNullOrEmpty
        }
    }
    It ('requires objects in Software.Remove and only one of ' +
        'UninstallArguments and UninstallCommand') {
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Remove = @('Old App') } }
        }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match 'Software.Remove\[0\]: expected object'

        $removal = @{
            DisplayName        = 'Old App'
            UninstallArguments = '/S'
            UninstallCommand   = 'x.exe'
        }
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Remove = @($removal) } }
        }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match (
            'Software.Remove\[0\]: use either UninstallArguments or ' +
            'UninstallCommand, not both'
        )

        $removal.Remove('UninstallCommand')
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Remove = @($removal) } }
        }
        @(Test-ConfigurationHC $document $TestDrive).Count | Should -Be 0
    }
    It 'accepts TimeoutMinutes from 1 to 1440 for removals and installers' {
        foreach ($minutes in @(1, 1440)) {
            $removal = @{ DisplayName = 'A'; TimeoutMinutes = $minutes }
            $document = @{
                SchemaVersion = 3
                Items         = @{ Software = @{ Remove = @($removal) } }
            }

            @(Test-ConfigurationHC $document $TestDrive).Count | Should -Be 0
        }
        foreach ($minutes in @(0, 1441)) {
            $removal = @{ DisplayName = 'A'; TimeoutMinutes = $minutes }
            $document = @{
                SchemaVersion = 3
                Items         = @{ Software = @{ Remove = @($removal) } }
            }

            @(Test-ConfigurationHC $document $TestDrive) -join ';' |
            Should -Match (
                'Remove\[0\]\.TimeoutMinutes: expected a number from 1 to 1440'
            )
        }
        $installer = @{
            ExecutablePath = 'C:\Windows\notepad.exe'
            TimeoutMinutes = 0
        }
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Install = @($installer) } }
        }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match (
            'Install\[0\]\.TimeoutMinutes: expected a number from 1 to 1440'
        )
    }
    It 'reports TimeoutMinutes <Value> as <Expected>' -ForEach @(
        @{ Value = 0; Expected = 'expected a number from 1 to 1440' }
        @{
            Value    = 'abc'
            Expected = 'expected a whole number or {{number:Description}}'
        }
        @{
            Value    = '15'
            Expected = 'expected a whole number or {{number:Description}}'
        }
        @{
            Value    = '{{input:Minutes}}'
            Expected = 'expected a whole number or {{number:Description}}'
        }
    ) {
        $installer = @{
            ExecutablePath = 'C:\Windows\notepad.exe'
            TimeoutMinutes = $Value
        }
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ Install = @($installer) } }
        }

        $problems = @(Test-ConfigurationHC $document $TestDrive)

        $problems.Count | Should -Be 1 -Because ($problems -join '; ')
        $problems[0] |
        Should -BeLike "*Install[[]0].TimeoutMinutes: $Expected"
    }
    It ('accepts {{number:...}} in the whole-number settings and keeps ' +
        'null for SMB limits') {
        $document = @{
            SchemaVersion = 3
            Items         = @{
                Software                 = @{
                    Remove  = @(
                        @{
                            DisplayName      = 'A'
                            TimeoutMinutes   = '{{number:Remove minutes}}'
                            SuccessExitCodes = @(0, '{{number:Remove code}}')
                        }
                    )
                    Install = @(
                        @{
                            ExecutablePath   = 'C:\Windows\notepad.exe'
                            TimeoutMinutes   = 15
                            SuccessExitCodes = @(0, '{{number:Extra code}}')
                        }
                        @{
                            ExecutablePath = 'C:\Windows\notepad.exe'
                            TimeoutMinutes = '{{number:Minutes}}'
                        }
                    )
                }
                StartCustomScriptsBefore = @(
                    @{
                        Path             = 'C:\Windows\notepad.exe'
                        SuccessExitCodes = @('{{number:Before code}}')
                    }
                )
                StartCustomScriptsAfter  = @(
                    @{
                        Path             = 'C:\Windows\notepad.exe'
                        SuccessExitCodes = @('{{number:After code}}')
                    }
                )
                RegionalSettings         = @{
                    WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'Romance Standard Time'
                    WinHomeLocationGeoId = '{{number:Location}}'
                    CultureName          = 'en-US'
                }
                SmbShares                = @(
                    @{
                        Name                = 'Data'
                        Path                = 'C:\Data'
                        CATimeout           = '{{number:Timeout}}'
                        ThrottleLimit       = $null
                        ConcurrentUserLimit = 10
                    }
                )
            }
        }

        $problems = @(Test-ConfigurationHC $document $TestDrive)

        $problems.Count | Should -Be 0 -Because ($problems -join '; ')
    }
    It 'rejects text that is not a number placeholder in <Setting>' -ForEach @(
        @{
            Setting = 'WinHomeLocationGeoId'
            Items   = @{
                RegionalSettings = @{
                    WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'Romance Standard Time'
                    WinHomeLocationGeoId = '21'
                    CultureName          = 'en-US'
                }
            }
        }
        @{
            Setting = 'CATimeout'
            Items   = @{
                SmbShares = @(
                    @{ Name = 'Data'; Path = 'C:\Data'; CATimeout = 'abc' }
                )
            }
        }
        @{
            Setting = 'SuccessExitCodes'
            Items   = @{
                StartCustomScriptsAfter = @(
                    @{
                        Path             = 'C:\Windows\notepad.exe'
                        SuccessExitCodes = @(0, '{{prefix:Code}}')
                    }
                )
            }
        }
    ) {
        $document = @{ SchemaVersion = 3; Items = $Items }

        $problems = @(Test-ConfigurationHC $document $TestDrive)

        $problems -join ';' | Should -BeLike (
            "*${Setting}*: expected a whole number or " +
            '{{number:Description}}*'
        )
    }
    It ('reports a string that does not match a pattern with the ' +
        'description, or a generic message without one') {
        InModuleScope Configuration {
            $described = (
                '{"type":"string","pattern":"^a+$",' +
                '"description":"only the letter a"}'
            ) | ConvertFrom-Json
            $plain = '{"type":"string","pattern":"^a+$"}' | ConvertFrom-Json

            Test-ShapeHC 'aaa' $described $null 'X' | Should -BeNullOrEmpty
            Test-ShapeHC 'abc' $described $null 'X' |
            Should -BeExactly 'X: expected only the letter a'
            Test-ShapeHC 'AAA' $described $null 'X' |
            Should -BeExactly 'X: expected only the letter a'
            Test-ShapeHC 'abc' $plain $null 'X' |
            Should -BeExactly "X: 'abc' does not match '^a+$'"
        }
    }
    It 'ignores a pattern for a value that is not a string' {
        InModuleScope Configuration {
            $schema = (
                '{"type":["string","integer","null"],"pattern":"^a+$",' +
                '"description":"only the letter a"}'
            ) | ConvertFrom-Json

            Test-ShapeHC 5 $schema $null 'X' | Should -BeNullOrEmpty
            Test-ShapeHC $null $schema $null 'X' | Should -BeNullOrEmpty
        }
    }
    It 'reports a PrefixLength that is not a prefix placeholder unchanged' {
        $test = {
            param($prefix)
            $card = @{
                FindBy = @{ Name = 'Ethernet' }
                Change = @{
                    IPSettings = @{
                        IPAddress    = '10.20.67.2'
                        PrefixLength = $prefix
                    }
                }
            }
            $document = @{
                SchemaVersion = 3
                Items         = @{ NetworkCards = @($card) }
            }
            @(Test-ConfigurationHC $document $TestDrive)
        }

        $problems = @(& $test 'abc')
        $problems.Count | Should -Be 1 -Because ($problems -join '; ')
        $problems[0] | Should -BeLike (
            '*IPSettings.PrefixLength: expected a number from 1 to 32, or ' +
            '{{prefix:Description}}'
        )
        @(& $test '{{prefix:P}}').Count | Should -Be 0
        @(& $test '{{number:P}}').Count | Should -Be 1
    }
    It ('finds a network card by exactly one of FindBy.Description, ' +
        'FindBy.Name and FindBy.OnlyCard') {
        $test = {
            param($card)
            $document = @{
                SchemaVersion = 3
                Items         = @{ NetworkCards = @($card) }
            }
            @(Test-ConfigurationHC $document $TestDrive) -join ';'
        }

        & $test @{ FindBy = @{}; Change = @{ NewName = 'LAN' } } |
            Should -Match (
                'NetworkCards\[0\]\.FindBy: needs one of Description, Name ' +
                'and OnlyCard'
            )
        & $test @{
            FindBy = @{ Description = 'Intel'; Name = 'Ethernet' }
            Change = @{}
        } | Should -Match (
            'NetworkCards\[0\]\.FindBy: use only one of Description, Name ' +
            'and OnlyCard'
        )
        & $test @{
            FindBy = @{ OnlyCard = $true }
            Change = @{ NewName = 'LAN' }
        } | Should -BeNullOrEmpty
        & $test @{
            FindBy = @{ OnlyCard = $false }
            Change = @{ NewName = 'LAN' }
        } | Should -Match 'FindBy\.OnlyCard: expected True'
        foreach ($kind in @('WiFi', 'Wired')) {
            & $test @{
                FindBy = @{ OnlyCard = $kind }
                Change = @{ NewName = 'LAN' }
            } | Should -BeNullOrEmpty -Because $kind
        }
        & $test @{
            FindBy = @{ OnlyCard = 'Cable' }
            Change = @{ NewName = 'LAN' }
        } | Should -Match "FindBy\.OnlyCard: invalid value 'Cable'"
        & $test @{
            FindBy = @{ OnlyCard = $true; Name = 'Ethernet' }
            Change = @{}
        } | Should -Match 'use only one of Description, Name and OnlyCard'
        & $test @{
            FindBy = @{ Name = 'Ethernet' }
            Change = @{ Description = 'New' }
        } | Should -Match 'Change\.Description: unknown property'
        & $test @{ Change = @{ NewName = 'LAN' } } |
        Should -Match 'NetworkCards\[0\]\.FindBy: required property is missing'
        & $test @{
            FindBy = @{ Name = 'Ethernet' }
            Change = @{ NewName = 'LAN'; DnsSuffix = '' }
        } | Should -BeNullOrEmpty
    }
    It ('checks IP settings, accepting placeholders before the restore ' +
        'asks for them') {
        $test = {
            param($settings)
            $card = @{
                FindBy = @{ Name = 'Ethernet' }
                Change = @{ IPSettings = $settings }
            }
            $document = @{
                SchemaVersion = 3
                Items         = @{ NetworkCards = @($card) }
            }
            @(Test-ConfigurationHC $document $TestDrive) -join ';'
        }

        & $test @{
            IPAddress      = '10.20.67.2'
            PrefixLength   = 24
            DefaultGateway = '10.20.67.254'
            DNSServers     = @('10.75.38.23')
        } | Should -BeNullOrEmpty
        & $test @{
            IPAddress      = '{{ipv4:Address}}'
            PrefixLength   = '{{prefix:Prefix}}'
            DefaultGateway = '{{ipv4:Gateway}}'
            DNSServers     = @('{{ipv4:DNS}}')
        } | Should -BeNullOrEmpty
        & $test @{ Dhcp = $true; DNSServers = @() } | Should -BeNullOrEmpty
        & $test @{ IPAddress = '10.20.67.2' } |
        Should -Match 'IPSettings.PrefixLength: required for a static address'
        & $test @{ Dhcp = $true; IPAddress = '10.20.67.2' } |
        Should -Match 'IPSettings.IPAddress: not used with Dhcp true'
        & $test @{ IPAddress = '10.20.67.300'; PrefixLength = 24 } |
        Should -Match (
            "IPSettings.IPAddress: '10.20.67.300' is not an IPv4 address"
        )
        & $test @{
            IPAddress      = '10.20.67.2'
            PrefixLength   = 24
            DefaultGateway = '10.20.68.1'
        } | Should -Match (
            "IPSettings.DefaultGateway: '10.20.68.1' is not in the subnet " +
            'of 10.20.67.2/24'
        )
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = 40 } |
        Should -Match 'IPSettings.PrefixLength: expected a number from 1 to 32'
        & $test @{ IPAddress = '10.20.67.2'; PrefixLength = '24' } |
        Should -Match (
            'IPSettings.PrefixLength: expected a number from 1 to 32, or ' +
            '\{\{prefix:Description\}\}'
        )
        & $test @{
            IPAddress    = '10.20.67.2'
            PrefixLength = 24
            DNSServers   = @('dns.contoso.com')
        } | Should -Match (
            "IPSettings.DNSServers\[0\]: 'dns.contoso.com' is not an IPv4 " +
            'address'
        )
    }
    It ('checks hosts file entries: addresses, host names, Remove and one ' +
        'address per name') {
        $test = {
            param([object[]]$entries)
            $document = @{
                SchemaVersion = 3
                Items         = @{ HostsFileEntries = $entries }
            }
            @(Test-ConfigurationHC $document $TestDrive) -join ';'
        }

        & $test @(
            @{ IPAddress = '10.20.60.47'; Hostnames = @('a', 'a.grouphc.net') }
            @{ IPAddress = 'fd00::47'; Hostnames = @('b') }
        ) | Should -BeNullOrEmpty
        & $test @(
            @{ IPAddress = '{{ipv4:Address}}'; Hostnames = @('c') }
            @{ Action = 'Remove'; Hostnames = @('old') }
        ) | Should -BeNullOrEmpty
        & $test @(@{ IPAddress = '10.20.60'; Hostnames = @('a') }) |
        Should -Match (
            "HostsFileEntries\[0\]\.IPAddress: '10.20.60' is not an IPv4 " +
            'or IPv6 address'
        )
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @('bad name') }) |
        Should -Match "Hostnames\[0\]: 'bad name' is not a valid host name"
        & $test @(@{ IPAddress = '10.20.60.47'; Hostnames = @() }) |
        Should -Match 'Hostnames: expected at least one host name'
        & $test @(
            @{
                Action    = 'Remove'
                IPAddress = '10.20.60.47'
                Hostnames = @('a')
            }
        ) | Should -Match 'IPAddress: not used with Action Remove'
        & $test @(
            @{ IPAddress = '10.20.60.47'; Hostnames = @('a') }
            @{ IPAddress = '10.20.60.48'; Hostnames = @('A') }
        ) | Should -Match (
            "HostsFileEntries\[1\]\.Hostnames\[0\]: 'A' is already used " +
            'for 10.20.60.47'
        )
        & $test @(
            @{ IPAddress = '10.20.60.47'; Hostnames = @('a') }
            @{ Action = 'Remove'; Hostnames = @('a') }
        ) | Should -Match "'a' is already used for 10.20.60.47"
        & $test @(
            @{ Action = 'Add'; IPAddress = '10.20.60.47'; Hostnames = @('a') }
        ) | Should -Match "Action: invalid value 'Add'"
    }
    It 'rejects empty array entries but permits empty sections' {
        $document = @{ SchemaVersion = 3; Items = @{ UserAccounts = @(@{}) } }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match 'Name: required'

        $document = @{
            SchemaVersion = 3
            Items         = @{ CreateFolders = @{}; ScheduledTasks = @() }
        }
        @(Test-ConfigurationHC $document $TestDrive).Count | Should -Be 0
    }
    It 'requires schema property casing and string comments' {
        $document = @{
            SchemaVersion = 3
            Items         = @{ Software = @{ install = @() } }
        }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match 'install: unknown'

        $document = @{ SchemaVersion = 3; Items = @{ software = @{} } }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match 'software: unknown'

        $document = @{
            SchemaVersion = 3
            Items         = @{ Comment = 5; Software = @{} }
        }
        @(Test-ConfigurationHC $document $TestDrive) -join ';' |
        Should -Match 'Comment: expected a string'
    }
    It ('combines the shared files of the combined sections example in ' +
        'order, only below safe example locations') {
        $file = Join-Path $root 'Configurations\Example combined sections.json'

        $loaded = Read-ConfigurationHC $file $root

        $loaded.Problems.Count | Should -Be 0 -Because (
            $loaded.Problems -join '; '
        )
        @($loaded.Items.Keys) | Should -Be @('CreateFolders', 'RegistryKeys')
        @($loaded.Items.CreateFolders.FolderPaths) | Should -Be @(
            '%ProgramData%\ComputerSnapshot example\Logs'
            '%ProgramData%\ComputerSnapshot example\Scripts'
            '%ProgramData%\ComputerSnapshot example\Kiosk\Media'
        )
        $entries = @($loaded.Items.RegistryKeys.RunAsCurrentUser.RegistryKeys)
        @($entries.Name) | Should -Be @(
            'Role', 'SupportDesk', 'StartPage', 'IdleLogoffMinutes'
        )
        foreach ($entry in $entries) {
            $entry.Path |
            Should -BeLike 'HKCU:\Software\ComputerSnapshot\Example*'
        }
        $loaded.Settings.RebootComputer | Should -BeFalse
    }
    It 'validates every shipped configuration and its shared references' {
        $shippedConfigurations.Count | Should -BeGreaterOrEqual 3
        $shippedSharedSections.Count | Should -BeGreaterOrEqual 5

        $files = Get-Item -LiteralPath $shippedConfigurations -ErrorAction Stop
        foreach ($file in $files) {
            $loaded = Read-ConfigurationHC $file.FullName $root
            $problems = @(Test-ConfigurationHC $loaded $root)
            $problems.Count | Should -Be 0 -Because ($problems -join '; ')
        }
    }
    It ('checks shipped configurations and Shared sections with ' +
        'Test-Json') -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $files = Get-Item -LiteralPath $shippedConfigurations -ErrorAction Stop
        foreach ($file in $files) {
            Get-Content -LiteralPath $file.FullName -Raw |
            Test-Json -SchemaFile $schemaPath -ErrorAction Stop |
            Should -BeTrue
        }

        $testJsonParams = @{
            SchemaFile  = $schemaPath
            ErrorAction = 'SilentlyContinue'
        }
        $files = Get-Item -LiteralPath $shippedSharedSections -ErrorAction Stop
        foreach ($file in $files) {
            $data = Read-SectionExampleHC $file.FullName
            $sectionNames = $schema.'$defs'.PSObject.Properties.Name
            $matchingSections = @($sectionNames | Where-Object {
                    $document = @{ SchemaVersion = 3; Items = @{ $_ = $data } }
                    $document | ConvertTo-Json -Depth 20 |
                    Test-Json @testJsonParams
                })
            $matchingSections.Count | Should -BeGreaterThan 0 -Because (
                "Shared file '$($file.Name)' must match a section shape"
            )
        }
    }
    It 'gives descriptions to every declared property' {
        function Test-DescriptionsHC($node) {
            if (
                $node -is [pscustomobject] -and
                $node.properties -is [pscustomobject]
            ) {
                foreach ($property in $node.properties.PSObject.Properties) {
                    $property.Value.description |
                    Should -Not -BeNullOrEmpty -Because $property.Name
                }
            }
            if ($node -is [pscustomobject]) {
                foreach ($property in $node.PSObject.Properties) {
                    Test-DescriptionsHC $property.Value
                }
            }
            elseif ($node -is [array]) {
                foreach ($item in $node) { Test-DescriptionsHC $item }
            }
        }

        Test-DescriptionsHC $schema
    }
}
