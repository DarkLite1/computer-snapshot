#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    . "$PSScriptRoot\..\Scripts\Invoke GUI.ps1" -NoShow
}
Describe 'Single-file wizard commands' {
    BeforeEach {
        Mock Start-Process
    }
    It 'launches an export without creating a configuration or temporary files' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Kiosk example' -Items UserAccounts, Software -OpenReportInBrowser $false
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count | Should -Be $before
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command -like '*-Action CreateSnapshot*' -and $command -like '*Configurations\Kiosk example.json*' -and $command -like '*-Items*UserAccounts*Software*'
        }
    }
    It 'includes HHmmss in the suggested export filename' {
        Mock Get-Date { '2026-10-21 142536' } -ParameterFilter { $Format -eq 'yyyy-MM-dd HHmmss' }
        $name = Get-DefaultConfigurationNameHC
        $name | Should -BeExactly "$env:COMPUTERNAME 2026-10-21 142536"
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name $name -Items UserAccounts
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command -like '* 2026-10-21 142536.json*'
        }
    }
    It 'rejects directory traversal in a configuration name' {
        { Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name '..\outside' -Items UserAccounts } | Should -Throw '*file name*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'requires at least one selected export item' {
        { Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Example' -Items @() } | Should -Throw '*Select at least one*'
    }
    It 'launches restore through the configuration launcher' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1])) -like '*Invoke configuration.ps1*-ConfigurationFile*Example.json*'
        }
    }
}