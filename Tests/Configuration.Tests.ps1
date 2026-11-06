#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
    . "$PSScriptRoot\Common\Restore input.ps1"
}

Describe 'Restore input placeholders' {
    It ('resolves nested string values once and preserves other value ' +
        'types and arrays') {
        $items = (
            '{"UserAccounts":[{"Name":"{{input:Account name}}",' +
            '"Password":"{{password:Account password}}","Enabled":false}],' +
            '"UserGroups":[],' +
            '"NetworkCards":[{"Address":"{{ipv4:IPv4 address}}"}],' +
            '"CreateFolders":{"FolderPaths":["{{input:Account name}}"],' +
            '"Comment":"{{input:Ignored}}"},"Number":24,"Nothing":null}'
        ) | ConvertFrom-Json
        $script:requests = @()
        $readValues = New-FakeReadValuesHC {
            param($field)
            $script:requests += $field.Path
            switch ($field.Kind) {
                'input' { 'Example' }
                'password' { 'Test-only password!"\$' }
                'ipv4' { '192.0.2.10' }
            }
        }
        $result = Resolve-RestoreInputHC -Items $items -ReadValues $readValues

        $requests.Count | Should -Be 3
        $items.UserAccounts[0].Name | Should -Be 'Example'
        $items.CreateFolders.FolderPaths[0] | Should -Be 'Example'
        $items.UserAccounts[0].Password |
            Should -BeExactly 'Test-only password!"\$'
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
        $items = @{
            UserAccounts = @(
                @{ Name = '{{input:Name}}'; Password = '{{password:Password}}' }
            )
        }
        {
            $readValues = New-FakeReadValuesHC {
                param($field)
                if ($field.Kind -eq 'input') { 'Example' }
            }
            Resolve-RestoreInputHC -Items $items -ReadValues $readValues
        } | Should -Throw '*cancelled*'
        $items.UserAccounts[0].Name | Should -Be '{{input:Name}}'
        $items.UserAccounts[0].Password | Should -Be '{{password:Password}}'
    }
    It 'rejects malformed or embedded placeholders before requesting values' {
        $placeholders = @(
            '{{input: }}', '{{unknown:Name}}', 'prefix {{input:Name}}'
        )
        foreach ($placeholder in $placeholders) {
            {
                Get-RestoreInputFieldsHC -Data @{
                    UserAccounts = @(@{ Name = $placeholder })
                }
            } | Should -Throw '*complete*'
        }
    }
    It ('validates required values and canonical IPv4 addresses without ' +
        'exposing the value') {
        foreach ($value in @('', ' ', '999.1.1.1', '127.1', '::1')) {
            Test-RestoreInputValueHC -Kind ipv4 -Value $value | Should -BeFalse
        }
        Test-RestoreInputValueHC -Kind ipv4 -Value '192.0.2.10' | Should -BeTrue

        $items = @{ NetworkCards = @(@{ Address = '{{ipv4:Address}}' }) }
        {
            $readValues = New-FakeReadValuesHC {
                'invalid-address'
            }
            Resolve-RestoreInputHC -Items $items -ReadValues $readValues
        } | Should -Throw '*supplied input is empty or invalid*'

        $protectParams = @{
            Text         = 'Failed: test-secret'
            SecretValues = @('test-secret')
        }
        Protect-RestoreInputTextHC @protectParams |
            Should -Be 'Failed: [redacted]'
    }
    It 'asks for a prefix length from 1 to 32 and stores it as a number' {
        foreach ($value in @('', '0', '33', '024', '24.0', ' 24', 'abc')) {
            Test-RestoreInputValueHC -Kind prefix -Value $value |
                Should -BeFalse -Because "'$value'"
        }
        foreach ($value in @('1', '24', '32')) {
            Test-RestoreInputValueHC -Kind prefix -Value $value | Should -BeTrue
        }

        $items = (
            '{"NetworkCards":[{"InterfaceAlias":"Ethernet",' +
            '"IPSettings":{"IPAddress":"{{ipv4:Address}}",' +
            '"PrefixLength":"{{prefix:Prefix length}}"}}]}'
        ) | ConvertFrom-Json
        $readValues = New-FakeReadValuesHC {
            param($field)
            if ($field.Kind -eq 'prefix') { '24' } else { '10.20.67.2' }
        }
        $null = Resolve-RestoreInputHC -Items $items -ReadValues $readValues
        $items.NetworkCards[0].IPSettings.PrefixLength | Should -BeOfType [int]
        $items.NetworkCards[0].IPSettings.PrefixLength | Should -Be 24

        {
            $badItems = @{ A = @{ P = '{{prefix:P}}' } }
            $readValues = New-FakeReadValuesHC { '40' }
            Resolve-RestoreInputHC -Items $badItems -ReadValues $readValues
        } | Should -Throw '*supplied input is empty or invalid*'
    }
    It 'accepts the whole number <Value>' -ForEach @(
        @{ Value = '15' }
        @{ Value = '0' }
        @{ Value = '-1' }
        @{ Value = '9223372036854775807' }
    ) {
        Test-RestoreInputValueHC -Kind number -Value $Value | Should -BeTrue
    }
    It 'rejects <Value> as a whole number' -ForEach @(
        @{ Value = '' }
        @{ Value = '015' }
        @{ Value = '1.5' }
        @{ Value = '1e3' }
        @{ Value = ' 15' }
        @{ Value = '15 ' }
        @{ Value = 'abc' }
        @{ Value = '+15' }
        @{ Value = '9223372036854775808' }
    ) {
        Test-RestoreInputValueHC -Kind number -Value $Value | Should -BeFalse
    }
    It 'stores a whole number as an int, or as a long when it is large' {
        $items = (
            '{"Software":{"Install":[{"ExecutablePath":"Setup.exe",' +
            '"TimeoutMinutes":"{{number:Minutes}}",' +
            '"SuccessExitCodes":[0,"{{number:Extra code}}"]}]},' +
            '"Other":{"Big":"{{number:Big}}","Text":"{{input:Text}}"}}'
        ) | ConvertFrom-Json
        $fakeAnswers = @{
            '{{number:Minutes}}'    = '15'
            '{{number:Extra code}}' = '-1'
            '{{number:Big}}'        = '3000000000'
            '{{input:Text}}'        = '15'
        }

        $readValues = New-FakeReadValuesHC {
            param($field)
            $fakeAnswers[$field.Placeholder]
        }
        $null = Resolve-RestoreInputHC -Items $items -ReadValues $readValues

        $install = $items.Software.Install[0]
        $install.TimeoutMinutes | Should -BeOfType [int]
        $install.TimeoutMinutes | Should -Be 15
        $install.SuccessExitCodes[1] | Should -BeOfType [int]
        $install.SuccessExitCodes[1] | Should -Be -1
        $items.Other.Big | Should -BeOfType [long]
        $items.Other.Big | Should -Be 3000000000
        $items.Other.Text | Should -BeOfType [string]
        $items.Other.Text | Should -BeExactly '15'
    }
    It 'refuses an invalid whole number from the prompt' {
        $items = @{ A = @{ P = '{{number:P}}' } }

        {
            $readValues = New-FakeReadValuesHC { '1.5' }
            Resolve-RestoreInputHC -Items $items -ReadValues $readValues
        } | Should -Throw '*supplied input is empty or invalid*'
        $items.A.P | Should -Be '{{number:P}}'
    }
    It 'finds a number placeholder in a file and in configuration data' {
        $fields = @(
            Get-TextInputFieldsHC -Text 'wait={{number:Seconds}}' -Path 'F'
        )
        $fields.Count | Should -Be 1
        $fields[0].Kind | Should -Be 'number'

        {
            Get-TextInputFieldsHC -Text 'wait={{number:Seconds' -Path 'F'
        } | Should -Throw '*{{number:Description}}*'
        {
            Get-RestoreInputFieldsHC -Data @{ A = 'x {{number:Seconds}}' }
        } | Should -Throw '*{{number:Description}}*'
    }
    It ('asks for placeholders inside files that are filled in while ' +
        'copying, once per placeholder') {
        $null = New-Item -Path "$TestDrive\Files" -ItemType Directory -Force
        ('http://{{ipv4:Server}}:1353/?ref={{input:Reference}}' +
            "`r`nagain {{ipv4:Server}}") |
            Set-Content -LiteralPath "$TestDrive\Files\Start.ps1"
        $items = @{
            CopyFilesFolders = @(
                @{
                    From             = 'Files\Start.ps1'
                    To               = 'C:\HC\Start.ps1'
                    FillPlaceholders = $true
                }
            )
            HostsFileEntries = @(
                @{ IPAddress = '{{ipv4:Server}}'; Hostnames = @('server') }
            )
        }
        $script:asked = @()
        $resolveParams = @{
            Items      = $items
            RootFolder = $TestDrive
            ReadValues = (New-FakeReadValuesHC {
                param($field)
                $script:asked += $field.Placeholder
                if ($field.Kind -eq 'ipv4') { '10.20.60.47' } else { 'TRM_01' }
            })
        }
        $result = Resolve-RestoreInputHC @resolveParams

        $asked | Should -Be @('{{ipv4:Server}}', '{{input:Reference}}')
        $result.Values['{{input:Reference}}'] | Should -Be 'TRM_01'
        $items.HostsFileEntries[0].IPAddress | Should -Be '10.20.60.47'
        $items.CopyFilesFolders[0].From | Should -Be 'Files\Start.ps1'
    }
    It 'refuses a password placeholder or an incomplete placeholder in a file' {
        {
            Get-TextInputFieldsHC -Text 'pw={{password:Secret}}' -Path 'File'
        } | Should -Throw '*not allowed in a file*plain text*'
        {
            Get-TextInputFieldsHC -Text 'ip={{ipv4:Server' -Path 'File'
        } | Should -Throw '*complete*'
        @(Get-TextInputFieldsHC -Text 'no placeholders' -Path 'File').Count |
            Should -Be 0
    }
    It 'redacts the encoded forms in which a secret is commonly repeated' {
        $secret = "P&ss<w0rd>'x"
        $forms = @(
            [System.Security.SecurityElement]::Escape($secret)
            [System.Net.WebUtility]::HtmlEncode($secret)
            [System.Uri]::EscapeDataString($secret)
            (ConvertTo-Json -InputObject $secret -Compress).Trim('"')
            $secret.Replace("'", "''")
        )
        foreach ($form in $forms) {
            $protectParams = @{
                Text         = "before $form after"
                SecretValues = @($secret)
            }
            Protect-RestoreInputTextHC @protectParams |
                Should -Be 'before [redacted] after' -Because $form
        }

        $protectParams = @{
            Text         = 'R&D <ok>'
            SecretValues = @($secret, '', $null)
        }
        Protect-RestoreInputTextHC @protectParams | Should -Be 'R&D <ok>'
    }
}

