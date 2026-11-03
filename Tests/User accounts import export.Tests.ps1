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

Describe 'User accounts removal' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User accounts import export.ps1"
        function Get-CurrentUserSidHC {}
    }
    BeforeEach {
        $localUsers = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ Name = 'bob'; SID = 'S-1-5-21-1-2-3-1001' }
            [pscustomobject]@{ Name = 'Other'; SID = 'S-1-5-21-1-2-3-1002' }
            [pscustomobject]@{ Name = 'Operator'; SID = 'S-1-5-21-1-2-3-1003' }
        )
        Mock Get-LocalUser { $localUsers.ToArray() }
        Mock Get-CurrentUserSidHC { 'S-1-5-21-1-2-3-1003' }
        Mock Remove-LocalUser {
            $found = @($localUsers | Where-Object { $_.SID -eq [string]$SID })
            foreach ($user in $found) { $null = $localUsers.Remove($user) }
        }
        Mock New-LocalUser
        Mock Set-LocalUser
        Mock Enable-LocalUser
        Mock Disable-LocalUser
        Mock Remove-Item { throw 'Profile files must not be deleted' }
    }
    It 'removes only the exact named account by SID, ignoring case and retaining files' {
        $data = @([pscustomobject]@{ Name = 'BOB'; Action = 'Remove' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed user account 'BOB' (profile files kept)")
        Should -Invoke Remove-LocalUser -Times 1 -Exactly -ParameterFilter {
            [string]$SID -eq 'S-1-5-21-1-2-3-1001' -and
            -not $Confirm -and
            $ErrorAction -eq 'Stop'
        }
        Should -Invoke New-LocalUser -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 0 -Exactly
        Should -Invoke Enable-LocalUser -Times 0 -Exactly
        Should -Invoke Disable-LocalUser -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
        @($localUsers.Name) | Should -Be @('Other', 'Operator')
    }
    It 'reports already absent accounts and repeated removals as successful no-ops' {
        $data = @(
            [pscustomobject]@{ Name = 'bob'; Action = 'Remove' }
            [pscustomobject]@{ Name = 'bob'; Action = 'Remove' }
            [pscustomobject]@{ Name = 'Absent'; Action = 'Remove' }
        )
        $result = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0
        $result.Messages | Should -Contain "User account 'bob' not found, nothing to remove"
        $result.Messages | Should -Contain "User account 'Absent' not found, nothing to remove"
        Should -Invoke Remove-LocalUser -Times 1 -Exactly
    }
    It 'protects renamed built-in accounts with RID <Rid>' -ForEach @(
        @{ Rid = 500 }; @{ Rid = 501 }; @{ Rid = 503 }; @{ Rid = 504 }
    ) {
        $localUsers[0].SID = "S-1-5-21-1-2-3-$Rid"
        $result = & $scriptPath -Action Import -Data @([pscustomobject]@{ Name = 'bob'; Action = 'Remove' }) -RootFolder $TestDrive
        $result.Errors -join ';' | Should -Match 'built-in Windows accounts cannot be removed'
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }
    It 'protects the account running the restore' {
        $result = & $scriptPath -Action Import -Data @([pscustomobject]@{ Name = 'Operator'; Action = 'Remove' }) -RootFolder $TestDrive
        $result.Errors -join ';' | Should -Match 'account running the restore cannot be removed'
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }
    It 'refuses removal when the account SID cannot be verified' {
        $localUsers[0].SID = $null
        $result = & $scriptPath -Action Import -Data @([pscustomobject]@{ Name = 'bob'; Action = 'Remove' }) -RootFolder $TestDrive
        $result.Errors -join ';' | Should -Match 'cannot verify the local account SID'
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }
    It 'refuses removal when the running account cannot be identified' {
        Mock Get-CurrentUserSidHC { $null }
        $result = & $scriptPath -Action Import -Data @([pscustomobject]@{ Name = 'bob'; Action = 'Remove' }) -RootFolder $TestDrive
        $result.Errors -join ';' | Should -Match 'cannot identify the account running the restore'
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }
    It 'reports removal failures and still creates, updates and removes other accounts' {
        Mock Remove-LocalUser { Write-Error 'Access denied' } -ParameterFilter { [string]$SID -eq 'S-1-5-21-1-2-3-1001' }
        $data = @(
            [pscustomobject]@{ Name = 'bob'; Action = 'Remove' }
            [pscustomobject]@{ Name = 'New'; Password = 'Str0ng!pw' }
            [pscustomobject]@{ Name = 'Operator'; Action = 'Set'; Description = 'Updated' }
            [pscustomobject]@{ Name = 'Other'; Action = 'Remove' }
        )
        $result = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to remove user account 'bob': Access denied")
        $result.Messages | Should -Be @(
            "Created user 'New'"
            "Updated user 'Operator', password unchanged"
            "Removed user account 'Other' (profile files kept)"
        )
    }
    It 'requires a new password if a removed name is later recreated' {
        $data = @(
            [pscustomobject]@{ Name = 'bob'; Action = 'Remove' }
            [pscustomobject]@{ Name = 'bob' }
        )
        $result = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors -join ';' | Should -Match 'a Password is required to create a new user'
        Should -Invoke Set-LocalUser -Times 0 -Exactly
    }
    It 'rejects invalid removal entries before changing accounts' -ForEach @(
        @{ Entry = @{ Name = '*'; Action = 'Remove' } }
        @{ Entry = @{ Name = 'b?b'; Action = 'Remove' } }
        @{ Entry = @{ Name = 'DOMAIN\bob'; Action = 'Remove' } }
        @{ Entry = @{ Name = ''; Action = 'Remove' } }
        @{ Entry = @{ Name = 'bob'; Action = 'Remove'; Password = 'unused' } }
        @{ Entry = @{ Name = 'bob'; Action = 'Remove'; Enabled = $false } }
        @{ Entry = @{ Name = 'bob'; Action = 'Delete' } }
    ) {
        $result = & $scriptPath -Action Import -Data @([pscustomobject]$Entry) -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 1
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 0 -Exactly
    }
}

Describe 'User accounts export' {
    It 'writes a password placeholder for each user, except for accounts Windows manages' {
        Mock Get-LocalUser {
            [pscustomobject]@{ Name = 'Administrator'; SID = 'S-1-5-21-1-2-3-500'; Enabled = $false }
            [pscustomobject]@{ Name = 'Guest'; SID = 'S-1-5-21-1-2-3-501'; Enabled = $false }
            [pscustomobject]@{ Name = 'DefaultAccount'; SID = 'S-1-5-21-1-2-3-503'; Enabled = $false }
            [pscustomobject]@{ Name = 'WDAGUtilityAccount'; SID = 'S-1-5-21-1-2-3-504'; Enabled = $false }
            [pscustomobject]@{ Name = 'kiosk'; SID = 'S-1-5-21-1-2-3-5010'; Enabled = $true }
        }
        $result = @(& "$PSScriptRoot\..\Scripts\User accounts import export.ps1" -Action Export -RootFolder $TestDrive)
        $passwords = @{}
        foreach ($user in $result[0].Data) { $passwords[$user.Name] = $user.Password }
        foreach ($user in $result[0].Data) {
            @($user.PSObject.Properties.Name) | Should -Not -Contain 'Action'
        }
        $passwords['Administrator'] | Should -Be "{{password:Password for local user 'Administrator'}}"
        $passwords['kiosk'] | Should -Be "{{password:Password for local user 'kiosk'}}"
        foreach ($name in 'Guest', 'DefaultAccount', 'WDAGUtilityAccount') {
            $passwords[$name] | Should -Be '' -Because $name
        }
    }
    It 'writes placeholders that a restore recognizes' {
        . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'kiosk'; SID = 'S-1-5-21-1-2-3-1001'; Enabled = $true } }
        $result = @(& "$PSScriptRoot\..\Scripts\User accounts import export.ps1" -Action Export -RootFolder $TestDrive)
        $fields = @(Get-RestoreInputFieldsHC -Data @{ UserAccounts = $result[0].Data })
        $fields.Count | Should -Be 1
        $fields[0].Kind | Should -Be 'password'
        $fields[0].Description | Should -Be "Password for local user 'kiosk'"
    }
}