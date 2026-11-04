#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
    Name       = 'User groups'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'User groups errors' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
        function Get-GroupMemberAdsiHC { param($GroupName) }
        function New-LocalAccountsErrorHC {
            param([string]$Message, [string]$Id)
            [System.Management.Automation.ErrorRecord]::new(
                [Exception]::new($Message),
                "$Id,Microsoft.PowerShell.Commands.AddLocalGroupMemberCommand",
                'InvalidArgument',
                $null
            )
        }
    }
    BeforeEach {
        Mock Get-LocalGroup {
            [pscustomobject]@{
                Name        = 'Administrators'
                Description = 'Admins'
                SID         = 'S-1-5-32-544'
            }
            [pscustomobject]@{
                Name        = 'Orphans'
                Description = ''
                SID         = 'S-1-5-21-1-2-3-1001'
            }
            [pscustomobject]@{
                Name        = 'Empty'
                Description = ''
                SID         = 'S-1-5-21-1-2-3-1002'
            }
        }
        Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'PC1\admin' } }
        Mock Get-LocalGroupMember {
            throw ('An error (1332) occurred while enumerating the group ' +
                'membership')
        } -ParameterFilter { $Name -eq 'Orphans' }
        Mock Get-LocalGroupMember { } -ParameterFilter { $Name -eq 'Empty' }
        Mock Get-GroupMemberAdsiHC {
            throw 'The group name could not be found.'
        }
        Mock New-LocalGroup { [pscustomobject]@{ Name = $Name } }
        Mock New-LocalGroup {
            throw 'Access denied'
        } -ParameterFilter { $Name -eq 'Broken' }
        Mock Set-LocalGroup
        Mock Add-LocalGroupMember
        Mock Add-LocalGroupMember {
            throw (New-LocalAccountsErrorHC 'already a member' 'MemberExists')
        } -ParameterFilter { $Member -like '*exists' }
        Mock Add-LocalGroupMember {
            throw (New-LocalAccountsErrorHC 'not found' 'PrincipalNotFound')
        } -ParameterFilter { $Member -like '*ghost' }
        Mock Add-LocalGroupMember {
            throw 'Access is denied'
        } -ParameterFilter { $Member -like '*denied' }
    }
    It 'reports each failed member and still adds the other members' {
        $data = @(
            [pscustomobject]@{
                Name        = 'Administrators'
                Description = 'Admins'
                Members     = @('exists', 'ghost', 'denied', 'bob', $null)
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result.Count | Should -Be 1
        $result[0].Messages | Should -Contain (
            "Account 'exists' is already a member of group 'Administrators'"
        )
        $result[0].Messages |
            Should -Contain "Added account 'bob' to group 'Administrators'"
        $result[0].Errors | Should -Be @(
            ("Failed to add account 'ghost' to group 'Administrators': " +
                'account not found')
            ("Failed to add account 'denied' to group 'Administrators': " +
                'Access is denied')
        )
        Should -Invoke Add-LocalGroupMember -Times 4 -Exactly
    }
    It ('reports a group that cannot be created and still processes the ' +
        'next group') {
        $data = @(
            [pscustomobject]@{ Name = 'Broken'; Members = @('alice') }
            [pscustomobject]@{
                Name        = 'Captains'
                Description = 'Star fleet'
                Members     = @('kirk')
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            "Failed to create or update group 'Broken': Access denied"
        )
        $result[0].Messages | Should -Be @(
            "Created group 'Captains'"
            "Added account 'kirk' to group 'Captains'"
        )
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -ParameterFilter {
            $Group -eq 'Broken'
        }
    }
    It 'leaves the description unchanged when it is not configured' {
        $data = @([pscustomobject]@{ Name = 'Administrators' })

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages | Should -Be @(
            "Group 'Administrators' already exists and is correct"
        )
        Should -Invoke Set-LocalGroup -Times 0 -Exactly
    }
    It ('reports a group whose members cannot be read and still exports ' +
        'the other groups') {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $result[0].Errors.Count | Should -Be 1
        $result[0].Errors[0] |
            Should -BeLike "Failed to read the members of group 'Orphans'*"
        @($result[0].Data.Name) | Should -Be @('S-1-5-32-544', 'Empty')
    }
    It 'exports an empty member list instead of a null member' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $empty = $result[0].Data | Where-Object { $_.Name -eq 'Empty' }
        $empty.Members.Count | Should -Be 0
    }
}

Describe 'User groups member names' {
    It 'reports a local account of the exported computer under its new name' {
        $scriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
        function Convert-AccountNameHC { param($Name) }
        Mock Convert-AccountNameHC { $Name -replace '^PC1\\', 'PC2\' }
        Mock Get-LocalGroup {
            [pscustomobject]@{ Name = 'Captains'; Description = '' }
        }
        Mock Add-LocalGroupMember

        $data = @(
            [pscustomobject]@{
                Name    = 'Captains'
                Members = @('PC1\picard', 'CONTOSO\kirk')
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages | Should -Contain (
            "Added account 'PC1\picard' as 'PC2\picard' to group 'Captains'"
        )
        $result[0].Messages |
            Should -Contain "Added account 'CONTOSO\kirk' to group 'Captains'"
        Should -Invoke Add-LocalGroupMember -Times 2 -Exactly
    }
}

Describe 'User groups across Windows languages' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
    }
    BeforeEach {
        Mock Get-LocalGroup {
            [pscustomobject]@{
                Name        = 'Administratoren'
                Description = 'Lokale beheerders'
                SID         = 'S-1-5-32-544'
            }
            [pscustomobject]@{
                Name        = 'Captains'
                Description = 'Star fleet'
                SID         = 'S-1-5-21-1-2-3-1005'
            }
        }
        Mock Get-LocalGroupMember {
            [pscustomobject]@{ Name = 'NT AUTHORITY\Iedereen'; SID = 'S-1-1-0' }
        }
        Mock Add-LocalGroupMember
        Mock New-LocalGroup
        Mock Set-LocalGroup
    }
    It ('exports built-in groups and members by SID, without their ' +
        'translated description') {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $builtIn = $result[0].Data | Where-Object { $_.Name -eq 'S-1-5-32-544' }
        $builtIn.Members | Should -Be @('S-1-1-0')
        $builtIn.Keys | Should -Not -Contain 'Description'
        $builtIn.Comment | Should -BeLike "Built-in group 'Administratoren'*"
        (
            $result[0].Data | Where-Object { $_.Name -eq 'Captains' }
        ).Description | Should -Be 'Star fleet'
    }
    It ('finds a built-in group by SID and never creates a group named ' +
        'after a SID') {
        $data = @(
            [pscustomobject]@{ Name = 'S-1-5-32-544'; Members = @('kirk') }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages | Should -Contain (
            "Group 'Administratoren' already exists and is correct"
        )
        $result[0].Messages |
            Should -Contain "Added account 'kirk' to group 'Administratoren'"
        Should -Invoke New-LocalGroup -Times 0 -Exactly
    }
    It 'reports a SID that is not a group on this computer' {
        $data = @([pscustomobject]@{ Name = 'S-1-5-32-999' })

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors[0] |
            Should -BeLike "*there is no group with SID 'S-1-5-32-999'*"
        Should -Invoke New-LocalGroup -Times 0 -Exactly
    }
}

Describe 'User groups with orphaned members' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\User groups import export.ps1"
        function Get-GroupMemberAdsiHC { param($GroupName) }
    }
    BeforeEach {
        Mock Get-LocalGroup {
            [pscustomobject]@{
                Name        = 'Helpdesk'
                Description = 'Support'
                SID         = 'S-1-5-21-1-2-3-1009'
            }
        }
        Mock Get-LocalGroupMember {
            throw ('An error (1332) occurred while enumerating the group ' +
                'membership.')
        }
        Mock Get-GroupMemberAdsiHC {
            [pscustomobject]@{ Name = 'PC1\kirk'; SID = 'S-1-5-21-1-2-3-1001' }
            [pscustomobject]@{ Name = $null; SID = 'S-1-5-21-9-9-9-1234' }
        }
    }
    It 'exports the other members through ADSI and reports the orphaned one' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Data[0].Members | Should -Be @('PC1\kirk')
        $result[0].Messages | Should -Contain (
            "Group 'Helpdesk': skipped member 'S-1-5-21-9-9-9-1234', an " +
            'account that cannot be resolved (deleted, or its domain is ' +
            'unreachable)'
        )
    }
    It 'reports both reasons when ADSI fails too' {
        Mock Get-GroupMemberAdsiHC { throw 'Access is denied.' }

        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $result[0].Errors | Should -Be @(
            ("Failed to read the members of group 'Helpdesk': An error " +
                '(1332) occurred while enumerating the group membership.; ' +
                'reading them through ADSI failed too: Access is denied.')
        )
        @($result[0].Data).Count | Should -Be 0
    }
    It 'does not use ADSI when Get-LocalGroupMember works' {
        Mock Get-LocalGroupMember {
            [pscustomobject]@{ Name = 'PC1\kirk'; SID = 'S-1-5-21-1-2-3-1001' }
        }

        $null = & $scriptPath -Action Export -RootFolder $TestDrive

        Should -Invoke Get-GroupMemberAdsiHC -Times 0 -Exactly
    }
}