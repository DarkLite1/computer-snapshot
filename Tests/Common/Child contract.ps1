param([string]$ScriptPath, [string]$Name)

Describe '<Name> data contract' -ForEach @(@{ ScriptPath = $ScriptPath; Name = $Name }) {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\..\Scripts\Common\Configuration.psm1" -Force
        $itemNames = @{
            Folders = 'CreateFolders'; 'Copy files folders' = 'CopyFilesFolders'; 'NTP time servers' = 'NtpTimeServers'
            'Network cards' = 'NetworkCards'; 'Regional settings' = 'RegionalSettings'; Software = 'Software'
            'User accounts' = 'UserAccounts'; 'User groups' = 'UserGroups'; 'Registry keys' = 'RegistryKeys'
            'Firewall rules' = 'FirewallRules'; 'Scheduled tasks' = 'ScheduledTasks'; 'Smb shares' = 'SmbShares'
            'Start custom scripts' = 'StartCustomScriptsBefore'
        }
        function Get-TimeServerHC {}
        function Set-SynchronizeTimeWithServerHC { param($ComputerName) }
        function Set-SynchronizeTimeWithDomainHC {}
        function Get-InstalledApplicationsHC {}
        function Remove-ApplicationHC { param($ApplicationName, $UninstallString) }
        function Start-ScriptHC { param($Path) }
        function Invoke-CustomScriptHC { param($Path, $Arguments) }
        function Get-NetFirewallAddressFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallPortFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallApplicationFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallServiceFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallInterfaceFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallInterfaceTypeFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Get-NetFirewallSecurityFilter { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject) }
    }
    BeforeEach {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'Example'; FullName = 'Example'; Description = ''; Enabled = $true; UserMayChangePassword = $true } }
        Mock New-LocalUser { 'command output' }
        Mock Set-LocalUser
        Mock Enable-LocalUser
        Mock Disable-LocalUser
        Mock Remove-LocalUser
        Mock Read-Host { 'n' }
        Mock Get-LocalGroup { [pscustomobject]@{ Name = 'Example'; Description = 'Example' } }
        Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'Everyone' } }
        Mock New-LocalGroup
        Mock Set-LocalGroup
        Mock Add-LocalGroupMember
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'Old'; InterfaceDescription = 'Example'; InterfaceIndex = 1 } }
        Mock Get-DnsClient { [pscustomobject]@{ InterfaceIndex = 1; ConnectionSpecificSuffix = 'old' } }
        Mock Get-NetConnectionProfile { [pscustomobject]@{ InterfaceAlias = 'New'; InterfaceIndex = 1; NetworkCategory = 'Public' } }
        Mock Rename-NetAdapter
        Mock Set-DnsClient
        Mock Set-NetConnectionProfile
        Mock Get-TimeServerHC { [pscustomobject]@{ Type = 'NT5DS'; TimeServer = 'server' } }
        Mock Set-SynchronizeTimeWithServerHC
        Mock Set-SynchronizeTimeWithDomainHC
        Mock Restart-Service
        Mock w32tm
        Mock Get-WinSystemLocale { [pscustomobject]@{ Name = 'en-US' } }
        Mock Get-TimeZone { [pscustomobject]@{ Id = 'UTC' } }
        Mock Get-WinHomeLocation { [pscustomobject]@{ GeoId = 21 } }
        Mock Get-Culture { [pscustomobject]@{ Name = 'en-US' } }
        Mock Set-WinSystemLocale
        Mock Set-TimeZone
        Mock Set-WinHomeLocation
        Mock Set-Culture
        Mock Start-ScriptHC
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Example'; TaskPath = '\HC\'; Settings = @{ Enabled = $true } } }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Register-ScheduledTask { 'command output' }
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = 'Example'; DisplayName = 'Example'; Direction = 'Inbound'; Enabled = 'True'; Action = 'Allow' } }
        Mock Get-NetFirewallAddressFilter
        Mock Get-NetFirewallPortFilter { [pscustomobject]@{ Protocol = 'TCP' } }
        Mock Get-NetFirewallApplicationFilter { [pscustomobject]@{ Program = 'Any' } }
        Mock Get-NetFirewallServiceFilter
        Mock Get-NetFirewallInterfaceFilter
        Mock Get-NetFirewallInterfaceTypeFilter
        Mock Get-NetFirewallSecurityFilter
        Mock New-NetFirewallRule
        Mock Remove-NetFirewallRule
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Example'; Path = ''; Description = '' } }
        Mock Get-SmbShareAccess
        Mock New-SmbShare
        Mock Set-SmbShare
        Mock Revoke-SmbShareAccess
        Mock Grant-SmbShareAccess
        Mock Get-Item { [pscustomobject]@{ PSIsContainer = $false } }
        Mock Test-Path { $true }
        Mock New-Item { 'command output' }
        Mock Copy-Item
        Mock Get-ItemProperty { [pscustomobject]@{ Example = 'old' } }
        Mock New-ItemProperty
        Mock Get-InstalledApplicationsHC
        Mock Remove-ApplicationHC
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Convert-Path { Join-Path $TestDrive 'example.exe' }
        Mock Invoke-CustomScriptHC { 'Custom script output' }
    }
    It 'exports one result with data and string messages without writing files' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse).FullName
        $result = @(. $ScriptPath -Action Export -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].PSObject.Properties.Name | Should -Contain 'Data'
        $result[0].Data | Should -Not -BeNullOrEmpty
        $result[0].Messages.GetType() | Should -Be ([string[]])
        $problems = @(Test-ConfigurationHC @{ SchemaVersion = 2; Items = @{ $itemNames[$Name] = $result[0].Data } } $TestDrive)
        @($problems | Where-Object { $_ -notmatch "file '.+' not found" }).Count | Should -Be 0 -Because ($problems -join '; ')
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse).FullName | Should -Be $before
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Copy-Item -Times 0 -Exactly
    }
    It 'returns one result for an empty import without applying anything' {
        $result = @(. $ScriptPath -Action Import -Data @() -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].Data | Should -BeNullOrEmpty
        $result[0].Messages | Should -Contain 'Nothing to do'
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 0 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
    It 'applies section data through the existing Windows operations' {
        $command = $null
        switch ($Name) {
            'Folders' { $data = [pscustomobject]@{ FolderPaths = @('C:\Example') }; Mock Test-Path { $false }; $command = 'New-Item' }
            'Copy files folders' { $data = @([pscustomobject]@{ From = 'Files\example.ps1'; To = 'C:\Example\file.ps1' }); $command = 'Copy-Item' }
            'NTP time servers' { $data = [pscustomobject]@{ SyncTimeWithDomain = $true }; $command = 'Restart-Service' }
            'Network cards' { $data = @([pscustomobject]@{ NetworkCardName = 'New'; NetworkCardDescription = 'Example'; NetworkCategory = 'Private'; NetworkCardDnsSuffix = 'new' }); $command = 'Rename-NetAdapter' }
            'Regional settings' { $data = [pscustomobject]@{ WinSystemLocaleName = 'en-US'; TimeZoneId = 'UTC'; WinHomeLocationGeoId = 21; CultureName = 'en-US' }; $command = 'Start-ScriptHC' }
            'User accounts' { $data = @([pscustomobject]@{ Name = 'Example'; FullName = 'Example'; Description = ''; Enabled = $true; UserMayChangePassword = $true; Password = 'Example-only' }); $command = 'Set-LocalUser' }
            'User groups' { $data = @([pscustomobject]@{ Name = 'Example'; Description = 'Example'; Members = @('Everyone') }); $command = 'Add-LocalGroupMember' }
            'Registry keys' { $data = [pscustomobject]@{ RunAsCurrentUser = @{ RegistryKeys = @(@{ Path = 'HKCU:\Example'; Name = 'Example'; Value = 'new'; Type = 'String' }) }; RunAsOtherUser = @() }; $command = 'New-ItemProperty' }
            'Software' { $data = [pscustomobject]@{ Remove = @(); Install = @(@{ ExecutablePath = 'Software\example.exe'; Arguments = '/S' }) }; $command = 'Start-Process' }
            'Start custom scripts' { $data = @([pscustomobject]@{ Path = 'Files\example.ps1'; Arguments = [pscustomobject]@{ Value = 'Example' } }); $command = 'Invoke-CustomScriptHC' }
            'Scheduled tasks' { $data = @([pscustomobject]@{ TaskName = 'Example'; TaskPath = '\HC\'; Enabled = $false; Xml = '<Task/>' }); $command = 'Disable-ScheduledTask' }
            'Firewall rules' { $data = @([pscustomobject]@{ Name = 'Example'; DisplayName = 'Example'; Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; Profile = 'Any'; DynamicTarget = 'Any'; EdgeTraversalPolicy = 'Block'; InterfaceType = 'Any'; Authentication = 'NotRequired'; Encryption = 'NotRequired' }); $command = 'New-NetFirewallRule' }
            'Smb shares' { $data = [pscustomobject]@{ Shares = @([pscustomobject]@{ Name = 'Example'; Path = 'C:\Example' }); Access = @(); NTFS = @() }; $command = 'Set-SmbShare' }
        }
        $result = @(. $ScriptPath -Action Import -Data $data -RootFolder $TestDrive -ErrorAction Stop)
        $result.Count | Should -Be 1
        $result[0].Data | Should -BeNullOrEmpty
        Should -Invoke $command -Times 1
    }
}