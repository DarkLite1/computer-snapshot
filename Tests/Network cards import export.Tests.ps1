#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Network cards import export.ps1" -Name 'Network cards'

Describe 'Network profile restoration' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Network cards import export.ps1"
    }
    BeforeEach {
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'Old'; InterfaceDescription = 'Example'; InterfaceIndex = 1 } }
        Mock Get-DnsClient { [pscustomobject]@{ InterfaceIndex = 1; ConnectionSpecificSuffix = '' } }
        Mock Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Old'; InterfaceIndex = 1; NetworkCategory = 'Public' }
            [pscustomobject]@{ InterfaceAlias = 'New'; InterfaceIndex = 2; NetworkCategory = 'Public' }
        }
        Mock Rename-NetAdapter
        Mock Set-NetConnectionProfile
        Mock Set-DnsClient
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Example' }; Change = [pscustomobject]@{ NewName = 'New'; NetworkCategory = 'Private' } })
    }
    It 'changes the matched adapter profile after a rename without touching a different interface' {
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Old' -and $NewName -eq 'New' }
        Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 -and $NetworkCategory -eq 'Private' }
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly -ParameterFilter { $InterfaceIndex -eq 2 }
        $result.Messages -join ';' | Should -Match 'Changed network category'
    }
    It 'changes category when retaining the existing adapter name' {
        $data[0].Change.NewName = ''
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
        Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 }
    }
    It 'does not reapply an already correct category' {
        $data[0].Change.NetworkCategory = 'Public'
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }
    It 'stops applying settings for the card when renaming fails' {
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue 'new.example'
        Mock Rename-NetAdapter { Write-Error 'Rename failed' }
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to configure network card 'New': Rename failed")
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'surfaces a failed profile update' {
        Mock Set-NetConnectionProfile { Write-Error 'Profile update failed' }
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to configure network card 'New': Profile update failed")
    }
    It 'clears an existing suffix when an empty string is explicitly supplied' {
        Mock Get-DnsClient { [pscustomobject]@{ InterfaceIndex = 1; ConnectionSpecificSuffix = 'old.example' } }
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue ''
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 1 -and $ConnectionSpecificSuffix -ceq ''
        }
    }
    It 'leaves an omitted suffix unchanged' {
        Mock Get-DnsClient { [pscustomobject]@{ InterfaceIndex = 1; ConnectionSpecificSuffix = 'old.example' } }
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'leaves a null suffix unchanged' {
        Mock Get-DnsClient { [pscustomobject]@{ InterfaceIndex = 1; ConnectionSpecificSuffix = 'old.example' } }
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue $null
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'does not reapply an already empty suffix' {
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue ''
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'applies a nonempty suffix to the matched interface' {
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue 'new.example'
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 -and $ConnectionSpecificSuffix -eq 'new.example' }
    }
    It 'surfaces a failed suffix update' {
        $data[0].Change | Add-Member -NotePropertyName DnsSuffix -NotePropertyValue 'new.example'
        Mock Set-DnsClient { Write-Error 'DNS suffix update failed' }
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to configure network card 'New': DNS suffix update failed")
    }
    It 'reports a card that is not found and still configures the next card' {
        $data = @(
            [pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Broadcom' }; Change = [pscustomobject]@{ NewName = 'Factory' } }
            $data[0]
        )
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to configure network card 'Factory': no network card found with a description containing 'Broadcom'")
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $NewName -eq 'New' }
    }
    It 'prefers an exact description over cards that only contain it' {
        Mock Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet'; InterfaceIndex = 1 }
            [pscustomobject]@{ Name = 'Ethernet 2'; InterfaceDescription = 'Intel(R) Ethernet #2'; InterfaceIndex = 2 }
        }
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Intel(R) Ethernet' }; Change = [pscustomobject]@{ NewName = 'LAN' } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Ethernet' -and $NewName -eq 'LAN' }
    }
    It 'refuses a partial description that matches several cards' {
        Mock Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet'; InterfaceIndex = 1 }
            [pscustomobject]@{ Name = 'Ethernet 2'; InterfaceDescription = 'Intel(R) Ethernet #2'; InterfaceIndex = 2 }
        }
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Intel' }; Change = [pscustomobject]@{ NewName = 'LAN' } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors[0] | Should -BeLike "*2 network cards match the description 'Intel'*use the full description"
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
    }
    It 'reports an already correct card' {
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Example' }; Change = [pscustomobject]@{ NewName = 'Old'; NetworkCategory = 'Public' } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Messages | Should -Be @("Network card 'Old' is already correct")
    }
    It 'reports a configured category for a card without a network connection' {
        Mock Get-NetConnectionProfile { }
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0
        $result.Messages | Should -Contain "Network card 'New' has no network connection, its network category 'Private' was not set"
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }
}

