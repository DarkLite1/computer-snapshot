#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Smb shares import export.ps1" -Name 'Smb shares'

Describe 'Inline NTFS permissions' {
	BeforeAll {
		$testScript = "$PSScriptRoot\..\Scripts\Smb shares import export.ps1"
		Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
		function Test-AccountExistsHC { param($Name) }
	}
	It 'captures explicit permissions and applies them without intermediate JSON' {
		$testAcl = [pscustomobject]@{
			Owner = 'BUILTIN\Administrators'; AreAccessRulesProtected = $true; ProtectionApplied = $false
			Access = @([pscustomobject]@{
				IdentityReference = 'Everyone'; AccessControlType = 'Allow'; FileSystemRights = 'ReadAndExecute'
				InheritanceFlags = 'ContainerInherit, ObjectInherit'; PropagationFlags = 'None'; IsInherited = $false
			})
		}
		$testAcl | Add-Member ScriptMethod RemoveAccessRule { param($Rule) return $true }
		$testAcl | Add-Member ScriptMethod SetAccessRuleProtection { param($Protected, $Preserve) $this.ProtectionApplied = $Protected }
		$testAcl | Add-Member ScriptMethod SetOwner { param($Owner) }
		$testAcl | Add-Member ScriptMethod AddAccessRule { param($Rule) }
		Mock Get-SmbShare { [pscustomobject]@{
			Name = 'Example'; Path = 'C:\Example'; ScopeName = '*'; Description = ''
			CachingMode = 'Manual'; SmbInstance = 'Default'; FolderEnumerationMode = 'Unrestricted'
			CATimeout = 0; EncryptData = $false; ThrottleLimit = 0; ConcurrentUserLimit = 0; ContinuouslyAvailable = $false
		} }
		Mock Get-SmbShareAccess
		Mock Test-Path { $true }
		Mock Get-Acl { $testAcl }
		Mock Set-Acl
		Mock Set-SmbShare
		Mock New-SmbShare
		Mock Test-AccountExistsHC { $true }
		$exportResult = . $testScript -Action Export -RootFolder $TestDrive
		$exportResult.Data.NTFS[0].Access.Count | Should -Be 1
		$exportResult.Data.NTFS[0].Access[0].IdentityReference | Should -Be 'Everyone'
		@(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ SmbShares = $exportResult.Data } } $TestDrive).Count | Should -Be 0
		$importResult = . $testScript -Action Import -Data $exportResult.Data -RootFolder $TestDrive -ErrorAction Stop
		$importResult.Data | Should -BeNullOrEmpty
		$testAcl.ProtectionApplied | Should -BeTrue
		$importResult.Errors.Count | Should -Be 0 -Because ($importResult.Errors -join '; ')
		# The complete ACL is written once, never a stripped intermediate ACL
		Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'C:\Example' }
	}
}
Describe 'Smb shares import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Smb shares import export.ps1"
        # Resolve well-known names from their SID, so the tests also pass on
        # Windows in another language ('Everyone' is 'Iedereen' in Dutch)
        $everyone = ([System.Security.Principal.SecurityIdentifier]'S-1-1-0').Translate([System.Security.Principal.NTAccount]).Value
        $users = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([System.Security.Principal.NTAccount]).Value
        $guests = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-546').Translate([System.Security.Principal.NTAccount]).Value
    }
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $folder -ItemType Directory
        Mock Get-SmbShare { [pscustomobject]@{ Name = $Name } }
        Mock New-SmbShare
        Mock Set-SmbShare
        Mock Get-SmbShareAccess { [pscustomobject]@{ AccountName = 'PC\Old'; AccessControlType = 'Allow'; AccessRight = 'Full' } }
        Mock Grant-SmbShareAccess
        Mock Block-SmbShareAccess
        Mock Revoke-SmbShareAccess
        Mock Unblock-SmbShareAccess
    }
    It 'blocks a Deny entry instead of granting it' {
        $data = [pscustomobject]@{
            Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
            Access = @([pscustomobject]@{ Name = 'Data'; AccountName = $guests; AccessControlType = 'Deny'; AccessRight = 'Full' })
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Block-SmbShareAccess -Times 1 -Exactly
        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
    }
    It 'removes unconfigured share permissions once all configured ones are applied' {
        $data = [pscustomobject]@{
            Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
            Access = @([pscustomobject]@{ Name = 'Data'; AccountName = $everyone; AccessControlType = 'Allow'; AccessRight = 'Read' })
        }
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Revoke-SmbShareAccess -Times 1 -Exactly -ParameterFilter { $AccountName -eq 'PC\Old' }
    }
    It 'keeps existing share permissions when a configured account does not exist' {
        $data = [pscustomobject]@{
            Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
            Access = @(
                [pscustomobject]@{ Name = 'Data'; AccountName = $everyone; AccessControlType = 'Allow'; AccessRight = 'Read' }
                [pscustomobject]@{ Name = 'Data'; AccountName = 'NoSuchAccount8f3a'; AccessControlType = 'Allow'; AccessRight = 'Full' }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 2
        $result[0].Errors[1] | Should -BeLike "*existing share permissions that are not in the configuration were kept*"
        Should -Invoke Grant-SmbShareAccess -Times 1 -Exactly
        Should -Invoke Revoke-SmbShareAccess -Times 0 -Exactly
    }
    It 'leaves share permissions unchanged when none are configured' {
        $data = [pscustomobject]@{ Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder }) }
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
        Should -Invoke Revoke-SmbShareAccess -Times 0 -Exactly
    }
    It 'skips administrative shares and reports a share without a path' {
        $data = [pscustomobject]@{ Shares = @(
                [pscustomobject]@{ Name = 'IPC$'; Path = '' }
                [pscustomobject]@{ Name = 'NoPath'; Path = '' }
                [pscustomobject]@{ Name = 'Data'; Path = $folder }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages[0] | Should -BeLike "Skipped share 'IPC$'*"
        $result[0].Errors | Should -Be @("Failed to create or update share 'NoPath': the share has no Path")
        Should -Invoke Set-SmbShare -Times 1 -Exactly
    }
    It 'applies configured NTFS permissions' {
        $data = [pscustomobject]@{
            Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
            NTFS   = @([pscustomobject]@{ Name = 'Data'; AreAccessRulesProtected = $false; Access = @(
                        [pscustomobject]@{ IdentityReference = $users; AccessControlType = 'Allow'; FileSystemRights = 'ReadAndExecute'; InheritanceFlags = 'ContainerInherit, ObjectInherit'; PropagationFlags = 'None' }
                    )
                })
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $explicit = @((Get-Acl -LiteralPath $folder).Access | Where-Object { -not $_.IsInherited })
        @($explicit | Where-Object { [string]$_.IdentityReference -eq $users }).Count | Should -Be 1
    }
    It 'keeps the current NTFS permissions when a configured account does not exist' {
        $before = (Get-Acl -LiteralPath $folder).Sddl
        $data = [pscustomobject]@{
            Shares = @([pscustomobject]@{ Name = 'Data'; Path = $folder })
            NTFS   = @([pscustomobject]@{ Name = 'Data'; AreAccessRulesProtected = $true; Access = @(
                        [pscustomobject]@{ IdentityReference = $users; AccessControlType = 'Allow'; FileSystemRights = 'ReadAndExecute'; InheritanceFlags = 'None'; PropagationFlags = 'None' }
                        [pscustomobject]@{ IdentityReference = 'NoSuchAccount8f3a'; AccessControlType = 'Allow'; FileSystemRights = 'FullControl'; InheritanceFlags = 'None'; PropagationFlags = 'None' }
                    )
                })
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[-1] | Should -BeLike '*the current NTFS permissions were kept*'
        (Get-Acl -LiteralPath $folder).Sddl | Should -BeExactly $before
    }
    It 'does not export administrative shares' {
        Mock Get-SmbShare {
            [pscustomobject]@{ Name = 'ADMIN$'; Path = 'C:\Windows'; Special = $true }
            [pscustomobject]@{ Name = 'C$'; Path = 'C:\'; Special = $true }
            [pscustomobject]@{ Name = 'Data'; Path = $folder; Special = $false }
        }
        Mock Get-SmbShareAccess
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        @($result[0].Data.Shares.Name) | Should -Be @('Data')
    }
    It 'does nothing for a configuration without a Shares list' {
        $data = [pscustomobject]@{ NTFS = @() ; Access = @() }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Set-SmbShare -Times 0 -Exactly
    }
}