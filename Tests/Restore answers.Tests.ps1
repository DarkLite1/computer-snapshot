#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
    . "$PSScriptRoot\Common\Restore input.ps1"
}

Describe 'Answers handed over by the wizard' {
    BeforeEach {
        $dictionaryType = (
            'System.Collections.Generic.Dictionary[string,string]'
        )
        $wizardAnswers = New-Object $dictionaryType ([StringComparer]::Ordinal)
        $wizardAnswers['{{input:Name}}'] = 'kiosk'
        $wizardAnswers['{{input:name}}'] = 'other'
        $wizardAnswers['{{password:Password}}'] = "Test-only`r`n""pass""!"
        $server = $null
    }
    AfterEach {
        if ($server) {
            $server.PowerShell.Stop()
            $server.PowerShell.Dispose()
        }
    }
    It 'hands every answer over once, from memory, with case-sensitive keys' {
        $server = Start-RestoreAnswerServerHC -Answers $wizardAnswers

        $received = Receive-RestoreAnswersHC -PipeName $server.PipeName

        $received.Count | Should -Be 3
        $received['{{input:Name}}'] | Should -BeExactly 'kiosk'
        $received['{{input:name}}'] | Should -BeExactly 'other'
        $received['{{password:Password}}'] |
            Should -BeExactly "Test-only`r`n""pass""!"
        $server.PipeName | Should -Match '^ComputerSnapshot-[0-9a-f]{32}$'
        $server.PipeName | Should -Not -Match 'kiosk'

        {
            $receiveParams = @{
                PipeName       = $server.PipeName
                TimeoutSeconds = 1
            }
            Receive-RestoreAnswersHC @receiveParams
        } | Should -Throw
    }
    It 'fails quickly when no wizard serves the answers' {
        $pipeName = 'ComputerSnapshot-' + [guid]::NewGuid().ToString('N')

        { Receive-RestoreAnswersHC -PipeName $pipeName -TimeoutSeconds 1 } |
            Should -Throw
    }
}

