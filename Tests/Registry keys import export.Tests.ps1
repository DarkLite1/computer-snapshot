#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Registry keys import export.ps1" -Name 'Registry keys'
Describe 'Registry keys import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Registry keys import export.ps1"
        # Stand-ins so the script's own helpers can be mocked
        function Get-UserSidHC { param($UserName) }
        function Get-UserProfilePathHC { param($Sid) }
        function New-UserProfileHC { param($UserName, $Password) }
        function Invoke-RegExeHC { param($Arguments) }
        function New-ValueKindItemHC {
            param([string]$Kind)
            $item = [pscustomobject]@{ Kind = $Kind }
            $item | Add-Member ScriptMethod GetValueKind { param($Name) $this.Kind }
            $item
        }
    }
    BeforeEach {
        Mock Get-ItemProperty { [pscustomobject]@{ Ok = '1'; Denied = '0' } }
        Mock Get-Item { New-ValueKindItemHC 'DWord' }
        Mock New-ItemProperty
        Mock New-ItemProperty { throw 'Requested registry access is not allowed.' } -ParameterFilter { $Name -eq 'Denied' }
        Mock New-Item { [pscustomobject]@{ Handle = $null } }
        Mock Test-Path { $true }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'Registry::HKEY_USERS\S-1-5-21-*' }
        Mock Get-UserSidHC { "S-1-5-21-$UserName" }
        Mock Get-UserSidHC { throw "user account '$UserName' does not exist" } -ParameterFilter { $UserName -eq 'ghost' }
        Mock Get-UserProfilePathHC { "C:\Users\$($Sid -replace '^S-1-5-21-')" }
        Mock New-UserProfileHC
        Mock Invoke-RegExeHC
        $key = { param($Name, $Value) [pscustomobject]@{ Path = 'HKCU:\Software\Test'; Name = $Name; Value = $Value; Type = 'DWORD' } }
    }
    It 'reports a failed value and still sets the other values' {
        $data = [pscustomobject]@{ RunAsCurrentUser = [pscustomobject]@{ RegistryKeys = @((& $key 'Denied' '1'), (& $key 'Ok' '2')) } }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to set registry value 'Denied' in 'HKCU:\Software\Test' to '1' with type 'DWORD': Requested registry access is not allowed.")
        $result[0].Messages | Should -Be @("Registry value 'Ok' in 'HKCU:\Software\Test' updated from '1' to '2'")
    }
    It 'updates a value that has the right data but the wrong type' {
        Mock Get-Item { New-ValueKindItemHC 'String' }
        $data = [pscustomobject]@{ RunAsCurrentUser = [pscustomobject]@{ RegistryKeys = @(& $key 'Ok' '1') } }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Registry value 'Ok' in 'HKCU:\Software\Test' updated from type 'String' to 'DWORD'")
        Should -Invoke New-ItemProperty -Times 1 -Exactly
    }
    It 'creates missing parent keys one at a time without -Force' {
        Mock Get-ItemProperty { throw [System.Management.Automation.ItemNotFoundException]::new('Cannot find path') }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HKLM:\SOFTWARE\Vendor*' }
        $data = [pscustomobject]@{ RunAsCurrentUser = [pscustomobject]@{ RegistryKeys = @([pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Vendor\App'; Name = 'Ok'; Value = '1'; Type = 'DWORD' }) } }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Vendor' }
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Vendor\App' }
        Should -Invoke New-Item -Times 0 -Exactly -ParameterFilter { $Force }
    }
    It 'loads another user''s registry under a temporary name and always unloads it' {
        $data = [pscustomobject]@{ RunAsOtherUser = @([pscustomobject]@{ UserName = 'bob'; RegistryKeys = @((& $key 'Denied' '1'), (& $key 'Ok' '2')) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "User 'bob': Failed to set registry value 'Denied'*"
        $result[0].Messages[0] | Should -BeLike "User 'bob': Registry value 'Ok' in 'Registry::HKEY_USERS\ComputerSnapshot_*\Software\Test' updated*"
        Should -Invoke Invoke-RegExeHC -Times 1 -Exactly -ParameterFilter { $Arguments -like 'load "HKEY_USERS\ComputerSnapshot_*" "C:\Users\bob\NTUSER.DAT"' }
        Should -Invoke Invoke-RegExeHC -Times 1 -Exactly -ParameterFilter { $Arguments -like 'unload "HKEY_USERS\ComputerSnapshot_*"' }
    }
    It 'uses the loaded registry of a signed-in user without loading it again' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS\S-1-5-21-alice' }
        $data = [pscustomobject]@{ RunAsOtherUser = @([pscustomobject]@{ UserName = 'alice'; RegistryKeys = @(& $key 'Ok' '2') }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages[0] | Should -BeLike "User 'alice': Registry value 'Ok' in 'Registry::HKEY_USERS\S-1-5-21-alice\Software\Test'*"
        Should -Invoke Invoke-RegExeHC -Times 0 -Exactly
    }
    It 'reports a user without a profile and without a password, and continues with the next user' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\Users\nopw\NTUSER.DAT' }
        $data = [pscustomobject]@{ RunAsOtherUser = @(
                [pscustomobject]@{ UserName = 'nopw'; RegistryKeys = @(& $key 'Ok' '2') }
                [pscustomobject]@{ UserName = 'ghost'; RegistryKeys = @(& $key 'Ok' '2') }
                [pscustomobject]@{ UserName = 'bob'; RegistryKeys = @(& $key 'Ok' '2') }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @(
            "Failed to set the registry values of user 'nopw': the user has no profile yet; 'UserPassword' is required to create it"
            "Failed to set the registry values of user 'ghost': user account 'ghost' does not exist"
        )
        @($result[0].Messages | Where-Object { $_ -like "User 'bob':*" }).Count | Should -Be 1
        Should -Invoke New-UserProfileHC -Times 0 -Exactly
    }
    It 'reports a registry that could not be unloaded' {
        Mock Invoke-RegExeHC { throw 'reg.exe unload failed with exit code 1' } -ParameterFilter { $Arguments -like 'unload *' }
        $data = [pscustomobject]@{ RunAsOtherUser = @([pscustomobject]@{ UserName = 'bob'; RegistryKeys = @(& $key 'Ok' '2') }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "Failed to unload the registry of user 'bob' from 'HKEY_USERS\ComputerSnapshot_*'*exit code 1"
    }
    It 'does nothing for a section without RunAsCurrentUser or RunAsOtherUser' {
        $result = @(& $scriptPath -Action Import -Data ([pscustomobject]@{ RunAsCurrentUser = [pscustomobject]@{ Comment = 'none yet' } }) -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }
}