Describe 'Restore input questions and their rules' {
    BeforeAll {
        $schema = Get-Content -Raw -LiteralPath (
            "$PSScriptRoot\..\Scripts\config.schema.json"
        ) | ConvertFrom-Json
    }
    It 'finds the range of <Path>' -ForEach @(
        @{
            Path    = 'Items.Software.Install[0].TimeoutMinutes'
            Minimum = 1
            Maximum = 1440
        }
        @{
            Path    = 'Items.Software.Remove[2].TimeoutMinutes'
            Minimum = 1
            Maximum = 1440
        }
        @{
            Path    = 'Items.NetworkCards[0].Change.IPSettings.PrefixLength'
            Minimum = 1
            Maximum = 32
        }
    ) {
        $rule = Get-RestoreInputRuleHC -Path $Path -Schema $schema

        $rule.Minimum | Should -Be $Minimum
        $rule.Maximum | Should -Be $Maximum
        $rule.Values | Should -BeNullOrEmpty
    }
    It 'finds the fixed values of a setting once in each spelling' {
        $path = (
            'Items.RegistryKeys.RunAsOtherUser[1].RegistryKeys[0].Type'
        )

        $rule = Get-RestoreInputRuleHC -Path $path -Schema $schema

        $rule.Values | Should -Contain 'DWord'
        $rule.Values -ccontains 'DWORD' | Should -BeFalse
        $rule.Values.Count | Should -Be 12
        $rule.Minimum | Should -BeNullOrEmpty
    }
    It 'gives no rule for <Path>' -ForEach @(
        @{ Path = 'Items.UserAccounts[0].Name' }
        @{ Path = 'Items.RegionalSettings.WinHomeLocationGeoId' }
        @{ Path = 'Items.StartCustomScriptsAfter[0].SuccessExitCodes[1]' }
        @{ Path = 'Items.StartCustomScriptsAfter[0].Arguments.Mode' }
        @{ Path = 'Items.RegistryKeys.RunAsCurrentUser.RegistryKeys[0].Value' }
        @{ Path = 'Items.Software.Unknown' }
        @{ Path = "Items.CopyFilesFolders[0].From 'Files\a b.txt'" }
    ) {
        Get-RestoreInputRuleHC -Path $Path -Schema $schema |
            Should -BeNullOrEmpty
    }
    It 'keeps only what is valid everywhere for a placeholder used twice' {
        $first = [pscustomobject]@{
            Minimum = 1
            Maximum = 1440
            Values  = $null
        }
        $second = [pscustomobject]@{
            Minimum = 10
            Maximum = $null
            Values  = $null
        }

        $rule = Merge-RestoreInputRuleHC $first $second

        $rule.Minimum | Should -Be 10
        $rule.Maximum | Should -Be 1440
        Merge-RestoreInputRuleHC $null $second | Should -Be $second
    }
    It ('asks each placeholder once, in the section that runs first, ' +
        'and skips the answered ones') {
        $items = [ordered]@{
            HostsFileEntries = @(
                [ordered]@{
                    IPAddress = '{{ipv4:Server}}'
                    Hostnames = @('{{input:Host}}')
                }
            )
            Software         = [ordered]@{
                Install = @(
                    [ordered]@{
                        ExecutablePath = '{{input:Answered}}'
                        TimeoutMinutes = '{{number:Minutes}}'
                    }
                )
            }
            NtpTimeServers   = [ordered]@{
                TimeServerNames = @('{{ipv4:Server}}')
            }
        }
        $fields = @(Get-RestoreInputFieldsHC -Data $items)
        $questionParams = @{
            Fields  = $fields
            Answers = @{ '{{input:Answered}}' = 'Setup.exe' }
        }

        $questions = @(Get-RestoreInputQuestionHC @questionParams)

        @($questions.Placeholder) | Should -Be @(
            '{{ipv4:Server}}', '{{input:Host}}', '{{number:Minutes}}'
        )
        @($questions.Section) | Should -Be @(
            'Hosts file', 'Hosts file', 'Software'
        )
        @($questions[0].OtherSections) | Should -Be @('Time synchronization')
        $questions[0].Rule | Should -BeNullOrEmpty
        $questions[2].Rule.Maximum | Should -Be 1440
    }
    It 'explains <Value> for a <Kind> answer as <Expected>' -ForEach @(
        @{ Kind = 'input'; Value = ' '; Expected = 'A value is required.' }
        @{
            Kind     = 'ipv4'
            Value    = '10.0.0'
            Expected = 'Enter an IPv4 address, such as 192.0.2.10.'
        }
        @{
            Kind     = 'prefix'
            Value    = '33'
            Expected = 'Enter a prefix length from 1 to 32, such as 24.'
        }
        @{
            Kind     = 'number'
            Value    = 'abc'
            Expected = 'Enter a whole number, such as 15.'
        }
        @{
            Kind     = 'number'
            Value    = '0'
            Minimum  = 1
            Maximum  = 1440
            Expected = 'Enter a whole number from 1 to 1440.'
        }
        @{
            Kind     = 'number'
            Value    = '5'
            Minimum  = 10
            Expected = 'Enter a whole number of at least 10.'
        }
        @{
            Kind     = 'input'
            Value    = 'Double'
            Values   = @('String', 'DWord')
            Expected = 'Choose a value from the list.'
        }
    ) {
        $rule = [pscustomobject]@{
            Minimum = $Minimum
            Maximum = $Maximum
            Values  = $Values
        }

        Get-RestoreInputProblemHC -Kind $Kind -Value $Value -Rule $rule |
            Should -BeExactly $Expected
    }
    It 'accepts <Value> for a <Kind> answer' -ForEach @(
        @{ Kind = 'input'; Value = 'kiosk' }
        @{ Kind = 'number'; Value = '1440'; Minimum = 1; Maximum = 1440 }
        @{ Kind = 'input'; Value = 'dword'; Values = @('String', 'DWord') }
    ) {
        $rule = [pscustomobject]@{
            Minimum = $Minimum
            Maximum = $Maximum
            Values  = $Values
        }

        Get-RestoreInputProblemHC -Kind $Kind -Value $Value -Rule $rule |
            Should -BeNullOrEmpty
    }
}

