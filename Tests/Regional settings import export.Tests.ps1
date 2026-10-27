#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Regional settings import export.ps1" -Name 'Regional settings'
Describe 'Regional settings import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Regional settings import export.ps1"
        function Start-ScriptHC { param($Path) }
    }
    BeforeEach {
        Mock Get-WinSystemLocale { [pscustomobject]@{ Name = 'en-US' } }
        Mock Get-TimeZone { [pscustomobject]@{ Id = 'UTC' } }
        Mock Get-WinHomeLocation { [pscustomobject]@{ GeoId = 244; HomeLocation = 'United States' } }
        Mock Get-Culture { [pscustomobject]@{ Name = 'en-US' } }
        Mock Set-WinSystemLocale
        Mock Set-TimeZone
        Mock Set-WinHomeLocation
        Mock Set-Culture
        Mock Start-ScriptHC { 'Set regional settings to be applied to newly created accounts too' }
        $data = [pscustomobject]@{ WinSystemLocaleName = 'nl-BE'; TimeZoneId = 'Romance Standard Time'; WinHomeLocationGeoId = 21; CultureName = 'nl-BE' }
    }
    It 'reports a failed setting and still applies the others' {
        Mock Set-TimeZone { throw 'The time zone ID was not found on the local computer.' }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to set the time zone to 'Romance Standard Time': The time zone ID was not found on the local computer.")
        Should -Invoke Set-WinSystemLocale -Times 1 -Exactly
        Should -Invoke Set-WinHomeLocation -Times 1 -Exactly
        Should -Invoke Set-Culture -Times 1 -Exactly
        Should -Invoke Start-ScriptHC -Times 1 -Exactly
        $result[0].Messages | Should -Contain 'Set regional settings to be applied to newly created accounts too'
    }
    It 'reports a failure to update the default profile' {
        Mock Start-ScriptHC { throw 'Failed to load the temporary profile: exit code 5' }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @('Failed to apply the regional settings to new accounts: Failed to load the temporary profile: exit code 5')
    }
    It 'changes nothing when required fields are missing' {
        $result = @(& $scriptPath -Action Import -Data ([pscustomobject]@{ TimeZoneId = 'UTC' }) -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike 'Nothing was changed, these required fields are missing: WinSystemLocaleName, WinHomeLocationGeoId, CultureName'
        Should -Invoke Set-TimeZone -Times 0 -Exactly
        Should -Invoke Start-ScriptHC -Times 0 -Exactly
    }
    It 'names the system locale correctly and says when it takes effect' {
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages[0] | Should -Be "Changed the system locale from 'en-US' to 'nl-BE', this takes effect after the computer is restarted"
    }
}