Describe 'Finding the card and IPv4 settings' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Network cards import export.ps1"
    }
    BeforeEach {
        Mock Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet'; InterfaceIndex = 7; InterfaceGuid = '{GUID-7}' }
            [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Wireless'; InterfaceIndex = 8; InterfaceGuid = '{GUID-8}' }
        }
        Mock Get-DnsClient
        Mock Get-NetConnectionProfile
        $fakeIPv4 = @{
            Dhcp       = 'Enabled'
            Addresses  = @([pscustomobject]@{ IPAddress = '192.168.1.50'; PrefixLength = 24; PrefixOrigin = 'Dhcp' })
            Routes     = @([pscustomobject]@{ NextHop = '192.168.1.1' })
            NameServer = ''
        }
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = $fakeIPv4.Dhcp } }
        Mock Get-NetIPAddress { $fakeIPv4.Addresses }
        Mock Get-NetRoute { $fakeIPv4.Routes }
        Mock Get-ItemProperty
        Mock Get-ItemProperty { [pscustomobject]@{ NameServer = $fakeIPv4.NameServer } } -ParameterFilter { $LiteralPath -like '*\Tcpip\Parameters\Interfaces\{GUID-7}' }
        Mock Set-NetIPInterface
        Mock Remove-NetIPAddress
        Mock Remove-NetRoute
        Mock New-NetIPAddress
        Mock Set-DnsClientServerAddress
        Mock Rename-NetAdapter
        $staticSettings = [pscustomobject]@{
            IPAddress      = '10.20.67.2'
            PrefixLength   = 24
            DefaultGateway = '10.20.67.254'
            DNSServers     = @('10.75.38.23', '10.75.38.22')
        }
    }
    It 'gives a DHCP card found by FindBy.Name a static address, gateway and DNS servers' {
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'Ethernet' }; Change = [pscustomobject]@{ IPSettings = $staticSettings } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 7 -and $Dhcp -eq 'Disabled' }
        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 7 }
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 7 -and $DestinationPrefix -eq '0.0.0.0/0' }
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $IPAddress -eq '10.20.67.2' -and $PrefixLength -eq 24 -and $DefaultGateway -eq '10.20.67.254'
        }
        Should -Invoke Set-DnsClientServerAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and ($ServerAddresses -join ',') -eq '10.75.38.23,10.75.38.22'
        }
        $result.Messages | Should -Be @(
            "Network card 'Ethernet' now has the static IPv4 address 10.20.67.2/24 with default gateway 10.20.67.254"
            "Network card 'Ethernet' now uses the DNS servers 10.75.38.23, 10.75.38.22"
        )
    }
    It 'changes nothing when the static settings are already correct' {
        $fakeIPv4.Dhcp = 'Disabled'
        $fakeIPv4.Addresses = @([pscustomobject]@{ IPAddress = '10.20.67.2'; PrefixLength = 24; PrefixOrigin = 'Manual' })
        $fakeIPv4.Routes = @([pscustomobject]@{ NextHop = '10.20.67.254' })
        $fakeIPv4.NameServer = '10.75.38.23,10.75.38.22'
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Description = 'Intel(R) Ethernet' }; Change = [pscustomobject]@{ IPSettings = $staticSettings } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Messages | Should -Be @("Network card with description 'Intel(R) Ethernet' is already correct")
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
        Should -Invoke Set-DnsClientServerAddress -Times 0 -Exactly
    }
    It 'switches a static card back to DHCP and makes hand-set DNS automatic' {
        $fakeIPv4.Dhcp = 'Disabled'
        $fakeIPv4.NameServer = '10.75.38.23'
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'Ethernet' }; Change = [pscustomobject]@{ IPSettings = [pscustomobject]@{ Dhcp = $true } } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $Dhcp -eq 'Enabled' }
        Should -Invoke Set-DnsClientServerAddress -Times 1 -Exactly -ParameterFilter { $ResetServerAddresses }
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
    }
    It 'leaves a DHCP card alone when it should use DHCP' {
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'Ethernet' }; Change = [pscustomobject]@{ IPSettings = [pscustomobject]@{ Dhcp = $true } } })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Messages | Should -Be @("Network card 'Ethernet' is already correct")
        Should -Invoke Set-NetIPInterface -Times 0 -Exactly
    }
    It 'names how a missing card was searched for' {
        $data = @(
            [pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'LAN' }; Change = [pscustomobject]@{} }
            [pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'Ethernet'; Description = 'Intel' }; Change = [pscustomobject]@{} }
        )
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @(
            "Failed to configure network card 'LAN': no network card found with Name 'LAN'; names: Ethernet, Wi-Fi"
            "Failed to configure network card 'Ethernet': FindBy has both Description and Name; use one of them"
        )
    }
    It 'renames a card found by FindBy.Name' {
        $data = @([pscustomobject]@{ FindBy = [pscustomobject]@{ Name = 'Ethernet' }; Change = [pscustomobject]@{ NewName = 'LAN' } })
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Ethernet' -and $NewName -eq 'LAN' }
    }
    It 'exports a static card with its gateway and hand-set DNS, and a DHCP card as Dhcp true' {
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = 'Disabled' } } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ IPAddress = '10.20.67.2'; PrefixLength = 24; PrefixOrigin = 'Manual' }
            [pscustomobject]@{ IPAddress = '10.20.67.3'; PrefixLength = 24; PrefixOrigin = 'Manual' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetRoute { [pscustomobject]@{ NextHop = '10.20.67.254' } } -ParameterFilter { $InterfaceIndex -eq 7 }
        $fakeIPv4.NameServer = '10.75.38.23,10.75.38.22'
        $result = . $scriptPath -Action Export -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0
        $static = $result.Data | Where-Object { $_.Change.NewName -eq 'Ethernet' }
        $static.FindBy.Description | Should -Be 'Intel(R) Ethernet'
        @($static.FindBy.Keys) | Should -Be @('Description')
        $static.Change.IPSettings.IPAddress | Should -Be '10.20.67.2'
        $static.Change.IPSettings.PrefixLength | Should -Be 24
        $static.Change.IPSettings.DefaultGateway | Should -Be '10.20.67.254'
        $static.Change.IPSettings.DNSServers | Should -Be @('10.75.38.23', '10.75.38.22')
        ($result.Data | Where-Object { $_.Change.NewName -eq 'Wi-Fi' }).Change.IPSettings.Dhcp | Should -BeTrue
        $result.Messages | Should -Contain "Network card 'Ethernet' has 2 IPv4 addresses; only 10.20.67.2 was exported"
    }
}