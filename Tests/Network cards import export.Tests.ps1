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
        $static.Change.IPSettings.IPAddress | Should -Be "{{ipv4:IP address of network card 'Ethernet' (was 10.20.67.2)}}"
        $static.Change.IPSettings.PrefixLength | Should -Be 24
        $static.Change.IPSettings.DefaultGateway | Should -Be '10.20.67.254'
        $static.Change.IPSettings.DNSServers | Should -Be @('10.75.38.23', '10.75.38.22')
        $dhcp = ($result.Data | Where-Object { $_.Change.NewName -eq 'Wi-Fi' }).Change.IPSettings
        $dhcp.Dhcp | Should -BeTrue
        @($dhcp.Keys) | Should -Not -Contain 'IPAddress'
        $result.Messages | Should -Be @(
            'Exported Network cards'
            "Network card 'Ethernet' has the static IPv4 address 10.20.67.2; it was exported as a placeholder, so the restore asks for the address"
            "Network card 'Ethernet' has 2 IPv4 addresses; only 10.20.67.2 was exported"
        )
    }
    It 'exports a static address placeholder that New answer file.ps1 lists' {
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = 'Disabled' } } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ IPAddress = '192.168.1.20'; PrefixLength = 24; PrefixOrigin = 'Manual' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
        $fakeConfigurationPath = Join-Path $TestDrive 'exported network.json'
        $fakeAnswerPath = Join-Path $TestDrive 'exported network.answers.json'
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{ NetworkCards = $result.Data }
        } $fakeConfigurationPath

        $null = & "$PSScriptRoot\..\Scripts\New answer file.ps1" `
            -ConfigurationFile $fakeConfigurationPath `
            -AnswerFile $fakeAnswerPath

        $answers = (
            Get-Content -LiteralPath $fakeAnswerPath -Raw | ConvertFrom-Json
        ).Answers
        @($answers.PSObject.Properties.Name) | Should -Be @(
            "{{ipv4:IP address of network card 'Ethernet' (was 192.168.1.20)}}"
        )
    }
}