Describe 'Answer file reading and resolution' {
    BeforeEach {
        $answerPath = Join-Path $TestDrive 'answers.json'
        $items = @{
            UserAccounts = @(
                @{
                    Name     = '{{input:Account}}'
                    Password = '{{password:Password}}'
                }
            )
        }
    }
    It ('uses supplied answers without prompting, deduplicates fields ' +
        'and records secrets') {
        ('{"Answers":{"{{input:Account}}":"Example",' +
            '"{{password:Password}}":"Test-secret!42"}}') |
            Set-Content -LiteralPath $answerPath
        $items.UserAccounts += @{ Name = '{{input:Account}}' }
        $answers = Read-RestoreAnswerFileHC $answerPath
        $params = @{
            Items      = $items
            Answers    = $answers
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }
        $result = Resolve-RestoreInputHC @params
        $items.UserAccounts[0].Name | Should -Be 'Example'
        $items.UserAccounts[1].Name | Should -Be 'Example'
        $result.Values.Count | Should -Be 2
        $result.SecretValues | Should -Be @('Test-secret!42')
    }
    It 'prompts only for missing or null answers' {
        ('{"Answers":{"{{input:Account}}":"Example",' +
            '"{{password:Password}}":null}}') |
            Set-Content -LiteralPath $answerPath
        $answers = Read-RestoreAnswerFileHC $answerPath
        $params = @{
            Items      = $items
            Answers    = $answers
            ReadValues = (New-FakeReadValuesHC {
                param($field)
                $field.Placeholder | Should -Be '{{password:Password}}'
                'Prompt-secret!42'
            })
        }
        $result = Resolve-RestoreInputHC @params
        $result.Values['{{input:Account}}'] | Should -Be 'Example'
        $result.SecretValues | Should -Be @('Prompt-secret!42')
    }
    It ('fails unattended on all missing answers before mutating data ' +
        'or prompting') {
        $before = $items | ConvertTo-Json -Depth 10
        $params = @{
            Items      = $items
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }
        $failure = { Resolve-RestoreInputHC @params } |
            Should -Throw '*missing answers*' -PassThru
        $failure.Exception.Message | Should -Match '\{\{input:Account\}\}'
        $failure.Exception.Message |
            Should -Match '\{\{password:Password\}\}'
        ($items | ConvertTo-Json -Depth 10) | Should -BeExactly $before
    }
    It 'matches complete placeholder keys exactly, including case' {
        '{"Answers":{"{{input:account}}":"Example"}}' |
            Set-Content -LiteralPath $answerPath
        {
            $params = @{
                Items      = $items
                Answers    = (Read-RestoreAnswerFileHC $answerPath)
                Unattended = $true
                ReadValues = { throw 'Unexpected prompt' }
            }
            Resolve-RestoreInputHC @params
        } |
            Should -Throw '*missing answers*{{input:Account}}*'
    }
    It ('supports unattended configurations without placeholders or ' +
        'an answer file') {
        $params = @{
            Items      = @{ UserAccounts = @(@{ Name = 'Existing' }) }
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }
        $result = Resolve-RestoreInputHC @params
        $result.Values.Count | Should -Be 0
    }
    It ('preserves distinct case-sensitive keys and literal escaped values ' +
        'on both PowerShell versions') {
        ('{"Answers":{"{{input:Name}}":"Example","{{input:name}}":"Other",' +
            '"{{password:Secret}}":"line1\n\"&<>\\line2"}}') |
            Set-Content -LiteralPath $answerPath
        $answers = Read-RestoreAnswerFileHC $answerPath
        $answers['{{input:Name}}'] | Should -BeExactly 'Example'
        $answers['{{input:name}}'] | Should -BeExactly 'Other'
        $answers['{{password:Secret}}'] |
            Should -BeExactly ("line1`n" + '"&<>\line2')
    }
    It 'rejects duplicate answer keys rather than silently choosing a value' {
        ('{"Answers":{"{{input:Account}}":null,' +
            '"{{input:Account}}":"Example"}}') |
            Set-Content -LiteralPath $answerPath
        { Read-RestoreAnswerFileHC $answerPath } |
            Should -Throw '*duplicate answer key*'
    }
    It 'keeps interactive cancellation behavior when an answer is missing' {
        { Resolve-RestoreInputHC -Items $items -ReadValues { $null } } |
            Should -Throw '*Restore cancelled*'
    }
    It 'validates IPv4 and prefix answers and converts a prefix to an integer' {
        ('{"Answers":{"{{ipv4:Server}}":"192.0.2.10",' +
            '"{{prefix:Prefix}}":"24"}}') |
            Set-Content -LiteralPath $answerPath
        $data = @{
            Address = '{{ipv4:Server}}'
            Prefix  = '{{prefix:Prefix}}'
        }
        $params = @{
            Items      = $data
            Answers    = (Read-RestoreAnswerFileHC $answerPath)
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }
        $null = Resolve-RestoreInputHC @params
        $data.Address | Should -Be '192.0.2.10'
        $data.Prefix | Should -BeOfType ([int])
        $data.Prefix | Should -Be 24
    }
    It ('rejects invalid supplied answers without revealing ' +
        'their values') -ForEach @(
        @{ Key = '{{ipv4:Server}}'; Value = 'INVALID-secret-value' }
        @{ Key = '{{prefix:Prefix}}'; Value = '33-secret-value' }
        @{ Key = '{{ipv4:Server}}'; Value = 24 }
        @{ Key = '{{password:Password}}'; Value = '' }
        @{ Key = '{{input:Account}}'; Value = @('secret-value') }
    ) {
        @{ Answers = @{ $Key = $Value } } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $answerPath
        { Read-RestoreAnswerFileHC $answerPath } |
            Should -Throw '*must be a nonempty, valid*string*'
        try { Read-RestoreAnswerFileHC $answerPath }
        catch { [string]$_ | Should -Not -Match 'secret-value' }
    }
    It 'accepts a prefix answer written as a number or as text' -ForEach @(
        @{ Value = '24' }
        @{ Value = '"24"' }
    ) {
        ('{"Answers":{"{{prefix:Prefix}}":' + $Value + '}}') |
            Set-Content -LiteralPath $answerPath

        $answers = Read-RestoreAnswerFileHC $answerPath

        $answers['{{prefix:Prefix}}'] | Should -BeExactly '24'
    }
    It ('rejects the prefix answer <Value> without revealing other ' +
        'answers') -ForEach @(
        @{ Value = '24.5' }
        @{ Value = '0' }
        @{ Value = '33' }
        @{ Value = 'true' }
    ) {
        ('{"Answers":{"{{password:Password}}":"Other-secret-value",' +
            '"{{prefix:Prefix}}":' + $Value + '}}') |
            Set-Content -LiteralPath $answerPath

        $failure = { Read-RestoreAnswerFileHC $answerPath } |
            Should -Throw '*valid prefix string or number*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'secret-value'
    }
    It 'accepts a number answer written as a number or as text' -ForEach @(
        @{ Value = '15' }
        @{ Value = '"15"' }
    ) {
        ('{"Answers":{"{{number:Minutes}}":' + $Value + '}}') |
            Set-Content -LiteralPath $answerPath

        $answers = Read-RestoreAnswerFileHC $answerPath

        $answers['{{number:Minutes}}'] | Should -BeExactly '15'
    }
    It ('rejects the number answer <Value> without revealing other ' +
        'answers') -ForEach @(
        @{ Value = '1.5' }
        @{ Value = 'true' }
        @{ Value = '"015"' }
        @{ Value = '"abc"' }
        @{ Value = '1e3' }
        @{ Value = '9223372036854775808' }
    ) {
        ('{"Answers":{"{{password:Password}}":"Other-secret-value",' +
            '"{{number:Minutes}}":' + $Value + '}}') |
            Set-Content -LiteralPath $answerPath

        $failure = { Read-RestoreAnswerFileHC $answerPath } |
            Should -Throw '*valid number string or number*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'secret-value'
    }
    It 'fills in a number answer from an answer file as a number' {
        '{"Answers":{"{{number:Minutes}}":30}}' |
            Set-Content -LiteralPath $answerPath
        $data = @{
            Software = @{
                Install = @(
                    @{
                        ExecutablePath = 'Setup.exe'
                        TimeoutMinutes = '{{number:Minutes}}'
                    }
                )
            }
        }
        $params = @{
            Items      = $data
            Answers    = (Read-RestoreAnswerFileHC $answerPath)
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }

        $null = Resolve-RestoreInputHC @params

        $data.Software.Install[0].TimeoutMinutes | Should -BeOfType ([int])
        $data.Software.Install[0].TimeoutMinutes | Should -Be 30
    }
    It 'rejects invalid document shapes, keys and malformed JSON' -ForEach @(
        @{ Json = '[]' }
        @{ Json = '{"Answers":[]}' }
        @{ Json = '{"answers":{}}' }
        @{ Json = '{"Answers":{},"Unexpected":true}' }
        @{ Json = '{"Answers":{"Account":"Example"}}' }
        @{ Json = '{"Answers":{"{{input:Account}}":"SECRET-MALFORMED"' }
    ) {
        $Json | Set-Content -LiteralPath $answerPath
        { Read-RestoreAnswerFileHC $answerPath } | Should -Throw
        try { Read-RestoreAnswerFileHC $answerPath }
        catch { [string]$_ | Should -Not -Match 'SECRET-MALFORMED' }
    }
    It 'fails on a missing file instead of treating it as empty answers' {
        {
            Read-RestoreAnswerFileHC (Join-Path $TestDrive 'missing.json')
        } | Should -Throw
    }
    It ('uses the same answers for configuration and copied-file ' +
        'placeholders without changing the source') {
        $source = Join-Path $TestDrive 'template.txt'
        'host={{ipv4:Server}};prefix={{prefix:Prefix}}' |
            Set-Content -LiteralPath $source
        $before = Get-Content -LiteralPath $source -Raw
        ('{"Answers":{"{{ipv4:Server}}":"192.0.2.10",' +
            '"{{prefix:Prefix}}":"24"}}') |
            Set-Content -LiteralPath $answerPath
        $data = @{
            NtpTimeServers   = @{ TimeServerNames = @('{{ipv4:Server}}') }
            CopyFilesFolders = @(@{ From = $source; FillPlaceholders = $true })
        }
        $params = @{
            Items      = $data
            RootFolder = $TestDrive
            Answers    = (Read-RestoreAnswerFileHC $answerPath)
            Unattended = $true
            ReadValues = { throw 'Unexpected prompt' }
        }
        $result = Resolve-RestoreInputHC @params
        $result.Values.Count | Should -Be 2
        $data.NtpTimeServers.TimeServerNames[0] | Should -Be '192.0.2.10'
        (Get-Content -LiteralPath $source -Raw) | Should -BeExactly $before
    }
}