Describe 'Version 2 configuration' {
    BeforeEach {
        $path = Join-Path $TestDrive 'configuration.json'
        $configuration = [ordered]@{
            SchemaVersion = 3
            Items         = [ordered]@{ Software = @{}; UserAccounts = @() }
        }
    }
    It 'loads inline sections with defaults in fixed order' {
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        @($loaded.Items.Keys) | Should -Be @('UserAccounts', 'Software')
        $loaded.Settings.RebootComputer | Should -BeFalse
        $loaded.Settings.RestartDelaySeconds | Should -Be 60
        @(Test-ConfigurationHC $loaded $TestDrive).Count | Should -Be 0
    }
    It 'reads the restart delay and rejects values outside 0 to 600' {
        $configuration.Settings = @{ RestartDelaySeconds = 0 }
        Write-ConfigurationHC $configuration $path
        (Read-ConfigurationHC $path $TestDrive).Settings.RestartDelaySeconds |
            Should -Be 0

        foreach ($delay in @(-1, 601, '60', 1.5, $true)) {
            $configuration.Settings = @{ RestartDelaySeconds = $delay }
            Write-ConfigurationHC $configuration $path
            (Read-ConfigurationHC $path $TestDrive).Problems -join ';' |
                Should -Match ('Settings.RestartDelaySeconds: expected a ' +
                    'whole number from 0 to 600') -Because "$delay"
        }
    }
    It 'preserves empty and singleton arrays without a UTF8 BOM' {
        $configuration.Items.UserAccounts = @(
            [pscustomobject]@{ Name = 'Example' }
        )
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        $loaded.Items.UserAccounts.GetType().IsArray | Should -BeTrue
        $loaded.Items.UserAccounts.Count | Should -Be 1
        [IO.File]::ReadAllBytes($path)[0] | Should -Be 123
    }
    It ('formats with two spaces and puts comments first in every nested ' +
        'object without mutating input') {
        $configuration.Settings = [ordered]@{
            RunElevated = $false
            Comment     = 'Settings note'
        }
        $configuration.Items = [ordered]@{
            UserAccounts = @(
                [pscustomobject][ordered]@{
                    Name    = 'Example'
                    Comment = 'Account note'
                    Enabled = $true
                }
            )
            Comment      = 'Items note'
        }
        Write-ConfigurationHC $configuration $path

        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match '(?m)^  "SchemaVersion": 3,'
        $text |
            Should -Match '"Settings": \{\r?\n    "Comment": "Settings note",'
        $text | Should -Match '"Items": \{\r?\n    "Comment": "Items note",'
        $text | Should -Match ('\{\r?\n        "Comment": "Account note",' +
            '\r?\n        "Name": "Example",')
        @($configuration.Settings.Keys)[0] | Should -Be 'RunElevated'
        $text.EndsWith([Environment]::NewLine) | Should -BeTrue
    }
    It 'keeps short arrays compact and expands arrays that exceed 80 columns' {
        $configuration.Items.Software = [ordered]@{
            Remove  = @('Short', 'Another')
            Install = @()
            Comment = 'Software note'
        }
        Write-ConfigurationHC $configuration $path
        [IO.File]::ReadAllText($path) |
            Should -Match '"Remove": \["Short", "Another"\]'

        $configuration.Items.Software.Remove = @(('A' * 35), ('B' * 35))
        Write-ConfigurationHC $configuration $path
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match '"Remove": \[\r?\n'
        @($text -split '\r?\n' | Where-Object { $_.Length -gt 80 }).Count |
            Should -Be 0
        (Read-ConfigurationHC $path $TestDrive).Items.Software.Remove |
            Should -Be $configuration.Items.Software.Remove
    }
    It 'preserves escaped text, nulls, booleans and numbers while formatting' {
        $xml = '<Task attr="quoted">' + "`r`n" + ('text { [ ] } ' * 12) +
            '</Task>'
        $configuration.Items.ScheduledTasks = @(
            [ordered]@{
                TaskName = 'Example'
                TaskPath = '\HC\'
                Enabled  = $false
                Xml      = $xml
            }
        )
        $configuration.Items.Software = @{
            Install = @(
                @{ ExecutablePath = 'C:\Example.exe'; Arguments = $null }
            )
        }
        Write-ConfigurationHC $configuration $path

        $loaded = Read-ConfigurationHC $path $TestDrive
        $loaded.Items.ScheduledTasks[0].Xml | Should -BeExactly $xml
        $loaded.Items.ScheduledTasks[0].Enabled | Should -BeFalse
        $loaded.Items.Software.Install[0].Arguments | Should -BeNullOrEmpty
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).SchemaVersion |
            Should -Be 3
    }
    It ('resolves references from the USB root rather than the current ' +
        'directory') {
        $setParams = @{
            LiteralPath = Join-Path $TestDrive 'shared.json'
            Encoding    = 'UTF8'
        }
        '[{"Name":"Example"}]' | Set-Content @setParams
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
        '"another.json"' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'shared.json')
        $configuration.Items.UserAccounts = 'shared.json'
        Write-ConfigurationHC $configuration $path
        $loaded = Read-ConfigurationHC $path $TestDrive
        Test-ConfigurationHC $loaded $TestDrive |
            Should -Match 'nested section references'
    }
    It 'reports a missing reference' {
        $configuration.Items.UserAccounts = 'missing.json'
        @(Test-ConfigurationHC $configuration $TestDrive) |
            Should -Match 'Items.UserAccounts.*missing.json'
    }
    It 'reports invalid referenced JSON' {
        'not json' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'shared.json')
        $configuration.Items.UserAccounts = 'shared.json'
        @(Test-ConfigurationHC $configuration $TestDrive) |
            Should -Match 'Items.UserAccounts.*shared.json'
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
        @(Test-ConfigurationHC $configuration $TestDrive) |
            Should -Match 'Action: unknown property'
    }
    It 'checks asset paths relative to the root' {
        'asset' | Set-Content -LiteralPath (Join-Path $TestDrive 'app.exe')
        $configuration.Items.Software = @{
            Install = @(@{ ExecutablePath = 'app.exe' })
            Remove  = @()
        }
        @(Test-ConfigurationHC $configuration $TestDrive).Count | Should -Be 0

        $configuration.Items.Software.Install[0].ExecutablePath = 'missing.exe'
        @(Test-ConfigurationHC $configuration $TestDrive) |
            Should -Match ('Items.Software.Install\[0\].ExecutablePath' +
                '.*not found')
    }
}

