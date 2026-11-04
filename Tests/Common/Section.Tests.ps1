#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\..\Scripts\Common\Section.ps1"
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
        It ('keeps names without a prefix, built-in and ' +
            'this computer''s accounts') {
            foreach ($name in @(
                    'Everyone'
                    'BUILTIN\Users'
                    'NT AUTHORITY\SYSTEM'
                    'NT SERVICE\TrustedInstaller'
                    "$env:COMPUTERNAME\alice"
                )) {
                Convert-AccountNameHC -Name $name | Should -Be $name
            }
            Should -Invoke Test-AccountExistsHC -Times 0 -Exactly
        }
    }
    Context 'Accounts stored by SID' {
        It ('exports a built-in account by SID and a local or domain ' +
            'account by name') {
            $params = @{
                Name = 'NT AUTHORITY\Iedereen'
                Sid  = 'S-1-1-0'
            }
            ConvertTo-PortableAccountNameHC @params | Should -Be 'S-1-1-0'

            $params = @{
                Name = 'PC1\bob'
                Sid  = 'S-1-5-21-1-2-3-1001'
            }
            ConvertTo-PortableAccountNameHC @params | Should -Be 'PC1\bob'

            ConvertTo-PortableAccountNameHC -Name 'NoSuchAccount8f3a' |
                Should -Be 'NoSuchAccount8f3a'
        }
        It 'turns a SID into the account name of this Windows language' {
            $sid = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
            $everyone = $sid.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
            Convert-AccountNameHC -Name 'S-1-1-0' | Should -Be $everyone
            ConvertTo-PortableAccountNameHC -Name $everyone |
                Should -Be 'S-1-1-0'
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