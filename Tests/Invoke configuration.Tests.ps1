#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    $testScript = "$PSScriptRoot\..\Scripts\Invoke configuration.ps1"
    $testStartScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"
    function Invoke-ScriptHC { param($Path, $Arguments) }
    function Test-IsStartedElevatedHC {}
}
Describe 'Configuration launcher' {
    BeforeEach {
        $testConfigurationFile = Join-Path $TestDrive 'Example.json'
        $document = @{ SchemaVersion = 2; Description = 'Example computer'; Settings = @{ RunElevated = $false }; Items = @{ UserAccounts = @() } }
        $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8
        Mock Invoke-ScriptHC
        Mock Start-Process
        Mock Test-IsStartedElevatedHC { $false }
        Mock Read-Host { 'y' }
        Mock Out-GridView { [pscustomobject]@{ Path = $testConfigurationFile } }
    }
    It 'passes only the action and file path to the main script' {
        . $testScript -ConfigurationFile $testConfigurationFile -StartScript $testStartScript -Confirm
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { $Arguments.Action -eq 'RestoreSnapshot' -and $Arguments.ConfigurationFile -eq $testConfigurationFile -and $Arguments.Count -eq 2 }
    }
    It 'selects a configuration from the picker' {
        . $testScript -ConfigurationsFolder $TestDrive -StartScript $testStartScript -Confirm
        Should -Invoke Out-GridView -Times 1 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly
    }
    It 'does nothing when confirmation is declined' {
        Mock Read-Host { 'n' }
        . $testScript -ConfigurationFile $testConfigurationFile -StartScript $testStartScript
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It 'relaunches the selected file with an encoded command when elevation is requested' {
        $document.Settings.RunElevated = $true
        $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $testConfigurationFile -Encoding UTF8
        . $testScript -ConfigurationsFolder $TestDrive -StartScript $testStartScript -Confirm
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1])).Contains($testConfigurationFile)
        }
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
    It 'rejects version 1 files without running any child scripts' {
        '{"StartScript":{}}' | Set-Content -LiteralPath $testConfigurationFile
        { . $testScript -ConfigurationFile $testConfigurationFile -StartScript $testStartScript -Confirm } | Should -Throw '*converter*'
        Should -Invoke Invoke-ScriptHC -Times 0 -Exactly
    }
}