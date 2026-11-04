#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
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
            ReadValue  = { throw 'Unexpected prompt' }
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
            Items     = $items
            Answers   = $answers
            ReadValue = {
                param($field)
                $field.Placeholder | Should -Be '{{password:Password}}'
                'Prompt-secret!42'
            }
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
            ReadValue  = { throw 'Unexpected prompt' }
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
                ReadValue  = { throw 'Unexpected prompt' }
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
            ReadValue  = { throw 'Unexpected prompt' }
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
        { Resolve-RestoreInputHC -Items $items -ReadValue { $null } } |
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
            ReadValue  = { throw 'Unexpected prompt' }
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
            ReadValue  = { throw 'Unexpected prompt' }
        }
        $result = Resolve-RestoreInputHC @params
        $result.Values.Count | Should -Be 2
        $data.NtpTimeServers.TimeServerNames[0] | Should -Be '192.0.2.10'
        (Get-Content -LiteralPath $source -Raw) | Should -BeExactly $before
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
                "$repository\Configurations\Example prompted setup.json"
            )
            AnswerFile        = $answerPath
        }
        $null = & "$repository\Scripts\New answer file.ps1" @params
        $document = Get-Content -LiteralPath $answerPath -Raw |
            ConvertFrom-Json
        @($document.Answers.PSObject.Properties).Count | Should -Be 3
    }
    It ('ships a partial example whose keys exactly match the prompted ' +
        'configuration') {
        $repository = Split-Path $PSScriptRoot -Parent
        $example = Join-Path $repository 'Examples\Answers prompted setup.json'
        $configurationFile = Join-Path $repository (
            'Configurations\Example prompted setup.json'
        )
        $configuration = Read-ConfigurationHC $configurationFile $repository
        $fields = @(Get-RestoreInputFieldsHC -Data $configuration.Items)
        $document = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
        @($document.Answers.PSObject.Properties.Name | Sort-Object) |
            Should -Be @($fields.Placeholder | Sort-Object)
        $answers = Read-RestoreAnswerFileHC $example
        $answers.Count | Should -Be 2
        foreach ($field in @($fields | Where-Object Kind -eq 'password')) {
            $document.Answers.($field.Placeholder) | Should -BeNullOrEmpty
        }
    }
}
