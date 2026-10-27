#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Start custom scripts import export.ps1" -Name 'Start custom scripts'
Describe 'Start custom scripts import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Start custom scripts import export.ps1"
        $customRoot = Join-Path $TestDrive 'Usb'
        $null = New-Item -Path (Join-Path $customRoot 'Files') -ItemType Directory -Force
        @'
param($Name = 'world')
Write-Output "Hello $Name"
Write-Host 'host line'
Write-Warning 'careful'
'@ | Set-Content -LiteralPath (Join-Path $customRoot 'Files\ok.ps1')
        @'
Write-Error 'something went wrong'
Write-Output 'kept going'
'@ | Set-Content -LiteralPath (Join-Path $customRoot 'Files\soft.ps1')
        @'
Write-Output 'before'
throw 'boom'
'@ | Set-Content -LiteralPath (Join-Path $customRoot 'Files\throws.ps1')
        @'
exit 3
'@ | Set-Content -LiteralPath (Join-Path $customRoot 'Files\exit.ps1')
    }
    It 'adds output, host lines and warnings to the report and passes arguments' {
        $data = @([pscustomobject]@{ Path = 'Files\ok.ps1'; Arguments = [pscustomobject]@{ Name = 'Brecht'; Comment = 'ignored' } })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $customRoot)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @(
            'Files\ok.ps1: Hello Brecht'
            'Files\ok.ps1: host line'
            'Files\ok.ps1: WARNING: careful'
            "Ran script 'Files\ok.ps1'"
        )
    }
    It 'lets a script continue after a non-terminating error and reports the error' {
        $result = @(& $scriptPath -Action Import -Data @([pscustomobject]@{ Path = 'Files\soft.ps1' }) -RootFolder $customRoot)
        $result[0].Messages | Should -Be @('Files\soft.ps1: kept going')
        $result[0].Errors | Should -Be @("Script 'Files\soft.ps1' failed: something went wrong")
    }
    It 'reports a throwing script, a non-zero exit code and a missing script, and still runs the others' {
        $data = @(
            [pscustomobject]@{ Path = 'Files\throws.ps1' }
            [pscustomobject]@{ Path = 'Files\exit.ps1' }
            [pscustomobject]@{ Path = 'Files\missing.ps1' }
            [pscustomobject]@{ Path = 'Files\ok.ps1' }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $customRoot)
        $result[0].Errors[0] | Should -Be "Script 'Files\throws.ps1' failed: boom"
        $result[0].Errors[1] | Should -Be "Script 'Files\exit.ps1' failed: the script ended with exit code 3"
        $result[0].Errors[2] | Should -BeLike "Script 'Files\missing.ps1' failed: the file '*missing.ps1' does not exist"
        $result[0].Messages | Should -Contain "Ran script 'Files\ok.ps1'"
        $result[0].Messages | Should -Contain 'Files\throws.ps1: before'
    }
}