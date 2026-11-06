#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Scripts\Regional settings import export.ps1"
    Name       = 'Regional settings'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Regional settings import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'Regional settings import export.ps1'
        function Start-ScriptHC { param($Path) }
        function Get-InstalledUILanguageHC {}
        function Get-UserLanguageListHC {}
        function Set-UserLanguageListHC { param($Languages) }
        function Get-UILanguageOverrideHC {}
        function Set-UILanguageOverrideHC { param($Language) }
    }
    BeforeEach {
        Mock Get-WinSystemLocale { [pscustomobject]@{ Name = 'en-US' } }
        Mock Get-TimeZone { [pscustomobject]@{ Id = 'UTC' } }
        Mock Get-WinHomeLocation {
            [pscustomobject]@{ GeoId = 244; HomeLocation = 'United States' }
        }
        Mock Get-Culture { [pscustomobject]@{ Name = 'en-US' } }
        Mock Get-UserLanguageListHC {
            [pscustomobject]@{
                LanguageTag     = 'en-US'
                InputMethodTips = @('0409:00000409')
            }
        }
        Mock Get-UILanguageOverrideHC
        Mock Get-InstalledUILanguageHC { 'en-US' }
        Mock Set-WinSystemLocale
        Mock Set-TimeZone
        Mock Set-WinHomeLocation
        Mock Set-Culture
        Mock Set-UserLanguageListHC {
            [pscustomobject]@{
                LanguageTag     = 'nl-BE'
                InputMethodTips = @('0813:0000080C')
            }
            [pscustomobject]@{
                LanguageTag     = 'en-US'
                InputMethodTips = @('0409:00000409')
            }
        }
        Mock Set-UILanguageOverrideHC
        Mock Start-ScriptHC {
            'Set regional settings to be applied to newly created accounts too'
        }
        $data = [pscustomobject]@{
            WinSystemLocaleName  = 'nl-BE'
            TimeZoneId           = 'Romance Standard Time'
            WinHomeLocationGeoId = 21
            CultureName          = 'nl-BE'
        }
    }
    It 'reports a failed setting and still applies the others' {
        Mock Set-TimeZone {
            throw 'The time zone ID was not found on the local computer.'
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to set the time zone to 'Romance Standard Time': " +
                'The time zone ID was not found on the local computer.')
        )
        Should -Invoke Set-WinSystemLocale -Times 1 -Exactly
        Should -Invoke Set-WinHomeLocation -Times 1 -Exactly
        Should -Invoke Set-Culture -Times 1 -Exactly
        Should -Invoke Start-ScriptHC -Times 1 -Exactly
        $result[0].Messages | Should -Contain (
            'Set regional settings to be applied to newly created accounts too'
        )
    }
    It 'reports a failure to update the default profile' {
        Mock Start-ScriptHC {
            throw 'Failed to load the temporary profile: exit code 5'
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ('Failed to apply the regional settings to new accounts: ' +
                'Failed to load the temporary profile: exit code 5')
        )
    }
    It 'changes nothing when required fields are missing' {
        $testParams = @{
            Action     = 'Import'
            Data       = [pscustomobject]@{ TimeZoneId = 'UTC' }
            RootFolder = $TestDrive
        }
        $result = @(& $scriptPath @testParams)

        $result[0].Errors[0] | Should -BeLike (
            'Nothing was changed, these required fields are missing: ' +
            'WinSystemLocaleName, WinHomeLocationGeoId, CultureName'
        )
        Should -Invoke Set-TimeZone -Times 0 -Exactly
        Should -Invoke Start-ScriptHC -Times 0 -Exactly
    }
    It 'names the system locale correctly and says when it takes effect' {
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages[0] | Should -Be (
            "Changed the system locale from 'en-US' to 'nl-BE', this takes " +
            'effect after the computer is restarted'
        )
    }
    It 'leaves languages and the display language alone when omitted' {
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive

        Should -Invoke Get-UserLanguageListHC -Times 0 -Exactly
        Should -Invoke Set-UserLanguageListHC -Times 0 -Exactly
        Should -Invoke Set-UILanguageOverrideHC -Times 0 -Exactly
    }
    It 'sets the languages in order with the given keyboards' {
        $data | Add-Member -NotePropertyMembers @{
            WinUserLanguageList = @(
                [pscustomobject]@{
                    LanguageTag     = 'nl-BE'
                    InputMethodTips = @('0813:0000080C')
                }
                [pscustomobject]@{ LanguageTag = 'en-US' }
            )
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -BeNullOrEmpty
        $invoke = @{
            CommandName = 'Set-UserLanguageListHC'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invoke -ParameterFilter {
            $Languages[0].LanguageTag -eq 'nl-BE' -and
            (@($Languages[0].InputMethodTips) -join ',') -eq
            '0813:0000080C' -and
            $Languages[1].LanguageTag -eq 'en-US' -and
            $null -eq $Languages[1].InputMethodTips
        }
        $result[0].Messages | Should -Contain (
            "Changed the language list from 'en-US (0409:00000409)' to " +
            "'nl-BE (0813:0000080C); en-US (0409:00000409)'"
        )
    }
    It 'does not change a language list that already matches' {
        $data | Add-Member -NotePropertyMembers @{
            WinUserLanguageList = @([pscustomobject]@{ LanguageTag = 'en-US' })
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        Should -Invoke Set-UserLanguageListHC -Times 0 -Exactly
        $result[0].Messages | Should -Contain (
            "Language list 'en-US (0409:00000409)' is already correct"
        )
    }
    It 'refuses a display language without an installed language pack' {
        $data | Add-Member -NotePropertyMembers @{
            WinUILanguageOverride = 'nl-NL'
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        Should -Invoke Set-UILanguageOverrideHC -Times 0 -Exactly
        $result[0].Errors | Should -Be @(
            ("Failed to set the display language to 'nl-NL': the " +
                'language pack is not installed')
        )
    }
    It 'sets an installed display language' {
        Mock Get-InstalledUILanguageHC { 'en-US', 'nl-NL' }
        $data | Add-Member -NotePropertyMembers @{
            WinUILanguageOverride = 'nl-NL'
        }

        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive

        $invoke = @{
            CommandName = 'Set-UILanguageOverrideHC'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invoke -ParameterFilter { $Language -eq 'nl-NL' }
    }
    It 'removes the display language override with null' {
        Mock Get-UILanguageOverrideHC { 'nl-NL' }
        $data | Add-Member -NotePropertyMembers @{
            WinUILanguageOverride = $null
        }

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $invoke = @{
            CommandName = 'Set-UILanguageOverrideHC'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invoke -ParameterFilter { -not $Language }
        $result[0].Messages | Should -Contain (
            "Removed the display language override 'nl-NL', this takes " +
            'effect after signing in again'
        )
    }
}