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
        $data = [pscustomobject]@{ Remove = @('Stuck App', 'Old App'); Install = @([pscustomobject]@{ ExecutablePath = 'Software\ok.exe'; Arguments = '/S' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to remove application 'Stuck App': the application is still installed after the uninstall (exit code 0)")
        $result[0].Messages | Should -Be @("Removed application 'Old App'", "Installed 'Software\ok.exe' with arguments '/S'")
    }
    It 'makes a Windows Installer uninstall silent and uses /X' {
        $data = [pscustomobject]@{ Remove = @('Msi App') }
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
        $result[0].Errors | Should -Be @("Failed to install 'Software\fail.exe': the installation failed with exit code 1603")
    }
    It 'reports a missing installer with its full path' {
        Mock Test-Path { $false }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\missing.exe' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "Failed to install 'Software\missing.exe': the file '*\Software\missing.exe' does not exist"
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'reports an application that is not installed as nothing to remove' {
        $data = [pscustomobject]@{ Remove = @('Not There') }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Application 'Not There' is not installed, nothing to remove")
        Should -Invoke Remove-ApplicationHC -Times 0 -Exactly
    }
    It 'restores the working folder' {
        $before = (Get-Location).Path
        $null = & $scriptPath -Action Import -Data ([pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\fail.exe' }) }) -RootFolder $TestDrive
        (Get-Location).Path | Should -Be $before
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