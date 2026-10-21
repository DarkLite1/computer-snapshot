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
		Should -Invoke Set-Acl -Times 2 -Exactly -ParameterFilter { $LiteralPath -eq 'C:\Example' }
	}
}