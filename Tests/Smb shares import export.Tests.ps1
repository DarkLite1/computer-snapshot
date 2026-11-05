#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Scripts\Smb shares import export.ps1"
    Name       = 'Smb shares'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Inline NTFS permissions' {
    BeforeAll {
        $testScript = "$PSScriptRoot\..\Scripts\Smb shares import export.ps1"
        $testModule = "$PSScriptRoot\..\Scripts\Common\Configuration.psm1"
        Import-Module $testModule -Force
        function Test-AccountExistsHC { param($Name) }
    }
    It ('captures explicit permissions and applies them without ' +
        'intermediate JSON') {
        # Use the names of this Windows language; the export stores them by SID
        $everyone = (
            [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        ).Translate([System.Security.Principal.NTAccount]).Value
        $administrators = (
            [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
        ).Translate([System.Security.Principal.NTAccount]).Value

        $testAcl = [pscustomobject]@{
            Owner                   = $administrators
            AreAccessRulesProtected = $true
            ProtectionApplied       = $false
            Access                  = @(
                [pscustomobject]@{
                    IdentityReference = $everyone
                    AccessControlType = 'Allow'
                    FileSystemRights  = 'ReadAndExecute'
                    InheritanceFlags  = 'ContainerInherit, ObjectInherit'
                    PropagationFlags  = 'None'
                    IsInherited       = $false
                }
            )
        }
        $testAcl | Add-Member ScriptMethod RemoveAccessRule {
            param($Rule) return $true
        }
        $testAcl | Add-Member ScriptMethod SetAccessRuleProtection {
            param($Protected, $Preserve)
            $this.ProtectionApplied = $Protected
        }
        $testAcl | Add-Member ScriptMethod SetOwner { param($Owner) }
        $testAcl | Add-Member ScriptMethod AddAccessRule { param($Rule) }

        Mock Get-SmbShare {
            [pscustomobject]@{
                Name                  = 'Example'
                Path                  = 'C:\Example'
                ScopeName             = '*'
                Description           = ''
                CachingMode           = 'Manual'
                SmbInstance           = 'Default'
                FolderEnumerationMode = 'Unrestricted'
                CATimeout             = 0
                EncryptData           = $false
                ThrottleLimit         = 0
                ConcurrentUserLimit   = 0
                ContinuouslyAvailable = $false
            }
        }
        Mock Get-SmbShareAccess
        Mock Test-Path { $true }
        Mock Get-Acl { $testAcl }
        Mock Set-Acl
        Mock Set-SmbShare
        Mock New-SmbShare
        Mock Test-AccountExistsHC { $true }

        $exportResult = . $testScript -Action Export -RootFolder $TestDrive

        $exportResult.Data[0].Name | Should -Be 'Example'
        $exportResult.Data[0].NTFS.Access.Count | Should -Be 1
        $exportResult.Data[0].NTFS.Access[0].IdentityReference |
            Should -Be 'Everyone'
        $exportResult.Data[0].NTFS.Owner | Should -Be 'BUILTIN\Administrators'

        $testConfiguration = @{
            SchemaVersion = 3
            Items         = @{ SmbShares = $exportResult.Data }
        }
        @(Test-ConfigurationHC $testConfiguration $TestDrive).Count |
            Should -Be 0

        $testParams = @{
            Action      = 'Import'
            Data        = $exportResult.Data
            RootFolder  = $TestDrive
            ErrorAction = 'Stop'
        }
        $importResult = . $testScript @testParams

        $importResult.Data | Should -BeNullOrEmpty
        $testAcl.ProtectionApplied | Should -BeTrue
        $importResult.Errors.Count |
            Should -Be 0 -Because ($importResult.Errors -join '; ')
        # The complete ACL is written once, never a stripped intermediate ACL
        Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'C:\Example'
        }
    }
}

