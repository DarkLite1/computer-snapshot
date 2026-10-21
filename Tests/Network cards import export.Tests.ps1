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
    It 'stops applying settings when renaming fails' {
        Mock Rename-NetAdapter { Write-Error 'Rename failed' }
        { . $scriptPath -Action Import -Data $data -RootFolder $TestDrive } | Should -Throw '*Rename failed*'
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
        Should -Invoke Set-DnsClient -Times 0 -Exactly
    }
    It 'surfaces a failed profile update' {
        Mock Set-NetConnectionProfile { Write-Error 'Profile update failed' }
        { . $scriptPath -Action Import -Data $data -RootFolder $TestDrive } | Should -Throw '*Profile update failed*'
    }
}