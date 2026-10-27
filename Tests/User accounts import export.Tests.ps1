#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\User accounts import export.ps1" -Name 'User accounts'
Describe 'User accounts import errors' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User accounts import export.ps1"
        function New-InvalidPasswordErrorHC {
            [System.Management.Automation.ErrorRecord]::new(
                [Exception]::new('The password does not meet the password policy requirements.'),
                'InvalidPassword,Microsoft.PowerShell.Commands.NewLocalUserCommand', 'InvalidArgument', $null)
        }
    }
    BeforeEach {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'Existing' }; [pscustomobject]@{ Name = 'Locked' } }
        Mock New-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock New-LocalUser { throw (New-InvalidPasswordErrorHC) } -ParameterFilter { $Name -eq 'Weak' }
        Mock Set-LocalUser
        Mock Enable-LocalUser
        Mock Enable-LocalUser { Write-Error "Access denied enabling $Name" } -ParameterFilter { $Name -eq 'Locked' }
        Mock Disable-LocalUser
        Mock Remove-LocalUser
        Mock Read-Host { throw 'Read-Host must not be called' }
    }
    It 'reports each failed user and still processes the others' {
        $data = @(
            [pscustomobject]@{ Name = 'New1'; Enabled = $true; Password = 'Str0ng!pw' }
            [pscustomobject]@{ Name = 'Locked'; Enabled = $true; Password = 'Str0ng!pw' }
            [pscustomobject]@{ Name = 'Existing'; Enabled = $false; Password = '' }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].Messages | Should -Be @("Created user 'New1' (enabled)", "Updated user 'Existing', password unchanged (disabled)")
        $result[0].Errors | Should -Be @("Failed to create or update user account 'Locked': Access denied enabling Locked")
        $result[0].Errors.GetType() | Should -Be ([string[]])
    }
    It 'skips the remaining steps of a user after a failed step' {
        $data = @([pscustomobject]@{ Name = 'Locked'; Enabled = $true; Password = 'Str0ng!pw' })
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-LocalUser -Times 0 -Exactly -ParameterFilter { $null -ne $Password }
    }
    It 'does not create a new user without a password' {
        $data = @([pscustomobject]@{ Name = 'NoPassword'; Enabled = $true; Password = '' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "*'NoPassword': a Password is required*"
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }
    It 'removes a new user again when its password is rejected' {
        $data = @([pscustomobject]@{ Name = 'Weak'; Enabled = $true; Password = 'a' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "*'Weak': the password does not meet*"
        Should -Invoke Remove-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -eq 'Weak' }
    }
    It 'keeps the password of an existing user without a configured password' {
        $data = @([pscustomobject]@{ Name = 'Existing'; Enabled = $true; Password = '' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0
        Should -Invoke Set-LocalUser -Times 0 -Exactly -ParameterFilter { $null -ne $Password }
    }
    It 'never prompts' {
        $data = @(
            [pscustomobject]@{ Name = 'NoPassword'; Enabled = $true; Password = '' }
            [pscustomobject]@{ Name = 'Weak'; Enabled = $true; Password = 'a' }
            [pscustomobject]@{ Name = 'Existing'; Enabled = $true; Password = '' }
        )
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'leaves settings that are not in the configuration unchanged' {
        $data = @([pscustomobject]@{ Name = 'Existing' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0
        $result[0].Messages | Should -Be @("Updated user 'Existing', password unchanged")
        Should -Invoke Enable-LocalUser -Times 0 -Exactly
        Should -Invoke Disable-LocalUser -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 1 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('UserMayChangePassword') -and -not $PSBoundParameters.ContainsKey('FullName') }
    }
}