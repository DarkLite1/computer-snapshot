#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Engine\Scripts\Power settings import export.ps1"
    Name       = 'Power settings'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Power settings' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Power settings import export.ps1'
        function Invoke-PowerCfgHC { param([string[]]$Arguments) }
        function Get-HibernateEnabledHC {}
    }
    BeforeEach {
        Mock Invoke-PowerCfgHC
        Mock Invoke-PowerCfgHC {
            'Existing Power Schemes (* Active)'
            '-----------------------------------'
            ('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  ' +
                '(Balanced) *')
            ('Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  ' +
                '(Hohe Leistung)')
            ('Power Scheme GUID: b2c6063b-bae9-4d4e-ab40-28d1ec22320c  ' +
                '(Kiosk (no sleep))')
        } -ParameterFilter { $Arguments[0] -eq '/list' }
        # Display: 10 minutes plugged in, 5 on battery; others never
        Mock Invoke-PowerCfgHC {
            '      Minimum Possible Setting: 0x00000000'
            '      Maximum Possible Setting: 0xffffffff'
            '    Current AC Power Setting Index: 0x00000258'
            '    Current DC Power Setting Index: 0x0000012c'
        } -ParameterFilter {
            $Arguments[0] -eq '/query' -and $Arguments[3] -eq 'VIDEOIDLE'
        }
        Mock Invoke-PowerCfgHC {
            '    Current AC Power Setting Index: 0x00000000'
            '    Current DC Power Setting Index: 0x00000000'
        } -ParameterFilter {
            $Arguments[0] -eq '/query' -and $Arguments[3] -ne 'VIDEOIDLE'
        }
        Mock Get-HibernateEnabledHC { $true }
        $importParams = @{ Action = 'Import'; RootFolder = $TestDrive }
    }
    It 'exports the plan, the timeouts in minutes and hibernation' {
        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors | Should -BeNullOrEmpty
        $result.Data.ActivePlan | Should -Be 'Balanced'
        $result.Data.MonitorTimeoutMinutes.AC | Should -Be 10
        $result.Data.MonitorTimeoutMinutes.DC | Should -Be 5
        $result.Data.SleepTimeoutMinutes.AC | Should -Be 0
        $result.Data.HibernateEnabled | Should -BeTrue
    }
    It 'activates a plan by its language-independent name or its own name' {
        foreach ($plan in @('HighPerformance', 'Kiosk (no sleep)')) {
            $importParams.Data = [pscustomobject]@{ ActivePlan = $plan }

            $result = & $scriptPath @importParams

            $result.Errors | Should -BeNullOrEmpty
        }
        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            $Arguments[0] -eq '/setactive' -and
            $Arguments[1] -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        } -Times 1 -Exactly
        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            $Arguments[0] -eq '/setactive' -and
            $Arguments[1] -eq 'b2c6063b-bae9-4d4e-ab40-28d1ec22320c'
        } -Times 1 -Exactly
    }
    It 'reports a plan the computer does not have' {
        $importParams.Data = [pscustomobject]@{ ActivePlan = 'PowerSaver' }

        $result = & $scriptPath @importParams

        $result.Errors | Should -Be @(
            ("Failed to activate power plan 'PowerSaver': this computer " +
                'has no such plan; plans: Balanced, Hohe Leistung, Kiosk ' +
                '(no sleep)')
        )
    }
    It 'sets only the timeouts that differ, in seconds, and applies them' {
        $importParams.Data = [pscustomobject]@{
            MonitorTimeoutMinutes = [pscustomobject]@{ AC = 10; DC = 15 }
            SleepTimeoutMinutes   = [pscustomobject]@{ AC = 0 }
        }

        $result = & $scriptPath @importParams

        $result.Errors | Should -BeNullOrEmpty
        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            ($Arguments -join ' ') -eq
            '/setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 900'
        } -Times 1 -Exactly
        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            $Arguments[0] -eq '/setacvalueindex'
        } -Times 0 -Exactly
        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            ($Arguments -join ' ') -eq '/setactive SCHEME_CURRENT'
        } -Times 1 -Exactly
        $result.Messages | Should -Be @(
            'Changed turn off display on DC power from 5 to 15 minutes'
            'The sleep timeout is already correct'
        )
    }
    It 'turns hibernation off' {
        $importParams.Data = [pscustomobject]@{ HibernateEnabled = $false }

        $result = & $scriptPath @importParams

        Should -Invoke Invoke-PowerCfgHC -ParameterFilter {
            ($Arguments -join ' ') -eq '/hibernate off'
        } -Times 1 -Exactly
        $result.Messages | Should -Be @('Turned hibernation off')
    }
}
