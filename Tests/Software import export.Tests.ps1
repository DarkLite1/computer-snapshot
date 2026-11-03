#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Software import export.ps1" -Name 'Software'
Describe 'Software import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        function Get-InstalledApplicationsHC { }
        function Remove-ApplicationHC { param($ApplicationName, $UninstallString) }
    }
    BeforeEach {
        $fakeInstalledApplications = [System.Collections.Generic.List[string]]@('Old App', 'Stuck App', 'Msi App')
        Mock Get-InstalledApplicationsHC {
            foreach ($name in $fakeInstalledApplications) {
                [pscustomobject]@{ DisplayName = $name; UninstallString = if ($name -eq 'Msi App') { 'MsiExec.exe /I{AAAA}' } else { "C:\$name\uninstall.exe" } }
            }
        }
        Mock Remove-ApplicationHC { if ($ApplicationName -ne 'Stuck App') { $null = $fakeInstalledApplications.Remove($ApplicationName) }; 0 }
        Mock Remove-ApplicationHC { 3010 } -ParameterFilter { $ApplicationName -eq 'Msi App' }
        Mock Test-Path { $true }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } } -ParameterFilter { $FilePath -like '*reboot.exe' }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1603 } } -ParameterFilter { $FilePath -like '*fail.exe' }
    }
    It 'reports a failed removal and still removes and installs the rest' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Stuck App' }, [pscustomobject]@{ DisplayName = 'Old App' }); Install = @([pscustomobject]@{ ExecutablePath = 'Software\ok.exe'; Arguments = '/S' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to remove application 'Stuck App': the application is still installed after the uninstall (exit code 0)")
        $result[0].Messages | Should -Be @("Removed application 'Old App'", "Installed 'Software\ok.exe' with arguments '/S'")
    }
    It 'makes a Windows Installer uninstall silent and uses /X' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Msi App' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'MsiExec.exe /X{AAAA} /qn /norestart' }
        $result[0].Messages | Should -Be @("Removed application 'Msi App', a restart is needed to complete the removal")
    }
    It 'treats exit code 3010 as success that needs a restart and reports other exit codes' {
        $data = [pscustomobject]@{ Install = @(
                [pscustomobject]@{ ExecutablePath = 'Software\reboot.exe' }
                [pscustomobject]@{ ExecutablePath = 'Software\fail.exe' }
                [pscustomobject]@{ ExecutablePath = 'Software\ok.exe' }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Installed 'Software\reboot.exe', a restart is needed to complete the installation", "Installed 'Software\ok.exe'")
        $result[0].Errors | Should -Be @("Failed to install 'Software\fail.exe': the installation failed with exit code 1603, success exit codes are 0")
    }
    It 'reports a missing installer with its full path' {
        Mock Test-Path { $false }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\missing.exe' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "Failed to install 'Software\missing.exe': the file '*\Software\missing.exe' does not exist"
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'reports an application that is not installed as nothing to remove' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Not There' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Application 'Not There' is not installed, nothing to remove")
        Should -Invoke Remove-ApplicationHC -Times 0 -Exactly
    }
    It 'restores the working folder' {
        $before = (Get-Location).Path
        $null = & $scriptPath -Action Import -Data ([pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\fail.exe' }) }) -RootFolder $TestDrive
        (Get-Location).Path | Should -Be $before
    }
    It 'accepts the exit codes listed in SuccessExitCodes and shows them' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } } -ParameterFilter { $FilePath -like '*vendor.exe' }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\vendor.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Installed 'Software\vendor.exe' (exit code 1)")
    }
    It 'still treats 3010 as success with a restart when SuccessExitCodes is set' {
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\reboot.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Installed 'Software\reboot.exe', a restart is needed to complete the installation")
    }
    It 'reports an exit code that is not listed' {
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\fail.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to install 'Software\fail.exe': the installation failed with exit code 1603, success exit codes are 0, 1")
    }
}


