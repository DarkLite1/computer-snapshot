param([string]$ScriptPath, [string]$Name, [switch]$EmptyExport)

Describe '<Name> data contract' -ForEach @(
    @{
        ScriptPath  = $ScriptPath
        Name        = $Name
        EmptyExport = [bool]$EmptyExport
    }
) {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot (
            '..\..\Scripts\Common\Configuration.psm1'
        )
        Import-Module $modulePath -Force
        $itemNames = @{
            Folders                = 'CreateFolders'
            'Copy files folders'   = 'CopyFilesFolders'
            'NTP time servers'     = 'NtpTimeServers'
            'Hosts file entries'   = 'HostsFileEntries'
            'Network cards'        = 'NetworkCards'
            'Regional settings'    = 'RegionalSettings'
            'Account policy'       = 'AccountPolicy'
            'Environment variables' = 'EnvironmentVariables'
            Software               = 'Software'
            'User accounts'        = 'UserAccounts'
            'User groups'          = 'UserGroups'
            'Registry keys'        = 'RegistryKeys'
            'Firewall rules'       = 'FirewallRules'
            'Scheduled tasks'      = 'ScheduledTasks'
            'Smb shares'           = 'SmbShares'
            'Start custom scripts' = 'StartCustomScriptsBefore'
        }

        function Get-TimeServerHC {}
        function Set-SynchronizeTimeWithServerHC { param($ComputerName) }
        function Set-SynchronizeTimeWithDomainHC {}
        function Get-InstalledApplicationsHC {}
        function Remove-ApplicationHC {
            param($ApplicationName, $UninstallString, $TimeoutSeconds)
        }
        function Get-HostsFilePathHC {}
        function Wait-ProcessTreeHC { param($Process, $TimeoutSeconds, $What) }
        function Start-ScriptHC { param($Path) }
        function Get-SecurityPolicyHC {}
        function Set-SecurityPolicyHC { param($Values) }
        function Get-EnvironmentVariablesHC { param($Scope) }
        function Set-EnvironmentVariableHC {
            param($Scope, $Name, $Value, $Kind)
        }
        function Send-EnvironmentChangeHC {}
        function Get-NetBiosSettingHC { param($Adapter) }
        function Set-NetBiosSettingHC { param($Adapter, $Setting) }
        function Get-UserLanguageListHC {}
        function Set-UserLanguageListHC { param($Languages) }
        function Get-UILanguageOverrideHC {}
        function Set-UILanguageOverrideHC { param($Language) }
        function Invoke-CustomScriptHC { param($Path, $Arguments) }
        function Get-RegistryKeyStateHC { param($Path, $Name) }
        function Get-NetFirewallAddressFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallPortFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallApplicationFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallServiceFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallInterfaceFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallInterfaceTypeFilter {
            param([switch]$All, $PolicyStore)
        }
        function Get-NetFirewallSecurityFilter {
            param([switch]$All, $PolicyStore)
        }
        function Remove-NetFirewallRule {
            param([Parameter(ValueFromPipeline)]$InputObject)
        }
        function Rename-NetFirewallRule {
            param([Parameter(ValueFromPipeline)]$InputObject, $NewName)
        }
    }
    BeforeEach {
        #region User accounts and groups
        Mock Get-LocalUser {
            [pscustomobject]@{
                Name                  = 'Example'
                FullName              = 'Example'
                Description           = ''
                Enabled               = $true
                UserMayChangePassword = $true
            }
        }
        Mock New-LocalUser { 'command output' }
        Mock Set-LocalUser
        Mock Enable-LocalUser
        Mock Disable-LocalUser
        Mock Remove-LocalUser
        Mock Read-Host { 'n' }
        Mock Get-LocalGroup {
            [pscustomobject]@{ Name = 'Example'; Description = 'Example' }
        }
        Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'Everyone' } }
        Mock New-LocalGroup
        Mock Set-LocalGroup
        Mock Add-LocalGroupMember
        #endregion

        #region Network
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Old'
                InterfaceDescription = 'Example'
                InterfaceIndex       = 1
            }
        }
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex           = 1
                ConnectionSpecificSuffix = 'old'
            }
        }
        Mock Get-NetConnectionProfile {
            [pscustomobject]@{
                InterfaceAlias  = 'Old'
                InterfaceIndex  = 1
                NetworkCategory = 'Public'
            }
        }
        Mock Rename-NetAdapter
        Mock Get-HostsFilePathHC { Join-Path $TestDrive 'hosts' }
        Mock Clear-DnsClientCache
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = 'Enabled' } }
        Mock Get-NetIPAddress
        Mock Get-NetRoute
        Mock Set-DnsClient
        Mock Set-NetConnectionProfile
        Mock Get-NetBiosSettingHC { 'Default' }
        Mock Set-NetBiosSettingHC
        Mock Get-NetAdapterBinding { [pscustomobject]@{ Enabled = $true } }
        Mock Enable-NetAdapterBinding
        Mock Disable-NetAdapterBinding
        #endregion

        #region Time and regional settings
        Mock Get-TimeServerHC {
            [pscustomobject]@{ Type = 'NT5DS'; TimeServer = 'server' }
        }
        Mock Set-SynchronizeTimeWithServerHC
        Mock Set-SynchronizeTimeWithDomainHC
        Mock Restart-Service
        Mock w32tm { $global:LASTEXITCODE = 0 }
        Mock Get-WinSystemLocale { [pscustomobject]@{ Name = 'en-US' } }
        Mock Get-TimeZone { [pscustomobject]@{ Id = 'UTC' } }
        Mock Get-WinHomeLocation { [pscustomobject]@{ GeoId = 21 } }
        Mock Get-Culture { [pscustomobject]@{ Name = 'en-US' } }
        Mock Set-WinSystemLocale
        Mock Set-TimeZone
        Mock Set-WinHomeLocation
        Mock Set-Culture
        Mock Get-UserLanguageListHC {
            [pscustomobject]@{
                LanguageTag     = 'en-US'
                InputMethodTips = @('0409:00000409')
            }
        }
        Mock Get-UILanguageOverrideHC
        Mock Set-UserLanguageListHC
        Mock Set-UILanguageOverrideHC
        Mock Start-ScriptHC
        $fakePolicy = @{ MinimumPasswordLength = 8; PasswordComplexity = 1 }
        Mock Get-SecurityPolicyHC { $fakePolicy.Clone() }
        Mock Set-SecurityPolicyHC {
            foreach ($key in $Values.Keys) { $fakePolicy[$key] = $Values[$key] }
        }
        Mock Get-EnvironmentVariablesHC {
            [pscustomobject]@{
                Name  = 'EXAMPLE_HOME'
                Value = 'C:\Example'
                Kind  = 'String'
            }
        }
        Mock Set-EnvironmentVariableHC
        Mock Send-EnvironmentChangeHC
        #endregion

        #region Scheduled tasks
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'Example'
                TaskPath = '\HC\'
                Settings = @{ Enabled = $true }
            }
        }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Register-ScheduledTask { 'command output' }
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
        #endregion

        #region Firewall rules
        Mock Get-NetFirewallRule {
            [pscustomobject]@{
                Name        = 'Example'
                InstanceID  = 'Example'
                DisplayName = 'Example'
                Direction   = 'Inbound'
                Enabled     = 'True'
                Action      = 'Allow'
            }
        }
        # The export reads each filter type once, for every rule
        foreach ($type in @(
                'Address', 'Service', 'Interface', 'InterfaceType', 'Security'
            )) {
            Mock "Get-NetFirewall${type}Filter" {
                [pscustomobject]@{ InstanceID = 'Example' }
            }
        }
        Mock Get-NetFirewallPortFilter {
            [pscustomobject]@{ InstanceID = 'Example'; Protocol = 'TCP' }
        }
        Mock Get-NetFirewallApplicationFilter {
            [pscustomobject]@{ InstanceID = 'Example'; Program = 'Any' }
        }
        Mock New-NetFirewallRule
        Mock Remove-NetFirewallRule
        Mock Rename-NetFirewallRule
        #endregion

        #region Smb shares
        Mock Get-SmbShare {
            [pscustomobject]@{ Name = 'Example'; Path = ''; Description = '' }
        }
        Mock Get-SmbShareAccess
        Mock New-SmbShare
        Mock Set-SmbShare
        Mock Revoke-SmbShareAccess
        Mock Grant-SmbShareAccess
        Mock Block-SmbShareAccess
        Mock Unblock-SmbShareAccess
        #endregion

        #region Files, registry and software
        Mock Get-Item { [pscustomobject]@{ PSIsContainer = $false } }
        Mock Test-Path { $true }
        Mock New-Item { 'command output' }
        Mock Copy-Item
        Mock Get-ItemProperty { [pscustomobject]@{ Example = 'old' } }
        Mock Get-RegistryKeyStateHC {
            [pscustomobject]@{
                KeyExists   = $true
                ValueNames  = @('Example')
                SubKeyNames = @()
                ValueExists = $Name -eq 'Example'
                Value       = 'old'
                Kind        = 'String'
            }
        }
        Mock New-ItemProperty
        Mock Get-InstalledApplicationsHC
        Mock Remove-ApplicationHC
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Wait-ProcessTreeHC { [int]$Process.ExitCode }
        Mock Convert-Path { Join-Path $TestDrive 'example.exe' }
        Mock Invoke-CustomScriptHC { 'Custom script output' }
        #endregion
    }
    It ('exports one result with data and string messages without ' +
        'writing files') {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse).FullName
        $result = @(. $ScriptPath -Action Export -RootFolder $TestDrive)
        $result.Count | Should -Be 1
        $result[0].PSObject.Properties.Name | Should -Contain 'Data'
        if ($EmptyExport) {
            # Sections that cannot be read from a computer export their
            # empty value: an empty list or an empty object
            Test-EmptySectionHC $result[0].Data | Should -BeTrue
            $null -eq $result[0].Data | Should -BeFalse
        }
        else {
            $result[0].Data | Should -Not -BeNullOrEmpty
        }
        $result[0].Messages.GetType() | Should -Be ([string[]])
        $result[0].Errors.GetType() | Should -Be ([string[]])
        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')

        $configuration = @{
            SchemaVersion = 3
            Items         = @{ $itemNames[$Name] = $result[0].Data }
        }
        $problems = @(Test-ConfigurationHC $configuration $TestDrive)
        $unexpected = @(
            $problems | Where-Object { $_ -notmatch "file '.+' not found" }
        )
        $unexpected.Count | Should -Be 0 -Because ($problems -join '; ')

        @(Get-ChildItem -LiteralPath $TestDrive -Recurse).FullName |
            Should -Be $before
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Copy-Item -Times 0 -Exactly
    }
    It 'returns one result for an empty import without applying anything' {
        $result = @(
            . $ScriptPath -Action Import -Data @() -RootFolder $TestDrive
        )
        $result.Count | Should -Be 1
        $result[0].Data | Should -BeNullOrEmpty
        $result[0].Messages | Should -Contain 'Nothing to do'
        $result[0].Errors.GetType() | Should -Be ([string[]])
        $result[0].Errors.Count | Should -Be 0
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 0 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
    It 'applies section data through the existing Windows operations' {
        $command = $null
        switch ($Name) {
            'Folders' {
                $data = [pscustomobject]@{ FolderPaths = @('C:\Example') }
                Mock Test-Path { $false }
                $command = 'New-Item'
            }
            'Copy files folders' {
                $data = @(
                    [pscustomobject]@{
                        From = 'Files\example.ps1'
                        To   = 'C:\Example\file.ps1'
                    }
                )
                $command = 'Copy-Item'
            }
            'NTP time servers' {
                $data = [pscustomobject]@{ SyncTimeWithDomain = $true }
                $command = 'Restart-Service'
            }
            'Network cards' {
                $data = @(
                    [pscustomobject]@{
                        FindBy = [pscustomobject]@{ Description = 'Example' }
                        Change = [pscustomobject]@{
                            NewName         = 'New'
                            NetworkCategory = 'Private'
                            DnsSuffix       = 'new'
                        }
                    }
                )
                $command = 'Rename-NetAdapter'
            }
            'Hosts file entries' {
                $data = @(
                    [pscustomobject]@{
                        IPAddress = '192.0.2.10'
                        Hostnames = @('server01')
                    }
                )
                $command = 'Clear-DnsClientCache'
            }
            'Regional settings' {
                $data = [pscustomobject]@{
                    WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'UTC'
                    WinHomeLocationGeoId = 21
                    CultureName          = 'en-US'
                }
                $command = 'Start-ScriptHC'
            }
            'Account policy' {
                $data = [pscustomobject]@{ MinimumPasswordLength = 12 }
                $command = 'Set-SecurityPolicyHC'
            }
            'Environment variables' {
                $data = @(
                    [pscustomobject]@{
                        Name  = 'EXAMPLE_HOME'
                        Value = 'C:\New'
                    }
                )
                $command = 'Set-EnvironmentVariableHC'
            }
            'User accounts' {
                $data = @(
                    [pscustomobject]@{
                        Name                  = 'Example'
                        FullName              = 'Example'
                        Description           = ''
                        Enabled               = $true
                        UserMayChangePassword = $true
                        Password              = 'Example-only'
                    }
                )
                $command = 'Set-LocalUser'
            }
            'User groups' {
                $data = @(
                    [pscustomobject]@{
                        Name        = 'Example'
                        Description = 'Example'
                        Members     = @('Everyone')
                    }
                )
                $command = 'Add-LocalGroupMember'
            }
            'Registry keys' {
                $data = [pscustomobject]@{
                    RunAsCurrentUser = @{
                        RegistryKeys = @(
                            @{
                                Path  = 'HKCU:\Example'
                                Name  = 'Example'
                                Value = 'new'
                                Type  = 'String'
                            }
                        )
                    }
                    RunAsOtherUser   = @()
                }
                $command = 'New-ItemProperty'
            }
            'Software' {
                $data = [pscustomobject]@{
                    Remove  = @()
                    Install = @(
                        @{
                            ExecutablePath = 'Software\example.exe'
                            Arguments      = '/S'
                        }
                    )
                }
                $command = 'Start-Process'
            }
            'Start custom scripts' {
                $data = @(
                    [pscustomobject]@{
                        Path      = 'Files\example.ps1'
                        Arguments = [pscustomobject]@{ Value = 'Example' }
                    }
                )
                $command = 'Invoke-CustomScriptHC'
            }
            'Scheduled tasks' {
                $data = @(
                    [pscustomobject]@{
                        TaskName = 'Example'
                        TaskPath = '\HC\'
                        Enabled  = $false
                        Xml      = '<Task/>'
                    }
                )
                $command = 'Disable-ScheduledTask'
            }
            'Firewall rules' {
                $data = @(
                    [pscustomobject]@{
                        Name                = 'Example'
                        DisplayName         = 'Example'
                        Enabled             = $true
                        Direction           = 'Inbound'
                        Action              = 'Allow'
                        Protocol            = 'TCP'
                        Profile             = 'Any'
                        DynamicTarget       = 'Any'
                        EdgeTraversalPolicy = 'Block'
                        InterfaceType       = 'Any'
                        Authentication      = 'NotRequired'
                        Encryption          = 'NotRequired'
                    }
                )
                $command = 'New-NetFirewallRule'
            }
            'Smb shares' {
                $data = @(
                    [pscustomobject]@{
                        Name   = 'Example'
                        Path   = 'C:\Example'
                        Access = @()
                    }
                )
                $command = 'Set-SmbShare'
            }
        }
        $importParams = @{
            Action      = 'Import'
            Data        = $data
            RootFolder  = $TestDrive
            ErrorAction = 'Stop'
        }
        $result = @(. $ScriptPath @importParams)
        $result.Count | Should -Be 1
        $result[0].Data | Should -BeNullOrEmpty
        $result[0].Errors.GetType() | Should -Be ([string[]])
        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke $command -Times 1
    }
}