#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    . "$PSScriptRoot\..\Scripts\Common\Section.ps1"
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
        It 'keeps names without a prefix, built-in and this computer''s accounts' {
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
    Context 'Test-AccountExistsHC' {
        It 'resolves real accounts and rejects unknown ones' {
            # Well-known names differ per Windows language, so use the SID
            $everyone = ([System.Security.Principal.SecurityIdentifier]'S-1-1-0').Translate(
                [System.Security.Principal.NTAccount]
            ).Value
            Test-AccountExistsHC -Name $everyone | Should -BeTrue
            Test-AccountExistsHC -Name 'NoSuchAccount8f3a' | Should -BeFalse
        }
    }
}