Describe 'Test-ConfigurationBeforeInputHC' {
    It ('leaves problems of placeholder values for later and reports ' +
        'the others') {
        $configuration = @{
            SchemaVersion = 3
            Items         = @{
                NetworkCards = @(
                    @{
                        FindBy = @{ Name = 'Ethernet' }
                        Change = @{
                            IPSettings = @{
                                IPAddress    = '{{ipv4:Address}}'
                                PrefixLength = '{{prefix:Prefix}}'
                            }
                        }
                    }
                )
                Software     = @{
                    Install = @(
                        @{ ExecutablePath = '{{input:Installer}}' }
                        @{ ExecutablePath = 'Missing\setup.exe' }
                    )
                }
            }
        }

        $problems = @(
            Test-ConfigurationBeforeInputHC $configuration $TestDrive
        )

        $problems.Count | Should -Be 1 -Because ($problems -join '; ')
        $problems[0] |
            Should -BeLike "*Install[[]1].ExecutablePath: file 'Missing*"
    }
    It 'leaves a registry value that is still a placeholder for later' {
        $configuration = @{
            SchemaVersion = 3
            Items         = @{
                RegistryKeys = @{
                    RunAsCurrentUser = @{
                        RegistryKeys = @(
                            @{
                                Path  = 'HKCU:\Software\Example'
                                Name  = 'Port'
                                Type  = 'DWord'
                                Value = '{{input:Port number}}'
                            }
                            @{
                                Path  = 'HKCU:\Software\Example'
                                Name  = 'Retries'
                                Type  = 'DWord'
                                Value = 'many'
                            }
                            @{
                                Path   = 'HKCU:\Software\Example'
                                Action = 'RemoveValue'
                            }
                        )
                    }
                }
            }
        }

        $problems = @(
            Test-ConfigurationBeforeInputHC $configuration $TestDrive
        )

        $problems.Count | Should -Be 2 -Because ($problems -join '; ')
        $problems[0] | Should -BeLike (
            '*RunAsCurrentUser.RegistryKeys[[]1].Value: ' +
            "'many' is not a number*"
        )
        $problems[1] | Should -BeLike (
            '*RunAsCurrentUser.RegistryKeys[[]2].Name: ' +
            'required for Action RemoveValue'
        )
    }
}

