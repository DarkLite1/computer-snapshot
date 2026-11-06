#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath (
    "$PSScriptRoot\..\Engine\Scripts\Network cards import export.ps1"
) -Name 'Network cards'

Describe 'Network profile restoration' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Network cards import export.ps1"
    }
    BeforeEach {
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
                ConnectionSpecificSuffix = ''
            }
        }
        Mock Get-NetConnectionProfile {
            [pscustomobject]@{
                InterfaceAlias  = 'Old'
                InterfaceIndex  = 1
                NetworkCategory = 'Public'
            }
            [pscustomobject]@{
                InterfaceAlias  = 'New'
                InterfaceIndex  = 2
                NetworkCategory = 'Public'
            }
        }
        Mock Rename-NetAdapter
        Mock Set-NetConnectionProfile
        Mock Set-DnsClient
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Description = 'Example' }
                Change = [pscustomobject]@{
                    NewName         = 'New'
                    NetworkCategory = 'Private'
                }
            }
        )
    }
    It ('changes the matched adapter profile after a rename without ' +
        'touching a different interface') {
        $importParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Old' -and $NewName -eq 'New'
        }
        Should -Invoke Set-NetConnectionProfile -ParameterFilter {
            $InterfaceIndex -eq 1 -and $NetworkCategory -eq 'Private'
        } -Times 1 -Exactly
        Should -Invoke Set-NetConnectionProfile -ParameterFilter {
            $InterfaceIndex -eq 2
        } -Times 0 -Exactly
        $result.Messages -join ';' | Should -Match 'Changed network category'
    }
    It 'changes category when retaining the existing adapter name' {
        $data[0].Change.NewName = ''

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
        Should -Invoke Set-NetConnectionProfile -ParameterFilter {
            $InterfaceIndex -eq 1
        } -Times 1 -Exactly
    }
    It 'does not reapply an already correct category' {
        $data[0].Change.NetworkCategory = 'Public'

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }
    It 'stops applying settings for the card when renaming fails' {
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = 'new.example'
        }
        $data[0].Change | Add-Member @fakeDnsSuffix
        Mock Rename-NetAdapter { Write-Error 'Rename failed' }

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure network card 'New': Rename failed"
        )
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'surfaces a failed profile update' {
        Mock Set-NetConnectionProfile { Write-Error 'Profile update failed' }

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure network card 'New': Profile update failed"
        )
    }
    It 'clears an existing suffix when an empty string is explicitly supplied' {
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex           = 1
                ConnectionSpecificSuffix = 'old.example'
            }
        }
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = ''
        }
        $data[0].Change | Add-Member @fakeDnsSuffix

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 1 -and $ConnectionSpecificSuffix -ceq ''
        }
    }
    It 'leaves an omitted suffix unchanged' {
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex           = 1
                ConnectionSpecificSuffix = 'old.example'
            }
        }

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'leaves a null suffix unchanged' {
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex           = 1
                ConnectionSpecificSuffix = 'old.example'
            }
        }
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = $null
        }
        $data[0].Change | Add-Member @fakeDnsSuffix

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'does not reapply an already empty suffix' {
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = ''
        }
        $data[0].Change | Add-Member @fakeDnsSuffix

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'applies a nonempty suffix to the matched interface' {
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = 'new.example'
        }
        $data[0].Change | Add-Member @fakeDnsSuffix

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 1 -and
            $ConnectionSpecificSuffix -eq 'new.example'
        }
    }
    It 'surfaces a failed suffix update' {
        $fakeDnsSuffix = @{
            NotePropertyName  = 'DnsSuffix'
            NotePropertyValue = 'new.example'
        }
        $data[0].Change | Add-Member @fakeDnsSuffix
        Mock Set-DnsClient { Write-Error 'DNS suffix update failed' }

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure network card 'New': DNS suffix update failed"
        )
    }
    It 'reports a card that is not found and still configures the next card' {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Description = 'Broadcom' }
                Change = [pscustomobject]@{ NewName = 'Factory' }
            }
            $data[0]
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            ("Failed to configure network card 'Factory': no network card " +
                "found with a description containing 'Broadcom'")
        )
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $NewName -eq 'New'
        }
    }
    It 'prefers an exact description over cards that only contain it' {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Ethernet'
                InterfaceDescription = 'Intel(R) Ethernet'
                InterfaceIndex       = 1
            }
            [pscustomobject]@{
                Name                 = 'Ethernet 2'
                InterfaceDescription = 'Intel(R) Ethernet #2'
                InterfaceIndex       = 2
            }
        }
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{
                    Description = 'Intel(R) Ethernet'
                }
                Change = [pscustomobject]@{ NewName = 'LAN' }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors.Count | Should -Be 0
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Ethernet' -and $NewName -eq 'LAN'
        }
    }
    It 'refuses a partial description that matches several cards' {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Ethernet'
                InterfaceDescription = 'Intel(R) Ethernet'
                InterfaceIndex       = 1
            }
            [pscustomobject]@{
                Name                 = 'Ethernet 2'
                InterfaceDescription = 'Intel(R) Ethernet #2'
                InterfaceIndex       = 2
            }
        }
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Description = 'Intel' }
                Change = [pscustomobject]@{ NewName = 'LAN' }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors[0] | Should -BeLike (
            "*2 network cards match the description 'Intel'*" +
            'use the full description'
        )
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
    }
    It 'reports an already correct card' {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Description = 'Example' }
                Change = [pscustomobject]@{
                    NewName         = 'Old'
                    NetworkCategory = 'Public'
                }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Messages | Should -Be @(
            "Network card 'Old' is already correct"
        )
    }
    It ('reports a configured category for a card without a network ' +
        'connection') {
        Mock Get-NetConnectionProfile { }

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors.Count | Should -Be 0
        $result.Messages | Should -Contain (
            "Network card 'New' has no network connection, its network " +
            "category 'Private' was not set"
        )
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }
}