Describe 'Smb shares import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Smb shares import export.ps1"
        # Resolve well-known names from their SID, so the tests also pass on
        # Windows in another language ('Everyone' is 'Iedereen' in Dutch)
        $everyone = (
            [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
        ).Translate([System.Security.Principal.NTAccount]).Value
        $users = (
            [System.Security.Principal.SecurityIdentifier]'S-1-5-32-545'
        ).Translate([System.Security.Principal.NTAccount]).Value
        $guests = (
            [System.Security.Principal.SecurityIdentifier]'S-1-5-32-546'
        ).Translate([System.Security.Principal.NTAccount]).Value
    }
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $folder -ItemType Directory

        Mock Get-SmbShare { [pscustomobject]@{ Name = $Name } }
        Mock New-SmbShare
        Mock Set-SmbShare
        Mock Get-SmbShareAccess {
            [pscustomobject]@{
                AccountName       = 'PC\Old'
                AccessControlType = 'Allow'
                AccessRight       = 'Full'
            }
        }
        Mock Grant-SmbShareAccess
        Mock Block-SmbShareAccess
        Mock Revoke-SmbShareAccess
        Mock Unblock-SmbShareAccess
    }
    It 'blocks a Deny entry instead of granting it' {
        $data = @(
            [pscustomobject]@{
                Name   = 'Data'
                Path   = $folder
                Access = @(
                    [pscustomobject]@{
                        AccountName       = $guests
                        AccessControlType = 'Deny'
                        AccessRight       = 'Full'
                    }
                )
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Block-SmbShareAccess -Times 1 -Exactly
        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
    }
    It ('removes unconfigured share permissions once all configured ones ' +
        'are applied') {
        $data = @(
            [pscustomobject]@{
                Name   = 'Data'
                Path   = $folder
                Access = @(
                    [pscustomobject]@{
                        AccountName       = $everyone
                        AccessControlType = 'Allow'
                        AccessRight       = 'Read'
                    }
                )
            }
        )
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive

        $invokeParams = @{
            CommandName     = 'Revoke-SmbShareAccess'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { $AccountName -eq 'PC\Old' }
        }
        Should -Invoke @invokeParams
    }
    It ('keeps existing share permissions when a configured account does ' +
        'not exist') {
        $data = @(
            [pscustomobject]@{
                Name   = 'Data'
                Path   = $folder
                Access = @(
                    [pscustomobject]@{
                        AccountName       = $everyone
                        AccessControlType = 'Allow'
                        AccessRight       = 'Read'
                    }
                    [pscustomobject]@{
                        AccountName       = 'NoSuchAccount8f3a'
                        AccessControlType = 'Allow'
                        AccessRight       = 'Full'
                    }
                )
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count | Should -Be 2
        $result[0].Errors[1] | Should -BeLike (
            "*existing share permissions that are not in the " +
            "configuration were kept*"
        )
        Should -Invoke Grant-SmbShareAccess -Times 1 -Exactly
        Should -Invoke Revoke-SmbShareAccess -Times 0 -Exactly
    }
    It 'leaves share permissions unchanged when none are configured' {
        $data = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive

        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
        Should -Invoke Revoke-SmbShareAccess -Times 0 -Exactly
    }
    It 'skips administrative shares and reports a share without a path' {
        $data = @(
            [pscustomobject]@{ Name = 'IPC$'; Path = '' }
            [pscustomobject]@{ Name = 'NoPath'; Path = '' }
            [pscustomobject]@{ Name = 'Data'; Path = $folder }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages[0] | Should -BeLike "Skipped share 'IPC$'*"
        $result[0].Errors | Should -Be @(
            "Failed to create or update share 'NoPath': the share has no Path"
        )
        Should -Invoke Set-SmbShare -Times 1 -Exactly
    }
    It 'applies configured NTFS permissions' {
        $testNtfsAccess = @(
            [pscustomobject]@{
                IdentityReference = $users
                AccessControlType = 'Allow'
                FileSystemRights  = 'ReadAndExecute'
                InheritanceFlags  = 'ContainerInherit, ObjectInherit'
                PropagationFlags  = 'None'
            }
        )
        $data = @(
            [pscustomobject]@{
                Name = 'Data'
                Path = $folder
                NTFS = [pscustomobject]@{
                    AreAccessRulesProtected = $false
                    Access                  = $testNtfsAccess
                }
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $explicit = @(
            (Get-Acl -LiteralPath $folder).Access |
                Where-Object { -not $_.IsInherited }
        )
        @(
            $explicit |
                Where-Object { [string]$_.IdentityReference -eq $users }
        ).Count | Should -Be 1
    }
    It ('keeps the current NTFS permissions when a configured account ' +
        'does not exist') {
        $before = (Get-Acl -LiteralPath $folder).Sddl
        $data = @(
            [pscustomobject]@{
                Name = 'Data'
                Path = $folder
                NTFS = [pscustomobject]@{
                    AreAccessRulesProtected = $true
                    Access                  = @(
                        [pscustomobject]@{
                            IdentityReference = $users
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'ReadAndExecute'
                            InheritanceFlags  = 'None'
                            PropagationFlags  = 'None'
                        }
                        [pscustomobject]@{
                            IdentityReference = 'NoSuchAccount8f3a'
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'FullControl'
                            InheritanceFlags  = 'None'
                            PropagationFlags  = 'None'
                        }
                    )
                }
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors[-1] |
            Should -BeLike '*the current NTFS permissions were kept*'
        (Get-Acl -LiteralPath $folder).Sddl | Should -BeExactly $before
    }
    It 'does not export administrative shares' {
        Mock Get-SmbShare {
            [pscustomobject]@{
                Name = 'ADMIN$'; Path = 'C:\Windows'; Special = $true
            }
            [pscustomobject]@{ Name = 'C$'; Path = 'C:\'; Special = $true }
            [pscustomobject]@{ Name = 'Data'; Path = $folder; Special = $false }
        }
        Mock Get-SmbShareAccess

        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        @($result[0].Data | ForEach-Object { $_.Name }) |
            Should -Be @('Data')
    }
    It 'configures several shares, each with its own permissions' {
        $second = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $second -ItemType Directory
        $data = @(
            [pscustomobject]@{
                Name   = 'Data'
                Path   = $folder
                Access = @(
                    [pscustomobject]@{
                        AccountName       = $everyone
                        AccessControlType = 'Allow'
                        AccessRight       = 'Read'
                    }
                )
            }
            [pscustomobject]@{
                Name   = 'Scans'
                Path   = $second
                Access = @(
                    [pscustomobject]@{
                        AccountName       = $users
                        AccessControlType = 'Allow'
                        AccessRight       = 'Change'
                    }
                )
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Grant-SmbShareAccess -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Data' -and
            $AccountName -eq $everyone -and
            $AccessRight -eq 'Read'
        }
        Should -Invoke Grant-SmbShareAccess -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Scans' -and
            $AccountName -eq $users -and
            $AccessRight -eq 'Change'
        }
    }
    It 'does nothing for an empty list of shares' {
        $data = @()
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Set-SmbShare -Times 0 -Exactly
    }
}