Describe 'Software removal by pattern' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        function Get-InstalledApplicationsHC { }
        function Remove-ApplicationHC { param($ApplicationName, $UninstallString) }
    }
    BeforeEach {
        $fakeApplications = [System.Collections.Generic.List[object]]::new()
        foreach ($fake in @(
                , @('Vendor Tool 1.0', 'C:\Tool1\uninst.exe', $null)
                , @('Vendor Tool 2.0', 'C:\Tool2\uninst.exe', 'C:\Tool2\uninst.exe /quiet')
                , @('Twice', 'C:\Twice64\uninst.exe', $null)
                , @('Twice', 'C:\Twice32\uninst.exe', $null)
                , @('App [x64]', 'C:\Bracket\uninst.exe', $null)
                , @('App 1', 'C:\App1\uninst.exe', $null)
            )) {
            $fakeApplications.Add([pscustomobject]@{ DisplayName = $fake[0]; UninstallString = $fake[1]; QuietUninstallString = $fake[2] })
        }
        Mock Get-InstalledApplicationsHC { $fakeApplications.ToArray() }
        Mock Remove-ApplicationHC {
            foreach ($fake in @($fakeApplications | Where-Object { $UninstallString -like "$($_.UninstallString)*" -or $UninstallString -like '*custom.exe*' })) {
                $null = $fakeApplications.Remove($fake)
            }
            0
        }
    }
    It 'removes every application that matches *, each with its own command' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'vendor tool*' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Vendor Tool 1.0'", "Removed application 'Vendor Tool 2.0'")
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool1\uninst.exe' }
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool2\uninst.exe /quiet' }
    }
    It 'removes both applications with the same name and treats brackets literally' {
        $data = [pscustomobject]@{ Remove = @(
                [pscustomobject]@{ DisplayName = 'Twice' }
                [pscustomobject]@{ DisplayName = 'App [x64]' }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Twice'", "Removed application 'Twice'", "Removed application 'App [x64]'")
        @($fakeApplications.DisplayName) | Should -Be @('Vendor Tool 1.0', 'Vendor Tool 2.0', 'App 1')
    }
    It 'adds UninstallArguments to the uninstall string, not the quiet command' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Vendor Tool 2.0'; UninstallArguments = '/S' }) }
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool2\uninst.exe /S' }
    }
    It 'runs UninstallCommand once for all matches and accepts its SuccessExitCodes' {
        Mock Remove-ApplicationHC {
            foreach ($fake in @($fakeApplications | Where-Object { $_.DisplayName -like 'Vendor Tool*' })) { $null = $fakeApplications.Remove($fake) }
            1
        }
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Vendor Tool*'; UninstallCommand = 'C:\custom.exe /all'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Vendor Tool 1.0', 'Vendor Tool 2.0'")
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\custom.exe /all' }
    }
    It 'refuses a pattern that matches more than 5 applications unless AllowMultiple is set' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = '*' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to remove application '*': '*' matches 6 applications; nothing was removed. Use a narrower DisplayName, or set AllowMultiple to remove them all")
        Should -Invoke Remove-ApplicationHC -Times 0 -Exactly
        $data.Remove[0] | Add-Member -NotePropertyName AllowMultiple -NotePropertyValue $true
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $fakeApplications.Count | Should -Be 0
    }
}

Describe 'Installed applications lookup' {
    It 'handles exactly one 32-bit application next to 64-bit applications' {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'One32'; UninstallString = 'x' } } -ParameterFilter { $Path -like '*Wow6432Node*' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ DisplayName = 'A64'; UninstallString = 'x' }
            [pscustomobject]@{ DisplayName = 'B64'; UninstallString = 'x' }
        } -ParameterFilter { $Path -notlike '*Wow6432Node*' }
        . $scriptPath -Action Export -RootFolder $TestDrive | Out-Null
        @(Get-InstalledApplicationsHC).DisplayName | Should -Be @('A64', 'B64', 'One32')
    }
}