Describe 'Shared snapshot catalogue' {
    It ('preserves the established order and maps every item to an ' +
        'existing script') {
        $scripts = Get-SnapshotScriptsHC
        @($scripts.Keys) | Should -Be @(
            'StartCustomScriptsBefore', 'RegionalSettings', 'AccountPolicy',
            'UserAccounts', 'UserGroups', 'FirewallRules',
            'EnvironmentVariables', 'CreateFolders',
            'SmbShares', 'NetworkCards', 'HostsFileEntries', 'NtpTimeServers',
            'PowerSettings',
            'RegistryKeys', 'ScheduledTasks', 'CopyFilesFolders', 'Software',
            'Services', 'StartCustomScriptsAfter'
        )
        foreach ($script in $scripts.Values) {
            Join-Path "$PSScriptRoot\..\Scripts" $script | Should -Exist
        }
    }
    It ('returns an independent map so caller overrides cannot change the ' +
        'catalogue') {
        $scripts = Get-SnapshotScriptsHC
        $scripts.UserAccounts = 'custom.ps1'
        (Get-SnapshotScriptsHC).UserAccounts |
            Should -Be 'User accounts import export.ps1'
    }
    It 'matches the items supported by the JSON schema' {
        $schemaPath = "$PSScriptRoot\..\Scripts\config.schema.json"
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $names = @(
            $schema.properties.Items.properties.PSObject.Properties.Name |
                Where-Object { $_ -ne 'Comment' } | Sort-Object
        )
        @((Get-SnapshotScriptsHC).Keys | Sort-Object) | Should -Be $names
    }
    It 'loads all empty sections in catalogue order regardless of JSON order' {
        $schemaPath = "$PSScriptRoot\..\Scripts\config.schema.json"
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $items = [ordered]@{}
        $names = (Get-SnapshotScriptsHC).Keys | Sort-Object -Descending
        foreach ($name in $names) {
            $items[$name] = if ($schema.'$defs'.$name.type -eq 'array') {
                ,@()
            }
            else {
                @{}
            }
        }
        $path = Join-Path $TestDrive 'all-items.json'
        Write-ConfigurationHC @{ SchemaVersion = 3; Items = $items } $path

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
        $document = @{
            SchemaVersion = 3
            Items         = [ordered]@{
                CreateFolders = @{ FolderPaths = @('C:\Example') }
            }
        }
    }
    It 'creates a new configuration file' {
        Write-ConfigurationHC $document $path
        $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $written.Items.CreateFolders.FolderPaths | Should -Be @('C:\Example')
    }
    It 'replaces an existing configuration file' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        Write-ConfigurationHC $document $path
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).SchemaVersion |
            Should -Be 3
    }
    It 'leaves no temporary files behind' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        Write-ConfigurationHC $document $path
        @(Get-ChildItem -LiteralPath $folder -Force).Name |
            Should -Be @('Example.json')
    }
    It 'keeps the existing file intact and cleans up when replacing fails' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        $before = Get-Content -LiteralPath $path -Raw
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            { Write-ConfigurationHC $document $path } |
                Should -Throw '*Failed to write configuration*'
            (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
            @(Get-ChildItem -LiteralPath $folder -Force).Name |
                Should -Be @('Example.json')
        }
        finally {
            Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false
        }
    }
    It 'reports a missing folder without creating anything' {
        $missing = Join-Path $folder 'Missing\Example.json'
        { Write-ConfigurationHC $document $missing } |
            Should -Throw '*Failed to write configuration*'
        Join-Path $folder 'Missing' | Should -Not -Exist
    }
}