Describe 'Keeping the old IPv4 settings when a change fails' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Network cards import export.ps1"
    }
    BeforeEach {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Ethernet'
                InterfaceDescription = 'Intel(R) Ethernet'
                InterfaceIndex       = 7
                InterfaceGuid        = '{GUID-7}'
            }
            [pscustomobject]@{
                Name                 = 'Wi-Fi'
                InterfaceDescription = 'Wireless'
                InterfaceIndex       = 8
                InterfaceGuid        = '{GUID-8}'
            }
        }
        Mock Get-DnsClient
        Mock Get-NetConnectionProfile
        Mock Rename-NetAdapter

        # One card whose settings change as the mocked cmdlets are called
        $fakeCard = @{
            Dhcp          = 'Disabled'
            Addresses     = @(
                [pscustomobject]@{
                    IPAddress    = '10.20.67.2'
                    PrefixLength = 24
                    PrefixOrigin = 'Manual'
                }
            )
            Gateways      = @('10.20.67.254')
            NameServer    = '10.75.38.23'
            FailAddresses = @('10.20.67.9')
            FailDhcp      = $false
            FailDns       = $false
        }
        Mock Get-NetIPInterface {
            [pscustomobject]@{ Dhcp = $fakeCard.Dhcp }
        }
        Mock Get-NetIPAddress { $fakeCard.Addresses }
        Mock Get-NetRoute {
            $fakeCard.Gateways |
            ForEach-Object { [pscustomobject]@{ NextHop = $_ } }
        }
        Mock Get-ItemProperty
        Mock Get-ItemProperty {
            [pscustomobject]@{ NameServer = $fakeCard.NameServer }
        } -ParameterFilter {
            $LiteralPath -like '*\Tcpip\Parameters\Interfaces\{GUID-7}'
        }
        Mock Set-NetIPInterface {
            if ($fakeCard.FailDhcp -and $Dhcp -eq 'Enabled') {
                throw 'DHCP is blocked by policy'
            }
            $fakeCard.Dhcp = [string]$Dhcp
        }
        Mock Remove-NetIPAddress {
            $fakeCard.Addresses = @(
                $fakeCard.Addresses |
                Where-Object { $IPAddress -and $_.IPAddress -ne $IPAddress }
            )
        }
        Mock Remove-NetRoute {
            $fakeCard.Gateways = @(
                $fakeCard.Gateways |
                Where-Object { $NextHop -and $_ -ne $NextHop }
            )
        }
        Mock New-NetIPAddress {
            if ($fakeCard.FailAddresses -contains $IPAddress) {
                throw "The address $IPAddress is already in use"
            }
            $fakeCard.Addresses += [pscustomobject]@{
                IPAddress    = $IPAddress
                PrefixLength = $PrefixLength
                PrefixOrigin = 'Manual'
            }
            if ($DefaultGateway) {
                $fakeCard.Gateways += $DefaultGateway
            }
        }
        Mock New-NetRoute {
            $fakeCard.Gateways += $NextHop
        }
        Mock Set-DnsClientServerAddress {
            if ($fakeCard.FailDns -and $ServerAddresses) {
                if ($ServerAddresses -notcontains '10.75.38.23') {
                    throw 'DNS server is not reachable'
                }
            }
            $fakeCard.NameServer = if ($ResetServerAddresses) { '' }
            else { $ServerAddresses -join ',' }
        }

        $fakeStaticSettings = [pscustomobject]@{
            IPAddress      = '10.20.67.9'
            PrefixLength   = 24
            DefaultGateway = '10.20.67.254'
        }
        $fakeData = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'Ethernet' }
                Change = [pscustomobject]@{
                    IPSettings = $fakeStaticSettings
                }
            }
        )
    }
    It 'adds the old static address and gateway back when the new address fails' {
        $result = . $scriptPath -Action Import -Data $fakeData `
            -RootFolder $TestDrive

        $result.Errors | Should -Be @(
            "Failed to configure network card 'Ethernet': the static " +
            'address 10.20.67.9/24 could not be set: The address ' +
            '10.20.67.9 is already in use; the previous IPv4 settings ' +
            'were restored'
        )

        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and
            $IPAddress -eq '10.20.67.2' -and
            $PrefixLength -eq 24
        }

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and
            $DestinationPrefix -eq '0.0.0.0/0' -and
            $NextHop -eq '10.20.67.254'
        }

        $fakeCard.Dhcp | Should -Be 'Disabled'
        $fakeCard.Addresses.IPAddress | Should -Be @('10.20.67.2')
        $fakeCard.Gateways | Should -Be @('10.20.67.254')
        $result.Messages | Should -BeNullOrEmpty
    }
    It 'turns DHCP on again when the new static address of a DHCP card fails' {
        $fakeCard.Dhcp = 'Enabled'
        $fakeCard.Addresses = @(
            [pscustomobject]@{
                IPAddress    = '192.168.1.50'
                PrefixLength = 24
                PrefixOrigin = 'Dhcp'
            }
        )
        $fakeCard.Gateways = @('192.168.1.1')

        $result = . $scriptPath -Action Import -Data $fakeData `
            -RootFolder $TestDrive

        $result.Errors[0] | Should -BeLike (
            '*the static address 10.20.67.9/24 could not be set: *; ' +
            'the previous IPv4 settings were restored'
        )

        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $Dhcp -eq 'Disabled'
        }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $Dhcp -eq 'Enabled'
        }
        $fakeCard.Dhcp | Should -Be 'Enabled'
    }
    It 'removes the new address and restores the old settings when DNS fails' {
        $fakeCard.FailDns = $true
        $fakeStaticSettings | Add-Member -NotePropertyName DNSServers `
            -NotePropertyValue @('10.99.99.99')

        $fakeData[0].Change.IPSettings.IPAddress = '10.20.67.5'

        $result = . $scriptPath -Action Import -Data $fakeData `
            -RootFolder $TestDrive

        $result.Errors | Should -Be @(
            "Failed to configure network card 'Ethernet': the DNS " +
            'servers 10.99.99.99 could not be set: DNS server is not ' +
            'reachable; the previous IPv4 settings were restored'
        )

        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $IPAddress -eq '10.20.67.5'
        }
        Should -Invoke Set-DnsClientServerAddress -Times 1 -Exactly `
            -ParameterFilter {
            ($ServerAddresses -join ',') -eq '10.75.38.23'
        }
        $fakeCard.Addresses.IPAddress | Should -Be @('10.20.67.2')
        $fakeCard.Gateways | Should -Be @('10.20.67.254')
        $fakeCard.NameServer | Should -Be '10.75.38.23'
    }
    It 'says so when restoring fails too and still configures the next card' {
        $fakeCard.FailAddresses = @('10.20.67.9', '10.20.67.2')
        $fakeData += [pscustomobject]@{
            FindBy = [pscustomobject]@{ Name = 'Wi-Fi' }
            Change = [pscustomobject]@{ NewName = 'Wireless LAN' }
        }

        $result = . $scriptPath -Action Import -Data $fakeData `
            -RootFolder $TestDrive

        $result.Errors | Should -Be @(
            "Failed to configure network card 'Ethernet': the static " +
            'address 10.20.67.9/24 could not be set: The address ' +
            '10.20.67.9 is already in use; restoring the previous ' +
            'settings failed too: the address 10.20.67.2/24 could not ' +
            'be added back: The address 10.20.67.2 is already in use'
        )

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $NextHop -eq '10.20.67.254'
        }
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Wi-Fi' -and $NewName -eq 'Wireless LAN'
        }
        $result.Messages | Should -Contain (
            "Renamed network card 'Wireless' from 'Wi-Fi' to 'Wireless LAN'"
        )
    }
    It 'restores the static settings when switching to DHCP fails' {
        $fakeCard.FailDhcp = $true
        $fakeData[0].Change.IPSettings = [pscustomobject]@{ Dhcp = $true }

        $result = . $scriptPath -Action Import -Data $fakeData `
            -RootFolder $TestDrive

        $result.Errors | Should -Be @(
            "Failed to configure network card 'Ethernet': DHCP could not " +
            'be enabled: DHCP is blocked by policy; the previous IPv4 ' +
            'settings were restored'
        )

        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $IPAddress -eq '10.20.67.2' -and $PrefixLength -eq 24
        }
        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $NextHop -eq '10.20.67.254'
        }
        Should -Invoke Set-DnsClientServerAddress -Times 0 -Exactly
        $fakeCard.Dhcp | Should -Be 'Disabled'
        $fakeCard.Addresses.IPAddress | Should -Be @('10.20.67.2')
        $fakeCard.Gateways | Should -Be @('10.20.67.254')
        $fakeCard.NameServer | Should -Be '10.75.38.23'
    }
}