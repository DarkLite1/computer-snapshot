#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

Describe 'Dell driver update example' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $runner = Join-Path $root 'Scripts\Start custom scripts import export.ps1'
        $data = Get-Content -LiteralPath (Join-Path $root 'Examples\StartCustomScriptsAfter.json') -Raw | ConvertFrom-Json
    }
    BeforeEach {
        Mock Test-Path { $true }
        Mock New-Item {}
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'runs driver-only updates synchronously without rebooting and reports the log' {
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages -join "`n" | Should -Match 'Dell driver updates completed successfully'
        $result.Messages -join "`n" | Should -Match 'Dell Command Update log:'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $env:ProgramW6432 'Dell\CommandUpdate\dcu-cli.exe') -and
            $Wait -and $PassThru -and
            $ArgumentList.Count -eq 5 -and
            $ArgumentList[0] -eq '/applyUpdates' -and
            $ArgumentList[1] -eq '-silent' -and
            $ArgumentList[2] -eq '-updateType=driver' -and
            $ArgumentList[3] -eq '-reboot=disable' -and
            $ArgumentList[4] -like '-outputLog="*\ComputerSnapshot\Logs\DellDrivers-*.log"'
        }
    }
    It 'reports restart-required as a successful outcome with a warning' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages -join "`n" | Should -Match 'WARNING:.*require a restart'
    }
    It 'reports no applicable updates as success' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 500 } }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages -join "`n" | Should -Match 'No applicable Dell driver updates'
    }
    It 'fails on a pending restart rather than reporting updates as installed' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors -join "`n" | Should -Match 'pending restart.*Restart and rerun.*Log:'
    }
    It 'reports other Dell errors with their exit code and log location' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1000 } }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors -join "`n" | Should -Match 'failed with exit code 1000.*Log:'
    }
    It 'finds the CLI under Program Files x86 when it is not in the native directory' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*\dcu-cli.exe' }
        Mock Test-Path { $true } -ParameterFilter {
            $LiteralPath -eq (Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe')
        }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe')
        }
    }
    It 'fails clearly without launching anything when Command Update is missing' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*\dcu-cli.exe' }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors -join "`n" | Should -Match 'CLI was not found.*Install Dell Command Update'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'reports a failure to create the log directory without launching updates' {
        Mock New-Item { throw 'Log directory access denied' }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors -join "`n" | Should -Match 'Log directory access denied'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'reports process launch failures' {
        Mock Start-Process { throw 'Cannot start Dell Command Update' }
        $result = & $runner -Action Import -Data $data -RootFolder $root
        $result.Errors -join "`n" | Should -Match 'Cannot start Dell Command Update'
    }
}