Describe 'Finding the card and IPv4 settings' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Network cards import export.ps1"
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
        $fakeIPv4 = @{
            Dhcp       = 'Enabled'
            Addresses  = @(
                [pscustomobject]@{
                    IPAddress    = '192.168.1.50'
                    PrefixLength = 24
                    PrefixOrigin = 'Dhcp'
                }
            )
            Routes     = @([pscustomobject]@{ NextHop = '192.168.1.1' })
            NameServer = ''
        }
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = $fakeIPv4.Dhcp } }
        Mock Get-NetIPAddress { $fakeIPv4.Addresses }
        Mock Get-NetRoute { $fakeIPv4.Routes }
        Mock Get-ItemProperty
        Mock Get-ItemProperty {
            [pscustomobject]@{ NameServer = $fakeIPv4.NameServer }
        } -ParameterFilter {
            $LiteralPath -like '*\Tcpip\Parameters\Interfaces\{GUID-7}'
        }
        Mock Set-NetIPInterface
        Mock Remove-NetIPAddress
        Mock Remove-NetRoute
        Mock New-NetIPAddress
        Mock Set-DnsClientServerAddress
        Mock Rename-NetAdapter
        Mock Get-NetAdapterBinding
        $staticSettings = [pscustomobject]@{
            IPAddress      = '10.20.67.2'
            PrefixLength   = 24
            DefaultGateway = '10.20.67.254'
            DNSServers     = @('10.75.38.23', '10.75.38.22')
        }
    }
    It ('gives a DHCP card found by FindBy.Name a static address, gateway ' +
        'and DNS servers') {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'Ethernet' }
                Change = [pscustomobject]@{ IPSettings = $staticSettings }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $Dhcp -eq 'Disabled'
        }
        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7
        }
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $DestinationPrefix -eq '0.0.0.0/0'
        }
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and
            $IPAddress -eq '10.20.67.2' -and
            $PrefixLength -eq 24 -and
            $DefaultGateway -eq '10.20.67.254'
        }
        Should -Invoke Set-DnsClientServerAddress -ParameterFilter {
            $InterfaceIndex -eq 7 -and
            ($ServerAddresses -join ',') -eq '10.75.38.23,10.75.38.22'
        } -Times 1 -Exactly
        $result.Messages | Should -Be @(
            ("Network card 'Ethernet' now has the static IPv4 address " +
                '10.20.67.2/24 with default gateway 10.20.67.254')
            ("Network card 'Ethernet' now uses the DNS servers " +
                '10.75.38.23, 10.75.38.22')
        )
    }
    It 'changes nothing when the static settings are already correct' {
        $fakeIPv4.Dhcp = 'Disabled'
        $fakeIPv4.Addresses = @(
            [pscustomobject]@{
                IPAddress    = '10.20.67.2'
                PrefixLength = 24
                PrefixOrigin = 'Manual'
            }
        )
        $fakeIPv4.Routes = @([pscustomobject]@{ NextHop = '10.20.67.254' })
        $fakeIPv4.NameServer = '10.75.38.23,10.75.38.22'
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{
                    Description = 'Intel(R) Ethernet'
                }
                Change = [pscustomobject]@{ IPSettings = $staticSettings }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Messages | Should -Be @(
            ("Network card with description 'Intel(R) Ethernet' is " +
                'already correct')
        )
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
        Should -Invoke Set-DnsClientServerAddress -Times 0 -Exactly
    }
    It 'switches a static card back to DHCP and makes hand-set DNS automatic' {
        $fakeIPv4.Dhcp = 'Disabled'
        $fakeIPv4.NameServer = '10.75.38.23'
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'Ethernet' }
                Change = [pscustomobject]@{
                    IPSettings = [pscustomobject]@{ Dhcp = $true }
                }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter {
            $Dhcp -eq 'Enabled'
        }
        Should -Invoke Set-DnsClientServerAddress -ParameterFilter {
            $ResetServerAddresses
        } -Times 1 -Exactly
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
    }
    It 'leaves a DHCP card alone when it should use DHCP' {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'Ethernet' }
                Change = [pscustomobject]@{
                    IPSettings = [pscustomobject]@{ Dhcp = $true }
                }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Messages | Should -Be @(
            "Network card 'Ethernet' is already correct"
        )
        Should -Invoke Set-NetIPInterface -Times 0 -Exactly
    }
    It 'names how a missing card was searched for' {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'LAN' }
                Change = [pscustomobject]@{}
            }
            [pscustomobject]@{
                FindBy = [pscustomobject]@{
                    Name        = 'Ethernet'
                    Description = 'Intel'
                }
                Change = [pscustomobject]@{}
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            ("Failed to configure network card 'LAN': no network card " +
                "found with Name 'LAN'; names: Ethernet, Wi-Fi")
            ("Failed to configure network card 'Ethernet': FindBy has " +
                'more than one of Description, Name and OnlyCard')
        )
    }
    It ('renames the only physical card, ignoring VPN and virtual ' +
        'adapters, and refuses when there are no or several') {
        $cards = @(
            [pscustomobject]@{
                Name                 = 'Ethernet 3'
                InterfaceDescription = 'Realtek PCIe GbE'
                InterfaceIndex       = 7
                HardwareInterface    = $true
            }
            [pscustomobject]@{
                Name                 = 'VPN'
                InterfaceDescription = 'Fortinet Virtual Ethernet Adapter'
                InterfaceIndex       = 9
                HardwareInterface    = $false
            }
        )
        Mock Get-NetAdapter { $cards }
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = $true }
                Change = [pscustomobject]@{ NewName = 'LAN' }
            }
        )
        $importParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }

        $result = . $scriptPath @importParams

        $result.Errors.Count |
            Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Ethernet 3' -and $NewName -eq 'LAN'
        }

        $cards[1].HardwareInterface = $true
        $result = . $scriptPath @importParams
        $result.Errors | Should -Be @(
            "Failed to configure network card 'LAN': FindBy OnlyCard: " +
            'this computer has 2 physical network cards (''Ethernet 3'' ' +
            '(Realtek PCIe GbE), ''VPN'' (Fortinet Virtual Ethernet ' +
            'Adapter)); use Description or Name instead'
        )

        $cards[0].HardwareInterface = $false
        $cards[1].HardwareInterface = $false
        $data[0].Change = [pscustomobject]@{}
        $result = . $scriptPath @importParams
        $result.Errors | Should -Be @(
            'Failed to configure network card (the only physical card): ' +
            'FindBy OnlyCard: this computer has no physical network card'
        )
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly
    }
    It ('finds the only Wi-Fi or wired card of a laptop, never counting ' +
        'Bluetooth or VPN adapters') {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Ethernet'
                InterfaceDescription = 'Intel(R) Ethernet Connection'
                InterfaceIndex       = 7
                HardwareInterface    = $true
                NdisPhysicalMedium   = 14
            }
            [pscustomobject]@{
                Name                 = 'Wi-Fi'
                InterfaceDescription = 'Intel(R) Wi-Fi 6 AX201'
                InterfaceIndex       = 8
                HardwareInterface    = $true
                NdisPhysicalMedium   = 9
            }
            [pscustomobject]@{
                Name                 = 'Bluetooth Network Connection'
                InterfaceDescription = 'Bluetooth Device (PAN)'
                InterfaceIndex       = 10
                HardwareInterface    = $true
                NdisPhysicalMedium   = 10
            }
            [pscustomobject]@{
                Name                 = 'VPN'
                InterfaceDescription = 'Fortinet Virtual Ethernet Adapter'
                InterfaceIndex       = 11
                HardwareInterface    = $false
                NdisPhysicalMedium   = 14
            }
        }
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = 'Wired' }
                Change = [pscustomobject]@{ NewName = 'LAN' }
            }
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = 'WiFi' }
                Change = [pscustomobject]@{ NewName = 'WLAN' }
            }
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = $true }
                Change = [pscustomobject]@{}
            }
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = 'Cable' }
                Change = [pscustomobject]@{}
            }
        )
        $importParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }

        $result = . $scriptPath @importParams

        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Ethernet' -and $NewName -eq 'LAN'
        }
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Wi-Fi' -and $NewName -eq 'WLAN'
        }
        $result.Errors | Should -Be @(
            ('Failed to configure network card (the only physical card): ' +
                'FindBy OnlyCard: this computer has 2 physical network ' +
                "cards ('Ethernet' (Intel(R) Ethernet Connection), 'Wi-Fi' " +
                '(Intel(R) Wi-Fi 6 AX201)); use Description or Name instead')
            ('Failed to configure network card (the only Cable card): ' +
                "FindBy OnlyCard 'Cable' is unknown; use true, 'WiFi' or " +
                "'Wired'")
        )
    }
    It 'reports a missing Wi-Fi card' {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'Ethernet'
                InterfaceDescription = 'Intel(R) Ethernet Connection'
                InterfaceIndex       = 7
                HardwareInterface    = $true
                NdisPhysicalMedium   = 14
            }
        }
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ OnlyCard = 'WiFi' }
                Change = [pscustomobject]@{ NewName = 'WLAN' }
            }
        )
        $importParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }

        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure network card 'WLAN': FindBy OnlyCard: " +
            'this computer has no Wi-Fi network card'
        )
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
    }
    It 'renames a card found by FindBy.Name' {
        $data = @(
            [pscustomobject]@{
                FindBy = [pscustomobject]@{ Name = 'Ethernet' }
                Change = [pscustomobject]@{ NewName = 'LAN' }
            }
        )

        $importParams = @{

            Action     = 'Import'

            Data       = $data

            RootFolder = $TestDrive

        }

        $null = . $scriptPath @importParams

        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Ethernet' -and $NewName -eq 'LAN'
        }
    }
    It ('exports a static card with its gateway and hand-set DNS, and a ' +
        'DHCP card as Dhcp true') {
        Mock Get-NetIPInterface {
            [pscustomobject]@{ Dhcp = 'Disabled' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{
                IPAddress    = '10.20.67.2'
                PrefixLength = 24
                PrefixOrigin = 'Manual'
            }
            [pscustomobject]@{
                IPAddress    = '10.20.67.3'
                PrefixLength = 24
                PrefixOrigin = 'Manual'
            }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetRoute {
            [pscustomobject]@{ NextHop = '10.20.67.254' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        $fakeIPv4.NameServer = '10.75.38.23,10.75.38.22'

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors.Count | Should -Be 0

        $static = $result.Data |
        Where-Object { $_.Change.NewName -eq 'Ethernet' }
        $static.FindBy.Description | Should -Be 'Intel(R) Ethernet'
        @($static.FindBy.Keys) | Should -Be @('Description')
        $static.Change.IPSettings.IPAddress | Should -Be (
            "{{ipv4:IP address of network card 'Ethernet' (was 10.20.67.2)}}"
        )
        $static.Change.IPSettings.PrefixLength | Should -Be 24
        $static.Change.IPSettings.DefaultGateway |
        Should -Be '10.20.67.254'
        $static.Change.IPSettings.DNSServers |
        Should -Be @('10.75.38.23', '10.75.38.22')

        $dhcp = (
            $result.Data | Where-Object { $_.Change.NewName -eq 'Wi-Fi' }
        ).Change.IPSettings
        $dhcp.Dhcp | Should -BeTrue
        @($dhcp.Keys) | Should -Not -Contain 'IPAddress'

        $result.Messages | Should -Be @(
            'Exported Network cards'
            ("Network card 'Ethernet' has the static IPv4 address " +
                '10.20.67.2; it was exported as a placeholder, so the ' +
                'restore asks for the address')
            ("Network card 'Ethernet' has 2 IPv4 addresses; only " +
                '10.20.67.2 was exported')
        )
    }
    It 'exports a static address placeholder that New answer file.ps1 lists' {
        Mock Get-NetIPInterface {
            [pscustomobject]@{ Dhcp = 'Disabled' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{
                IPAddress    = '192.168.1.20'
                PrefixLength = 24
                PrefixOrigin = 'Manual'
            }
        } -ParameterFilter { $InterfaceIndex -eq 7 }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        Import-Module (
            "$PSScriptRoot\..\Engine\Common\Configuration.psm1"
        ) -Force
        $fakeConfigurationPath = Join-Path $TestDrive 'exported network.json'
        $fakeAnswerPath = Join-Path $TestDrive 'exported network.answers.json'
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{ NetworkCards = $result.Data }
        } $fakeConfigurationPath

        $answerFileParams = @{
            ConfigurationFile = $fakeConfigurationPath
            AnswerFile        = $fakeAnswerPath
        }
        $answerFileScript = "$PSScriptRoot\..\Engine\Scripts\New answer file.ps1"
        $null = & $answerFileScript @answerFileParams

        $answers = (
            Get-Content -LiteralPath $fakeAnswerPath -Raw | ConvertFrom-Json
        ).Answers
        @($answers.PSObject.Properties.Name) | Should -Be @(
            "{{ipv4:IP address of network card 'Ethernet' (was 192.168.1.20)}}"
        )
    }
    It ('exports the category and DNS suffix of each card by interface ' +
        'index and reads its IPv4 settings once') {
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex           = 7
                ConnectionSpecificSuffix = 'lan.example'
            }
            [pscustomobject]@{
                InterfaceIndex           = 8
                ConnectionSpecificSuffix = 'wifi.example'
            }
        }
        Mock Get-NetConnectionProfile {
            [pscustomobject]@{
                InterfaceAlias  = 'Wi-Fi'
                InterfaceIndex  = 8
                NetworkCategory = 'Public'
            }
            [pscustomobject]@{
                InterfaceAlias  = 'Ethernet'
                InterfaceIndex  = 7
                NetworkCategory = 'Private'
            }
            [pscustomobject]@{
                InterfaceAlias  = 'Ethernet'
                InterfaceIndex  = 7
                NetworkCategory = 'DomainAuthenticated'
            }
        }
        Mock Get-NetIPInterface {
            [pscustomobject]@{ Dhcp = 'Disabled' }
        } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{
                IPAddress    = '192.168.1.20'
                PrefixLength = 24
                PrefixOrigin = 'Manual'
            }
        } -ParameterFilter { $InterfaceIndex -eq 7 }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors.Count | Should -Be 0
        $ethernet, $wifi = @($result.Data.Change)
        $ethernet.NetworkCategory | Should -Be 'Private'
        $ethernet.DnsSuffix | Should -Be 'lan.example'
        $wifi.NetworkCategory | Should -Be 'Public'
        $wifi.DnsSuffix | Should -Be 'wifi.example'
        Should -Invoke Get-NetIPInterface -Times 2 -Exactly
        Should -Invoke Get-NetIPAddress -Times 2 -Exactly
    }
}