Describe 'Sections combined from several files' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $newItemParams = @{
            Path     = "$root\Shared", "$root\Configurations"
            ItemType = 'Directory'
            Force    = $true
        }
        $null = New-Item @newItemParams

        function New-SharedFileHC {
            param([string]$Name, [string]$Json)
            $Json | Set-Content -LiteralPath "$root\Shared\$Name" -Encoding UTF8
        }
        function Read-TestConfigurationHC {
            param([string]$ItemsJson)
            $testPath = "$root\Configurations\Test.json"
            '{ "SchemaVersion": 3, "Items": ' + $ItemsJson + ' }' |
                Set-Content -LiteralPath $testPath -Encoding UTF8
            Read-ConfigurationHC $testPath $root
        }
    }
    It 'joins the lists of several files in order' {
        New-SharedFileHC 'Common.json' (
            '[ { "Name": "Data", "Path": "C:\\Data" } ]'
        )
        New-SharedFileHC 'Scanner.json' (
            '[ { "Name": "Scans", "Path": "D:\\Scans" } ]'
        )
        $loaded = Read-TestConfigurationHC (
            '{ "SmbShares": [ "Shared\\Common.json", "Shared\\Scanner.json" ] }'
        )
        $loaded.Problems.Count |
            Should -Be 0 -Because ($loaded.Problems -join '; ')
        @($loaded.Items.SmbShares | ForEach-Object { $_.Name }) |
            Should -Be @('Data', 'Scans')
        @(Test-ConfigurationHC $loaded $root).Count | Should -Be 0
    }
    It 'combines objects and their nested lists' {
        New-SharedFileHC 'A.json' (
            '{ "Comment": "A", "RunAsCurrentUser": { "RegistryKeys": [ ' +
            '{ "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "A", ' +
            '"Type": "String", "Value": "1" } ] } }'
        )
        New-SharedFileHC 'B.json' (
            '{ "Comment": "B", "RunAsCurrentUser": { "RegistryKeys": [ ' +
            '{ "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "B", ' +
            '"Type": "String", "Value": "2" } ] }, "RunAsOtherUser": [] }'
        )
        $loaded = Read-TestConfigurationHC (
            '{ "RegistryKeys": [ "Shared\\A.json", "Shared\\B.json" ] }'
        )
        $loaded.Problems.Count |
            Should -Be 0 -Because ($loaded.Problems -join '; ')
        @(
            $loaded.Items.RegistryKeys.RunAsCurrentUser.RegistryKeys |
                ForEach-Object { $_.Name }
        ) | Should -Be @('A', 'B')
        $loaded.Items.RegistryKeys.Comment | Should -Be 'A'
        @(Test-ConfigurationHC $loaded $root).Count | Should -Be 0
    }
    It 'accepts the same single value in several files' {
        New-SharedFileHC 'A.json' (
            '{ "SyncTimeWithDomain": false, ' +
            '"TimeServerNames": [ "a.example" ] }'
        )
        New-SharedFileHC 'B.json' (
            '{ "SyncTimeWithDomain": false, ' +
            '"TimeServerNames": [ "b.example" ] }'
        )
        $loaded = Read-TestConfigurationHC (
            '{ "NtpTimeServers": [ "Shared\\A.json", "Shared\\B.json" ] }'
        )
        $loaded.Problems.Count |
            Should -Be 0 -Because ($loaded.Problems -join '; ')
        $loaded.Items.NtpTimeServers.TimeServerNames |
            Should -Be @('a.example', 'b.example')
    }
    It 'reports a single value that two files set differently' {
        New-SharedFileHC 'A.json' (
            '{ "WinSystemLocaleName": "nl-BE", ' +
            '"TimeZoneId": "Romance Standard Time", ' +
            '"WinHomeLocationGeoId": 21, "CultureName": "nl-BE" }'
        )
        New-SharedFileHC 'B.json' '{ "TimeZoneId": "W. Europe Standard Time" }'
        $loaded = Read-TestConfigurationHC (
            '{ "RegionalSettings": [ "Shared\\A.json", "Shared\\B.json" ] }'
        )
        $loaded.Problems[0] | Should -BeLike (
            "*'Items.RegionalSettings.TimeZoneId' is " +
            """Romance Standard Time"" in 'Shared\A.json' but " +
            """W. Europe Standard Time"" in 'Shared\B.json'*"
        )
        $loaded.Items.Keys | Should -Not -Contain 'RegionalSettings'
    }
    It 'reports duplicates across files through the normal checks' {
        New-SharedFileHC 'A.json' '[ { "Name": "Data", "Path": "C:\\Data" } ]'
        New-SharedFileHC 'B.json' '[ { "Name": "Data", "Path": "E:\\Other" } ]'
        $loaded = Read-TestConfigurationHC (
            '{ "SmbShares": [ "Shared\\A.json", "Shared\\B.json" ] }'
        )
        (@(Test-ConfigurationHC $loaded $root) -join ';') |
            Should -BeLike "*share 'Data' is already configured*"
    }
    It 'reports a missing file and a file that refers to other files' {
        New-SharedFileHC 'Nested.json' '[ "Shared\\A.json" ]'
        $loaded = Read-TestConfigurationHC (
            '{ "UserAccounts": [ "Shared\\Nested.json" ], ' +
            '"UserGroups": [ "Shared\\Missing.json" ] }'
        )
        ($loaded.Problems -join ';') | Should -BeLike (
            "*reference 'Shared\Nested.json': nested section references " +
            "are not supported*"
        )
        ($loaded.Problems -join ';') |
            Should -BeLike "*reference 'Shared\Missing.json'*"
    }
}