Describe 'Answer template generation' {
    BeforeEach {
        $configurationPath = Join-Path $TestDrive 'configuration.json'
        $answerPath = Join-Path $TestDrive (
            ([guid]::NewGuid().ToString('N')) + '.answers.json'
        )
        $sharedPath = Join-Path $TestDrive 'users.json'
        $sourcePath = Join-Path $TestDrive 'template.txt'
        ('[{"Name":"{{input:Account}}","Password":"{{password:Password}}",' +
            '"Description":"{{input:Account}}"}]') |
            Set-Content -LiteralPath $sharedPath
        'host={{ipv4:Server}};prefix={{prefix:Prefix}}' |
            Set-Content -LiteralPath $sourcePath
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts     = 'users.json'
                CopyFilesFolders = @(
                    @{
                        From             = 'template.txt'
                        To               = 'C:\Example\template.txt'
                        FillPlaceholders = $true
                    }
                )
                Software         = 'missing-unselected.json'
            }
        } $configurationPath
    }
    It ('generates null answers from selected shared sections and ' +
        'template files without changing sources') {
        $files = @($configurationPath, $sharedPath, $sourcePath)
        $before = @(Get-Content -LiteralPath $files -Raw)
        $params = @{
            ConfigurationFile = $configurationPath
            AnswerFile        = $answerPath
            RootFolder        = $TestDrive
            Items             = @('UserAccounts', 'CopyFilesFolders')
        }
        $result = New-RestoreAnswerFileHC @params
        $result | Should -Be $answerPath
        $document = Get-Content -LiteralPath $answerPath -Raw |
            ConvertFrom-Json
        @($document.Answers.PSObject.Properties).Count | Should -Be 4
        foreach ($property in $document.Answers.PSObject.Properties) {
            $property.Value | Should -BeNullOrEmpty
        }
        (Read-RestoreAnswerFileHC $answerPath).Count | Should -Be 0
        @(Get-Content -LiteralPath $files -Raw) | Should -Be $before
        $tempFiles = @{
            LiteralPath = $TestDrive
            Filter      = '.answers-*.tmp'
            Force       = $true
        }
        @(Get-ChildItem @tempFiles).Count | Should -Be 0
    }
    It 'lists number placeholders of the configuration and of files' {
        'wait={{number:Seconds}}' | Set-Content -LiteralPath $sourcePath
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                Software         = @{
                    Install = @(
                        @{
                            ExecutablePath = 'C:\Windows\notepad.exe'
                            TimeoutMinutes = '{{number:Minutes}}'
                        }
                    )
                }
                CopyFilesFolders = @(
                    @{
                        From             = $sourcePath
                        To               = 'C:\Example\template.txt'
                        FillPlaceholders = $true
                    }
                )
            }
        } $configurationPath
        $script = Join-Path $PSScriptRoot '..\Scripts\New answer file.ps1'

        $null = & $script -ConfigurationFile $configurationPath -AnswerFile (
            $answerPath
        )

        $document = Get-Content -LiteralPath $answerPath -Raw |
            ConvertFrom-Json
        @($document.Answers.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('{{number:Minutes}}', '{{number:Seconds}}')
    }
    It 'protects existing answer files unless Force is explicitly used' {
        'existing answers' | Set-Content -LiteralPath $answerPath
        $params = @{
            ConfigurationFile = $configurationPath
            AnswerFile        = $answerPath
            RootFolder        = $TestDrive
            Items             = 'UserAccounts'
        }
        { New-RestoreAnswerFileHC @params } |
            Should -Throw '*already exists*'
        (Get-Content -LiteralPath $answerPath -Raw).Trim() |
            Should -Be 'existing answers'
        $null = New-RestoreAnswerFileHC @params -Force
        $document = Get-Content -LiteralPath $answerPath -Raw |
            ConvertFrom-Json
        $document.Answers.PSObject.Properties.Name |
            Should -Contain '{{password:Password}}'
    }
    It 'never overwrites the configuration itself, even with Force' {
        $params = @{
            ConfigurationFile = $configurationPath
            AnswerFile        = $configurationPath
            RootFolder        = $TestDrive
            Items             = 'UserAccounts'
            Force             = $true
        }
        { New-RestoreAnswerFileHC @params } |
            Should -Throw '*must not replace the configuration*'
    }
    It ('fails on missing template files instead of producing an ' +
        'incomplete answer template') {
        Remove-Item -LiteralPath $sourcePath
        $params = @{
            ConfigurationFile = $configurationPath
            AnswerFile        = $answerPath
            RootFolder        = $TestDrive
            Items             = 'CopyFilesFolders'
        }
        { New-RestoreAnswerFileHC @params } |
            Should -Throw '*Cannot discover file placeholders*'
    }
    It 'provides a CLI generator that only writes the answer file' {
        $repository = Split-Path $PSScriptRoot -Parent
        $params = @{
            ConfigurationFile = (
                "$repository\Configurations\Example Prompted Setup.json"
            )
            AnswerFile        = $answerPath
        }
        $null = & "$repository\Scripts\New answer file.ps1" @params
        $document = Get-Content -LiteralPath $answerPath -Raw |
            ConvertFrom-Json
        @($document.Answers.PSObject.Properties).Count | Should -Be 3
    }
    It ('ships partial examples in Answers whose keys exactly match the ' +
        'prompted configuration, without a password') {
        $repository = Split-Path $PSScriptRoot -Parent
        $examplesFolder = Join-Path $repository 'Answers\Examples'
        $examples = @(
            Get-ChildItem -LiteralPath $examplesFolder -Recurse -File
        )
        $configurationFile = Join-Path $repository (
            'Configurations\Example Prompted Setup.json'
        )
        $configuration = Read-ConfigurationHC $configurationFile $repository
        $fields = @(Get-RestoreInputFieldsHC -Data $configuration.Items)

        @($examples.Name | Sort-Object -Unique) |
            Should -Be @('Example Prompted Setup.json')
        $examples.Count | Should -Be 3
        foreach ($example in $examples) {
            $document = Get-Content -LiteralPath $example.FullName -Raw |
                ConvertFrom-Json
            @($document.Answers.PSObject.Properties.Name | Sort-Object) |
                Should -Be @($fields.Placeholder | Sort-Object)
            $answers = Read-RestoreAnswerFileHC $example.FullName
            $answers.Count | Should -Be 2
            foreach ($field in @($fields | Where-Object Kind -eq 'password')) {
                $document.Answers.($field.Placeholder) | Should -BeNullOrEmpty
            }
        }
    }
}