Describe 'DNS registration, NetBIOS and IPv6' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Network cards import export.ps1"
        function Get-NetBiosSettingHC { param($Adapter) }
        function Set-NetBiosSettingHC { param($Adapter, $Setting) }
    }
    BeforeEach {
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name                 = 'LAN'
                InterfaceDescription = 'Intel(R) Ethernet'
                InterfaceIndex       = 7
            }
        }
        Mock Get-DnsClient {
            [pscustomobject]@{
                InterfaceIndex                 = 7
                ConnectionSpecificSuffix       = ''
                RegisterThisConnectionsAddress = $true
                UseSuffixWhenRegistering       = $false
            }
        }
        Mock Get-NetConnectionProfile
        Mock Get-NetIPInterface
        Mock Set-DnsClient
        Mock Get-NetBiosSettingHC { 'Default' }
        Mock Set-NetBiosSettingHC
        Mock Get-NetAdapterBinding { [pscustomobject]@{ Enabled = $true } }
        Mock Enable-NetAdapterBinding
        Mock Disable-NetAdapterBinding
        $importParams = @{
            Action     = 'Import'
            RootFolder = $TestDrive
            Data       = @(
                [pscustomobject]@{
                    FindBy = [pscustomobject]@{ Name = 'LAN' }
                    Change = [pscustomobject]@{
                        RegisterInDns               = $false
                        UseDnsSuffixWhenRegistering = $true
                        NetBios                     = 'Disabled'
                        IPv6Enabled                 = $false
                    }
                }
            )
        }
    }
    It 'changes each setting that differs' {
        $result = . $scriptPath @importParams

        $result.Errors.Count | Should -Be 0 -Because ($result.Errors -join '; ')
        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and
            $RegisterThisConnectionsAddress -eq $false -and
            $null -eq $UseSuffixWhenRegistering
        }
        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $UseSuffixWhenRegistering -eq $true
        }
        Should -Invoke Set-NetBiosSettingHC -ParameterFilter {
            $Setting -eq 'Disabled' -and $Adapter.InterfaceIndex -eq 7
        } -Times 1 -Exactly
        Should -Invoke Disable-NetAdapterBinding -ParameterFilter {
            $InterfaceDescription -eq 'Intel(R) Ethernet' -and
            $ComponentID -eq 'ms_tcpip6'
        } -Times 1 -Exactly
        $result.Messages | Should -Be @(
            ("Turned off 'Register this connection's addresses in DNS' " +
                "for network card 'LAN'")
            ("Turned on 'Use this connection's DNS suffix in DNS " +
                "registration' for network card 'LAN'")
            ("Changed NetBIOS over TCP/IP of network card 'LAN' from " +
                "'Default' to 'Disabled'")
            "Disabled IPv6 on network card 'LAN'"
        )
    }
    It 'changes nothing when the settings are already correct' {
        $change = $importParams.Data[0].Change
        $change.RegisterInDns = $true
        $change.UseDnsSuffixWhenRegistering = $false
        $change.NetBios = 'Default'
        $change.IPv6Enabled = $true

        $result = . $scriptPath @importParams

        Should -Invoke Set-DnsClient -Times 0 -Exactly
        Should -Invoke Set-NetBiosSettingHC -Times 0 -Exactly
        Should -Invoke Enable-NetAdapterBinding -Times 0 -Exactly
        Should -Invoke Disable-NetAdapterBinding -Times 0 -Exactly
        $result.Messages | Should -Be @(
            "Network card 'LAN' is already correct"
        )
    }
    It 'exports DNS registration, NetBIOS and IPv6' {
        Mock Get-NetBiosSettingHC { 'Disabled' }
        Mock Get-NetAdapterBinding { [pscustomobject]@{ Enabled = $false } }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $change = @($result.Data)[0].Change
        $change.RegisterInDns | Should -BeTrue
        $change.UseDnsSuffixWhenRegistering | Should -BeFalse
        $change.NetBios | Should -Be 'Disabled'
        $change.IPv6Enabled | Should -BeFalse
    }
}

