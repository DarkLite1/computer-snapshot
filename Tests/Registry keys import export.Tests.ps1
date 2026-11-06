#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContractParams = @{
    ScriptPath  = "$PSScriptRoot\..\Engine\Scripts\Registry keys import export.ps1"
    Name        = 'Registry keys'
    EmptyExport = $true
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContractParams

Describe 'Registry keys import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Registry keys import export.ps1"

        # Stand-ins so the script's own helpers can be mocked
        function Get-UserSidHC { param($UserName) }
        function Get-UserProfilePathHC { param($Sid) }
        function New-UserProfileHC { param($UserName, $Password) }
        function Invoke-RegExeHC { param($Arguments) }
        function Get-RegistryKeyStateHC { param($Path, $Name) }
        function New-KeyStateHC {
            param(
                [bool]$KeyExists = $true,
                [string]$Kind = 'DWord',
                [string]$Name
            )
            $values = @{ Ok = 1; Denied = 0 }
            [pscustomobject]@{
                KeyExists   = $KeyExists
                ValueNames  = @($values.Keys)
                SubKeyNames = @()
                ValueExists = (
                    $KeyExists -and $Name -and $values.ContainsKey($Name)
                )
                Value       = if ($Name) { $values[$Name] } else { $null }
                Kind        = $Kind
            }
        }
    }
    BeforeEach {
        Mock Get-RegistryKeyStateHC { New-KeyStateHC -Name $Name }
        Mock New-ItemProperty
        Mock New-ItemProperty {
            throw 'Requested registry access is not allowed.'
        } -ParameterFilter { $Name -eq 'Denied' }
        Mock New-Item { [pscustomobject]@{ Handle = $null } }
        Mock Test-Path { $true }
        Mock Test-Path { $false } -ParameterFilter {
            $LiteralPath -like 'Registry::HKEY_USERS\S-1-5-21-*'
        }
        Mock Get-UserSidHC { "S-1-5-21-$UserName" }
        Mock Get-UserSidHC {
            throw "user account '$UserName' does not exist"
        } -ParameterFilter { $UserName -eq 'ghost' }
        Mock Get-UserProfilePathHC { "C:\Users\$($Sid -replace '^S-1-5-21-')" }
        Mock New-UserProfileHC
        Mock Invoke-RegExeHC

        $key = {
            param($Name, $Value)
            [pscustomobject]@{
                Path  = 'HKCU:\Software\Test'
                Name  = $Name
                Value = $Value
                Type  = 'DWORD'
            }
        }
    }
    It 'reports a failed value and still sets the other values' {
        $data = [pscustomobject]@{
            RunAsCurrentUser = [pscustomobject]@{
                RegistryKeys = @((& $key 'Denied' '1'), (& $key 'Ok' '2'))
            }
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to set registry value 'Denied' in " +
            "'HKCU:\Software\Test' to '1' with type 'DWORD': " +
            'Requested registry access is not allowed.')
        )
        $result[0].Messages | Should -Be @(
            ("Registry value 'Ok' in 'HKCU:\Software\Test' updated " +
            "from '1' to '2'")
        )
    }
    It 'updates a value that has the right data but the wrong type' {
        Mock Get-RegistryKeyStateHC {
            New-KeyStateHC -Name $Name -Kind 'String'
        }
        $data = [pscustomobject]@{
            RunAsCurrentUser = [pscustomobject]@{
                RegistryKeys = @(& $key 'Ok' '1')
            }
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages | Should -Be @(
            ("Registry value 'Ok' in 'HKCU:\Software\Test' updated " +
            "from type 'String' to DWord '1'")
        )
        Should -Invoke New-ItemProperty -Times 1 -Exactly
    }
    It 'creates missing parent keys one at a time without -Force' {
        Mock Get-RegistryKeyStateHC {
            New-KeyStateHC -Name $Name -KeyExists $false
        }
        Mock Test-Path { $false } -ParameterFilter {
            $LiteralPath -like 'HKLM:\SOFTWARE\Vendor*'
        }
        $data = [pscustomobject]@{
            RunAsCurrentUser = [pscustomobject]@{
                RegistryKeys = @(
                    [pscustomobject]@{
                        Path  = 'HKLM:\SOFTWARE\Vendor\App'
                        Name  = 'Ok'
                        Value = '1'
                        Type  = 'DWORD'
                    }
                )
            }
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count | Should -Be 0 -Because (
            $result[0].Errors -join '; '
        )
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKLM:\SOFTWARE\Vendor'
        }
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKLM:\SOFTWARE\Vendor\App'
        }
        Should -Invoke New-Item -Times 0 -Exactly -ParameterFilter { $Force }
    }
    It ('loads another user''s registry under a temporary name and ' +
        'always unloads it') {
        $data = [pscustomobject]@{
            RunAsOtherUser = @(
                [pscustomobject]@{
                    UserName     = 'bob'
                    RegistryKeys = @((& $key 'Denied' '1'), (& $key 'Ok' '2'))
                }
            )
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors[0] |
        Should -BeLike "User 'bob': Failed to set registry value 'Denied'*"
        $result[0].Messages[0] | Should -Be (
            "User 'bob': Registry value 'Ok' in 'HKCU:\Software\Test' " +
            "updated from '1' to '2'"
        )
        Should -Invoke Get-RegistryKeyStateHC -ParameterFilter {
            $Path -like 'Registry::HKEY_USERS\ComputerSnapshot_*\Software\Test'
        }
        Should -Invoke Invoke-RegExeHC -Times 1 -Exactly -ParameterFilter {
            $Arguments -like (
                'load "HKEY_USERS\ComputerSnapshot_*" ' +
                '"C:\Users\bob\NTUSER.DAT"'
            )
        }
        Should -Invoke Invoke-RegExeHC -Times 1 -Exactly -ParameterFilter {
            $Arguments -like 'unload "HKEY_USERS\ComputerSnapshot_*"'
        }
    }
    It 'uses the loaded registry of a signed-in user without loading it again' {
        Mock Test-Path { $true } -ParameterFilter {
            $LiteralPath -eq 'Registry::HKEY_USERS\S-1-5-21-alice'
        }
        $data = [pscustomobject]@{
            RunAsOtherUser = @(
                [pscustomobject]@{
                    UserName     = 'alice'
                    RegistryKeys = @(& $key 'Ok' '2')
                }
            )
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages[0] | Should -BeLike (
            "User 'alice': Registry value 'Ok' in 'HKCU:\Software\Test'*"
        )
        Should -Invoke Get-RegistryKeyStateHC -ParameterFilter {
            $Path -eq 'Registry::HKEY_USERS\S-1-5-21-alice\Software\Test'
        }
        Should -Invoke Invoke-RegExeHC -Times 0 -Exactly
    }
    It ('reports a user without a profile and without a password, and ' +
        'continues with the next user') {
        Mock Test-Path { $false } -ParameterFilter {
            $LiteralPath -eq 'C:\Users\nopw\NTUSER.DAT'
        }
        $data = [pscustomobject]@{
            RunAsOtherUser = @(
                [pscustomobject]@{
                    UserName     = 'nopw'
                    RegistryKeys = @(& $key 'Ok' '2')
                }
                [pscustomobject]@{
                    UserName     = 'ghost'
                    RegistryKeys = @(& $key 'Ok' '2')
                }
                [pscustomobject]@{
                    UserName     = 'bob'
                    RegistryKeys = @(& $key 'Ok' '2')
                }
            )
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to set the registry values of user 'nopw': the user " +
            "has no profile yet; 'UserPassword' is required to create it")
            ("Failed to set the registry values of user 'ghost': user " +
            "account 'ghost' does not exist")
        )
        @(
            $result[0].Messages | Where-Object { $_ -like "User 'bob':*" }
        ).Count | Should -Be 1
        Should -Invoke New-UserProfileHC -Times 0 -Exactly
    }
    It 'reports a registry that could not be unloaded' {
        Mock Invoke-RegExeHC {
            throw 'reg.exe unload failed with exit code 1'
        } -ParameterFilter { $Arguments -like 'unload *' }
        $data = [pscustomobject]@{
            RunAsOtherUser = @(
                [pscustomobject]@{
                    UserName     = 'bob'
                    RegistryKeys = @(& $key 'Ok' '2')
                }
            )
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors[0] | Should -BeLike (
            "Failed to unload the registry of user 'bob' from " +
            "'HKEY_USERS\ComputerSnapshot_*'*exit code 1"
        )
    }
    It ('does nothing for a section without RunAsCurrentUser or ' +
        'RunAsOtherUser') {
        $data = [pscustomobject]@{
            RunAsCurrentUser = [pscustomobject]@{ Comment = 'none yet' }
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count | Should -Be 0 -Because (
            $result[0].Errors -join '; '
        )
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }
}

Describe 'Registry keys on the real registry' {
    # Works in a temporary key below HKCU, which only affects the current user
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Registry keys import export.ps1"
    }
    BeforeEach {
        $testKey = (
            'HKCU:\Software\ComputerSnapshot.Tests\' +
            [guid]::NewGuid().ToString('N')
        )
        $null = New-Item -Path $testKey -Force

        function Invoke-EntryHC {
            param([object[]]$Entries)
            $data = [pscustomobject]@{
                RunAsCurrentUser = [pscustomobject]@{
                    RegistryKeys = $Entries
                }
            }
            @(
                & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
            )[0]
        }
    }
    AfterEach {
        $parentKey = Split-Path $testKey -Parent
        Remove-Item -LiteralPath $parentKey -Recurse -Force -ErrorAction Ignore
    }
    It 'sets every value type and does not rewrite unchanged values' {
        $entries = @(
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'Text'
                Type  = 'String'
                Value = 'hello'
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'Expand'
                Type  = 'ExpandString'
                Value = '%SystemRoot%\Temp'
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'List'
                Type  = 'MultiString'
                Value = @('one', 'two')
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'Bytes'
                Type  = 'Binary'
                Value = '01 0A FF'
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'Small'
                Type  = 'DWORD'
                Value = '0xFFFFFFFF'
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = 'Big'
                Type  = 'QWord'
                Value = 16
            }
            [pscustomobject]@{
                Path  = $testKey
                Name  = ''
                Type  = 'String'
                Value = 'default value'
            }
        )

        $result = Invoke-EntryHC $entries

        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')

        $key = Get-Item -LiteralPath $testKey
        try {
            $key.GetValue('Text') | Should -Be 'hello'
            $key.GetValue('Expand', $null, 'DoNotExpandEnvironmentNames') |
            Should -Be '%SystemRoot%\Temp'
            [string]$key.GetValueKind('Expand') | Should -Be 'ExpandString'
            $key.GetValue('List') | Should -Be @('one', 'two')
            $key.GetValue('Bytes') | Should -Be ([byte[]]@(1, 10, 255))
            $key.GetValue('Small') | Should -Be -1
            [string]$key.GetValueKind('Small') | Should -Be 'DWord'
            $key.GetValue('Big') | Should -Be 16
            [string]$key.GetValueKind('Big') | Should -Be 'QWord'
            $key.GetValue('') | Should -Be 'default value'
        }
        finally { $key.Dispose() }

        $again = Invoke-EntryHC $entries

        @(
            $again.Messages | Where-Object { $_ -notlike '*is already correct' }
        ) | Should -BeNullOrEmpty
    }
    It 'removes a value, and reports a value that does not exist' {
        $null = New-ItemProperty -LiteralPath $testKey -Name 'Old' -Value 'x'

        $result = Invoke-EntryHC @(
            [pscustomobject]@{
                Action = 'RemoveValue'
                Path   = $testKey
                Name   = 'Old'
            }
            [pscustomobject]@{
                Action = 'RemoveValue'
                Path   = $testKey
                Name   = 'Old'
            }
        )

        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages[1] |
        Should -BeLike '*does not exist, nothing to remove'
        (Get-Item -LiteralPath $testKey).GetValueNames() |
        Should -Not -Contain 'Old'
    }
    It 'clears values only, values and subkeys, or removes the key' {
        $null = New-ItemProperty -LiteralPath $testKey -Name 'Value' -Value 'x'
        $null = New-Item -Path "$testKey\Sub" -Force
        $innerValueParams = @{
            LiteralPath = "$testKey\Sub"
            Name        = 'Inner'
            Value       = 'y'
        }
        $null = New-ItemProperty @innerValueParams

        $result = Invoke-EntryHC @(
            [pscustomobject]@{ Action = 'ClearValues'; Path = $testKey }
        )
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        @((Get-Item -LiteralPath $testKey).GetValueNames()).Count | Should -Be 0
        "$testKey\Sub" | Should -Exist

        $null = New-ItemProperty -LiteralPath $testKey -Name 'Value' -Value 'x'
        $result = Invoke-EntryHC @(
            [pscustomobject]@{ Action = 'ClearKey'; Path = $testKey }
        )
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $testKey | Should -Exist
        "$testKey\Sub" | Should -Not -Exist
        @((Get-Item -LiteralPath $testKey).GetValueNames()).Count | Should -Be 0

        $result = Invoke-EntryHC @(
            [pscustomobject]@{ Action = 'RemoveKey'; Path = $testKey }
        )
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        $testKey | Should -Not -Exist
    }
    It 'refuses to clear or remove a hive root or a key directly below it' {
        $result = Invoke-EntryHC @(
            [pscustomobject]@{
                Action = 'ClearKey'
                Path   = 'HKCU:\Software'
            }
            [pscustomobject]@{
                Action = 'RemoveKey'
                Path   = 'HKEY_CURRENT_USER'
            }
        )

        $result.Errors.Count | Should -Be 2
        $result.Errors | ForEach-Object { $_ | Should -BeLike '*refused*' }
        'HKCU:\Software' | Should -Exist
    }
}
