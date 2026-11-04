#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $testScript = "$PSScriptRoot\..\Scripts\Invoke configuration.ps1"
    $testStartScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"

    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"

    function Invoke-ScriptHC { param($Path, $Arguments) }
    function Test-IsStartedElevatedHC {}
}

Describe 'Configuration launcher' {
    BeforeEach {
        $testConfigurationFile = Join-Path $TestDrive 'Example.json'
        $document = @{
            SchemaVersion = 3
            Description   = 'Example computer'
            Settings      = @{ RunElevated = $false }
            Items         = @{ UserAccounts = @() }
        }
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        Mock Invoke-ScriptHC
        Mock Start-Process
        Mock Test-IsStartedElevatedHC { $false }
        Mock Read-Host { 'y' }
        Mock Out-GridView {
            [pscustomobject]@{ Path = $testConfigurationFile }
        }
        Mock Read-RestoreInputHC {
            throw 'The launcher must not collect input.'
        }
    }
    It 'passes only the action and file path to the main script' {
        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.Action -eq 'RestoreSnapshot' -and
            $Arguments.ConfigurationFile -eq $testConfigurationFile -and
            $Arguments.Count -eq 2
        }
    }
    It 'selects a configuration from the picker' {
        $testParams = @{
            ConfigurationsFolder = $TestDrive
            StartScript          = $testStartScript
            SkipConfirmation     = $true
        }
        . $testScript @testParams

        Should -Invoke Out-GridView -Times 1 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly
    }
    It 'does nothing when confirmation is declined' {
        Mock Read-Host { 'n' }

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It ('relaunches the selected file with an encoded command when ' +
        'elevation is requested') {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationsFolder = $TestDrive
            StartScript          = $testStartScript
            SkipConfirmation     = $true
        }
        . $testScript @testParams

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and
            [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            ).Contains($testConfigurationFile)
        }
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It 'rejects version 1 files without running any child scripts' {
        '{"StartScript":{}}' |
            Set-Content -LiteralPath $testConfigurationFile

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
        }
        { . $testScript @testParams } | Should -Throw '*converter*'

        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It 'forwards the selected sections to the main script' {
        $document.Items.Software = @{
            Install = @(@{ ExecutablePath = 'missing.exe' })
        }
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
            Items             = 'UserAccounts'
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.Items.Count -eq 1 -and
            $Arguments.Items[0] -eq 'UserAccounts'
        }
    }
    It ('forwards explicit runtime settings without editing the saved ' +
        'configuration') {
        $before = Get-Content -LiteralPath $testConfigurationFile -Raw

        $testParams = @{
            ConfigurationFile   = $testConfigurationFile
            StartScript         = $testStartScript
            SkipConfirmation    = $true
            RebootComputer      = $false
            RestartDelaySeconds = 120
            OpenReportInBrowser = $true
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.ContainsKey('RebootComputer') -and
            $Arguments.RebootComputer -eq $false -and
            $Arguments.RestartDelaySeconds -eq 120 -and
            $Arguments.ContainsKey('OpenReportInBrowser') -and
            $Arguments.OpenReportInBrowser -eq $true
        }
        (Get-Content -LiteralPath $testConfigurationFile -Raw) |
            Should -BeExactly $before
    }
    It ('defers input and resolved-value validation until after ' +
        'elevation without passing answers') {
        $document.Settings.RunElevated = $true
        $document.Items.Software = @{
            Install = @(@{ ExecutablePath = '{{input:Installer path}}' })
        }
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
        }
        . $testScript @testParams

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $Verb -eq 'RunAs' -and
            $command.Contains($testConfigurationFile) -and
            $command -notmatch 'Installer path|password'
        }
        Should -Invoke Read-RestoreInputHC -Times 0 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It ('passes placeholder configurations to the executor without ' +
        'collecting answers in the launcher') {
        $document.Items.Software = @{
            Install = @(@{ ExecutablePath = '{{input:Installer path}}' })
        }
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 2
        }
        Should -Invoke Read-RestoreInputHC -Times 0 -Exactly
    }
    It 'preserves selection and runtime settings when relaunching elevated' {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile   = $testConfigurationFile
            StartScript         = $testStartScript
            SkipConfirmation    = $true
            Items               = 'UserAccounts'
            RebootComputer      = $true
            RestartDelaySeconds = 0
            OpenReportInBrowser = $false
        }
        . $testScript @testParams

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $Verb -eq 'RunAs' -and
            $command.Contains("-Items @('UserAccounts')") -and
            $command.Contains('-RestartDelaySeconds 0') -and
            $command.Contains('-RebootComputer $true') -and
            $command.Contains('-OpenReportInBrowser $false')
        }
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It ('asks for confirmation without -SkipConfirmation and stops on ' +
        'another answer than y') {
        Mock Read-Host { 'n' }

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
        }
        . $testScript @testParams

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It 'still accepts the old name -Confirm, for existing shortcuts' {
        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            Confirm           = $true
        }
        . $testScript @testParams

        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly
    }
    It 'relaunches elevated with -SkipConfirmation' {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            SkipConfirmation  = $true
        }
        . $testScript @testParams

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains(' -SkipConfirmation') -and
            -not $command.Contains(' -Confirm')
        }
    }
    It ('passes the answer-file path and unattended flag without asking ' +
        'for confirmation') {
        Mock Test-IsStartedElevatedHC { $true }

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            AnswerFile        = "Answers\kiosk's answers.json"
            Unattended        = $true
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.Unattended -and
            $Arguments.AnswerFile -like "*\Answers\kiosk's answers.json"
        }
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Read-RestoreInputHC -Times 0 -Exactly
    }
    It ('passes only the quoted answer-file path through elevation, not ' +
        'file contents') {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            AnswerFile        = "Answers\kiosk's answers.json"
            SkipConfirmation  = $true
        }
        . $testScript @testParams

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains("\Answers\kiosk''s answers.json'") -and
            $command.Contains(' -AnswerFile ')
        }
    }
    It 'never displays a picker or UAC prompt in unattended mode' {
        $testParams = @{
            StartScript = $testStartScript
            Unattended  = $true
        }
        { . $testScript @testParams } |
            Should -Throw '*requires ConfigurationFile*'

        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            Unattended        = $true
        }
        { . $testScript @testParams } |
            Should -Throw '*administrator rights*'

        Should -Invoke Out-GridView -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It ('refuses unattended without administrator rights, RunElevated ' +
        '<RunElevated>, before reading the configuration') -ForEach @(
        @{ RunElevated = $true }
        @{ RunElevated = $false }
    ) {
        $document.Settings.RunElevated = $RunElevated
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8
        Mock Read-ConfigurationHC {
            throw 'The configuration must not be read.'
        }

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            Unattended        = $true
        }
        {
            . $testScript @testParams
        } | Should -Throw 'Unattended restore requires administrator rights.*'

        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It ('runs an elevation-requesting configuration unattended when ' +
        'already elevated') {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8
        Mock Test-IsStartedElevatedHC { $true }

        $testParams = @{
            ConfigurationFile = $testConfigurationFile
            StartScript       = $testStartScript
            Unattended        = $true
        }
        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            $Arguments.Unattended
        }
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}