Describe 'Keeping the old IPv4 settings when a change fails' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Network cards import export.ps1"
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
    It ('adds the old static address and gateway back when the new ' +
        'address fails') {
        $importParams = @{
            Action     = 'Import'
            Data       = $fakeData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

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

        $importParams = @{
            Action     = 'Import'
            Data       = $fakeData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

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
        $fakeDnsServers = @{
            NotePropertyName  = 'DNSServers'
            NotePropertyValue = @('10.99.99.99')
        }
        $fakeStaticSettings | Add-Member @fakeDnsServers

        $fakeData[0].Change.IPSettings.IPAddress = '10.20.67.5'

        $importParams = @{
            Action     = 'Import'
            Data       = $fakeData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure network card 'Ethernet': the DNS " +
            'servers 10.99.99.99 could not be set: DNS server is not ' +
            'reachable; the previous IPv4 settings were restored'
        )

        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 7 -and $IPAddress -eq '10.20.67.5'
        }
        Should -Invoke Set-DnsClientServerAddress -ParameterFilter {
            ($ServerAddresses -join ',') -eq '10.75.38.23'
        } -Times 1 -Exactly
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

        $importParams = @{
            Action     = 'Import'
            Data       = $fakeData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

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

        $importParams = @{
            Action     = 'Import'
            Data       = $fakeData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @importParams

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