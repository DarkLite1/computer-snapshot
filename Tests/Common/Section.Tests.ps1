#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\..\Scripts\Common\Section.ps1"
}

Describe 'New-SectionResultHC' {
    It 'returns string arrays for lists, one message and nothing' {
        $messages = New-Object 'System.Collections.Generic.List[string]'
        $messages.Add('one')
        $messages.Add('two')

        $result = New-SectionResultHC -Messages $messages
        $single = New-SectionResultHC -Messages 'only'
        $empty = New-SectionResultHC -Messages $null -Errors $null

        $result.Messages | Should -Be @('one', 'two')
        $result.Messages.GetType() | Should -Be ([string[]])
        $result.Errors.GetType() | Should -Be ([string[]])
        $result.Errors.Count | Should -Be 0
        $single.Messages.GetType() | Should -Be ([string[]])
        $single.Messages | Should -Be @('only')
        $empty.Messages.GetType() | Should -Be ([string[]])
        $empty.Errors.GetType() | Should -Be ([string[]])
        $empty.Data | Should -BeNullOrEmpty
    }
    It 'keeps the shape of the data' {
        $data = @([ordered]@{ Name = 'only' })

        $result = New-SectionResultHC -Data $data

        $result.Data.GetType().IsArray | Should -BeTrue
        $result.Data.Count | Should -Be 1
    }
}

Describe 'Test-ElevatedHC' {
    It 'tells whether the current process runs as administrator' {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $expected = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
        $identity.Dispose()

        $result = Test-ElevatedHC

        $result | Should -BeOfType [bool]
        $result | Should -Be $expected
    }
}

Describe 'Account names' {
    Context 'Convert-AccountNameHC' {
        BeforeEach {
            $knownAccounts = @(
                'CONTOSO\Domain Admins'
                "$env:COMPUTERNAME\bob"
            )
            Mock Test-AccountExistsHC { $knownAccounts -contains $Name }
        }
        It 'keeps a domain account that this computer can resolve' {
            Convert-AccountNameHC -Name 'CONTOSO\Domain Admins' |
                Should -Be 'CONTOSO\Domain Admins'
        }
        It 'maps a local account of the exported computer to this computer' {
            Convert-AccountNameHC -Name 'PC1\bob' |
                Should -Be "$env:COMPUTERNAME\bob"
        }
        It 'keeps a name that cannot be resolved in any form' {
            Convert-AccountNameHC -Name 'PC1\ghost' | Should -Be 'PC1\ghost'
            Convert-AccountNameHC -Name 'CONTOSO\ghost' |
                Should -Be 'CONTOSO\ghost'
        }
        It ('keeps names without a prefix, service accounts and ' +
            'this computer''s accounts') {
            foreach ($name in @(
                    'kiosk'
                    'NT SERVICE\TrustedInstaller'
                    "$env:COMPUTERNAME\alice"
                )) {
                Convert-AccountNameHC -Name $name | Should -Be $name
            }
            Should -Invoke Test-AccountExistsHC -Times 0 -Exactly
        }
    }
    Context 'Built-in accounts by English name' {
        It ('exports a built-in account by English name, a local or domain ' +
            'or service account by name, and an unknown built-in by SID') {
            $params = @{
                Name = 'Iedereen'
                Sid  = 'S-1-1-0'
            }
            ConvertTo-PortableAccountNameHC @params | Should -Be 'Everyone'

            $params = @{
                Name = 'BUILTIN\Administratoren'
                Sid  = 'S-1-5-32-544'
            }
            ConvertTo-PortableAccountNameHC @params |
                Should -Be 'BUILTIN\Administrators'

            $params = @{
                Name = 'PC1\bob'
                Sid  = 'S-1-5-21-1-2-3-1001'
            }
            ConvertTo-PortableAccountNameHC @params | Should -Be 'PC1\bob'

            $params = @{
                Name = 'NT SERVICE\TrustedInstaller'
                Sid  = 'S-1-5-80-956008885-3418522649-1831038044-' +
                    '1853292631-2271478464'
            }
            ConvertTo-PortableAccountNameHC @params |
                Should -Be 'NT SERVICE\TrustedInstaller'

            $params = @{
                Name = 'APPLICATION PACKAGE AUTHORITY\Some capability'
                Sid  = 'S-1-15-3-1024-1'
            }
            ConvertTo-PortableAccountNameHC @params |
                Should -Be 'S-1-15-3-1024-1'

            ConvertTo-PortableAccountNameHC -Name 'NoSuchAccount8f3a' |
                Should -Be 'NoSuchAccount8f3a'
        }
        It ('finds the SID of an English name, with or without prefix, ' +
            'and of a SID') {
            Get-WellKnownAccountSidHC -Name 'BUILTIN\Administrators' |
                Should -Be 'S-1-5-32-544'
            Get-WellKnownAccountSidHC -Name 'administrators' |
                Should -Be 'S-1-5-32-544'
            Get-WellKnownAccountSidHC -Name 'NT AUTHORITY\SYSTEM' |
                Should -Be 'S-1-5-18'
            Get-WellKnownAccountSidHC -Name 'Everyone' | Should -Be 'S-1-1-0'
            Get-WellKnownAccountSidHC -Name 's-1-5-32-545' |
                Should -Be 'S-1-5-32-545'
            Get-WellKnownAccountSidHC -Name 'kiosk' | Should -BeNullOrEmpty
            Get-WellKnownAccountSidHC -Name 'CONTOSO\Administrators' |
                Should -BeNullOrEmpty
        }
        It ('has a unique, valid SID and English name for every built-in ' +
            'account') {
            $accounts = Get-WellKnownAccountHC
            foreach ($sid in $accounts.Keys) {
                $sid | Should -Match '^S-1-\d+(-\d+)+$'
                Get-WellKnownAccountSidHC -Name $accounts[$sid] |
                    Should -Be $sid -Because $accounts[$sid]
            }
        }
        It ('turns an English name or SID into the account name of this ' +
            'Windows language') {
            $sid = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
            $everyone = $sid.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
            Convert-AccountNameHC -Name 'S-1-1-0' | Should -Be $everyone
            Convert-AccountNameHC -Name 'Everyone' | Should -Be $everyone
            ConvertTo-PortableAccountNameHC -Name $everyone |
                Should -Be 'Everyone'

            $sid = [System.Security.Principal.SecurityIdentifier](
                'S-1-5-32-544'
            )
            $administrators = $sid.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
            Convert-AccountNameHC -Name 'BUILTIN\Administrators' |
                Should -Be $administrators
            Convert-AccountNameHC -Name 'Administrators' |
                Should -Be $administrators
        }
        It 'keeps a SID that this computer does not know' {
            Convert-AccountNameHC -Name 'S-1-5-21-1-2-3-99999' |
                Should -Be 'S-1-5-21-1-2-3-99999'
        }
    }
    Context 'Test-AccountExistsHC' {
        It 'resolves real accounts and rejects unknown ones' {
            # Well-known names differ per Windows language, so use the SID
            $sid = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
            $everyone = $sid.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
            Test-AccountExistsHC -Name $everyone | Should -BeTrue
            Test-AccountExistsHC -Name 'NoSuchAccount8f3a' | Should -BeFalse
        }
    }
}

Describe 'Get-ExportTaskFolderHC' {
    It 'removes duplicate folders regardless of case, keeping the first' {
        $options = @{ TaskPath = @('\HC\', '\hc\', 'HC', 'Vendor') }

        Get-ExportTaskFolderHC -Options $options |
            Should -BeExactly @('\HC\', '\Vendor\')
    }
}