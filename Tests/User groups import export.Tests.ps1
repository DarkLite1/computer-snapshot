#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\User groups import export.ps1" -Name 'User groups'
Describe 'User groups errors' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
        function New-LocalAccountsErrorHC {
            param([string]$Message, [string]$Id)
            [System.Management.Automation.ErrorRecord]::new([Exception]::new($Message), "$Id,Microsoft.PowerShell.Commands.AddLocalGroupMemberCommand", 'InvalidArgument', $null)
        }
    }
    BeforeEach {
        Mock Get-LocalGroup {
            [pscustomobject]@{ Name = 'Administrators'; Description = 'Admins' }
            [pscustomobject]@{ Name = 'Orphans'; Description = '' }
            [pscustomobject]@{ Name = 'Empty'; Description = '' }
        }
        Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'PC1\admin' } }
        Mock Get-LocalGroupMember { throw 'An error (1332) occurred while enumerating the group membership' } -ParameterFilter { $Name -eq 'Orphans' }
        Mock Get-LocalGroupMember { } -ParameterFilter { $Name -eq 'Empty' }
        Mock New-LocalGroup { [pscustomobject]@{ Name = $Name } }
        Mock New-LocalGroup { throw 'Access denied' } -ParameterFilter { $Name -eq 'Broken' }
        Mock Set-LocalGroup
        Mock Add-LocalGroupMember
        Mock Add-LocalGroupMember { throw (New-LocalAccountsErrorHC 'already a member' 'MemberExists') } -ParameterFilter { $Member -like '*exists' }
        Mock Add-LocalGroupMember { throw (New-LocalAccountsErrorHC 'not found' 'PrincipalNotFound') } -ParameterFilter { $Member -like '*ghost' }
        Mock Add-LocalGroupMember { throw 'Access is denied' } -ParameterFilter { $Member -like '*denied' }
    }
    It 'reports each failed member and still adds the other members' {
        $data = @([pscustomobject]@{ Name = 'Administrators'; Description = 'Admins'; Members = @('exists', 'ghost', 'denied', 'bob', $null) })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].Messages | Should -Contain "Account 'exists' is already a member of group 'Administrators'"
        $result[0].Messages | Should -Contain "Added account 'bob' to group 'Administrators'"
        $result[0].Errors | Should -Be @(
            "Failed to add account 'ghost' to group 'Administrators': account not found"
            "Failed to add account 'denied' to group 'Administrators': Access is denied"
        )
        Should -Invoke Add-LocalGroupMember -Times 4 -Exactly
    }
    It 'reports a group that cannot be created and still processes the next group' {
        $data = @(
            [pscustomobject]@{ Name = 'Broken'; Members = @('alice') }
            [pscustomobject]@{ Name = 'Captains'; Description = 'Star fleet'; Members = @('kirk') }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to create or update group 'Broken': Access denied")
        $result[0].Messages | Should -Be @("Created group 'Captains'", "Added account 'kirk' to group 'Captains'")
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -ParameterFilter { $Group -eq 'Broken' }
    }
    It 'leaves the description unchanged when it is not configured' {
        $data = @([pscustomobject]@{ Name = 'Administrators' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Group 'Administrators' already exists and is correct")
        Should -Invoke Set-LocalGroup -Times 0 -Exactly
    }
    It 'reports a group whose members cannot be read and still exports the other groups' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 1
        $result[0].Errors[0] | Should -BeLike "Failed to read the members of group 'Orphans'*"
        @($result[0].Data.Name) | Should -Be @('Administrators', 'Empty')
    }
    It 'exports an empty member list instead of a null member' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        $empty = $result[0].Data | Where-Object { $_.Name -eq 'Empty' }
        $empty.Members.Count | Should -Be 0
    }
}