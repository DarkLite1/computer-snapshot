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
        $data = @([pscustomobject]@{ NetworkCardName = 'New'; NetworkCardDescription = 'Example'; NetworkCategory = 'Private' })
    }
    It 'changes the matched adapter profile after a rename without touching a different interface' {
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Old' -and $NewName -eq 'New' }
        Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 -and $NetworkCategory -eq 'Private' }
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly -ParameterFilter { $InterfaceIndex -eq 2 }
        $result.Messages -join ';' | Should -Match 'Changed network category'
    }
    It 'changes category when retaining the existing adapter name' {
        $data[0].NetworkCardName = ''
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
        Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 }
    }
    It 'does not reapply an already correct category' {
        $data[0].NetworkCategory = 'Public'
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }
    It 'stops applying settings for the card when renaming fails' {
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue 'new.example'
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
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue ''
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
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue $null
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'does not reapply an already empty suffix' {
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue ''
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'applies a nonempty suffix to the matched interface' {
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue 'new.example'
        $null = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 1 -and $ConnectionSpecificSuffix -eq 'new.example' }
    }
    It 'surfaces a failed suffix update' {
        $data[0] | Add-Member -NotePropertyName NetworkCardDnsSuffix -NotePropertyValue 'new.example'
        Mock Set-DnsClient { Write-Error 'DNS suffix update failed' }
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors | Should -Be @("Failed to configure network card 'New': DNS suffix update failed")
    }
    It 'reports a card that is not found and still configures the next card' {
        $data = @(
            [pscustomobject]@{ NetworkCardName = 'Factory'; NetworkCardDescription = 'Broadcom'; NetworkCategory = '' }
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
        $data = @([pscustomobject]@{ NetworkCardName = 'LAN'; NetworkCardDescription = 'Intel(R) Ethernet'; NetworkCategory = '' })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors.Count | Should -Be 0
        Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Ethernet' -and $NewName -eq 'LAN' }
    }
    It 'refuses a partial description that matches several cards' {
        Mock Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet'; InterfaceIndex = 1 }
            [pscustomobject]@{ Name = 'Ethernet 2'; InterfaceDescription = 'Intel(R) Ethernet #2'; InterfaceIndex = 2 }
        }
        $data = @([pscustomobject]@{ NetworkCardName = 'LAN'; NetworkCardDescription = 'Intel'; NetworkCategory = '' })
        $result = . $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        $result.Errors[0] | Should -BeLike "*2 network cards match the description 'Intel'*use the full description"
        Should -Invoke Rename-NetAdapter -Times 0 -Exactly
    }
    It 'reports an already correct card' {
        $data = @([pscustomobject]@{ NetworkCardName = 'Old'; NetworkCardDescription = 'Example'; NetworkCategory = 'Public' })
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