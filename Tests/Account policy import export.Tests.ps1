#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Engine\Scripts\Account policy import export.ps1"
    Name       = 'Account policy'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Account policy' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Account policy import export.ps1'
        function Get-SecurityPolicyHC {}
        function Set-SecurityPolicyHC { param($Values) }
    }
    BeforeEach {
        $fakePolicy = @{
            MinimumPasswordAge    = 1
            MaximumPasswordAge    = 42
            MinimumPasswordLength = 8
            PasswordComplexity    = 0
            PasswordHistorySize   = 10
            LockoutBadCount       = 0
        }
        Mock Get-SecurityPolicyHC { $fakePolicy.Clone() }
        Mock Set-SecurityPolicyHC {
            foreach ($key in $Values.Keys) {
                $fakePolicy[$key] = $Values[$key]
            }
        }
    }
    It 'exports the settings, with never as 0 and without lockout times' {
        $fakePolicy.MaximumPasswordAge = -1

        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors | Should -BeNullOrEmpty
        $result.Data.MinimumPasswordLength | Should -Be 8
        $result.Data.PasswordComplexity | Should -BeFalse
        $result.Data.MaximumPasswordAgeDays | Should -Be 0
        $result.Data.LockoutThreshold | Should -Be 0
        @($result.Data.Keys) | Should -Not -Contain 'LockoutDurationMinutes'
    }
    It 'applies only the settings that differ, all at once' {
        $data = [pscustomobject]@{
            MinimumPasswordLength      = 12
            PasswordComplexity         = $true
            PasswordHistorySize        = 10
            LockoutThreshold           = 5
            LockoutDurationMinutes     = 15
            ResetLockoutCounterMinutes = 15
        }

        $result = & $scriptPath -Action Import -Data $data -RootFolder (
            $TestDrive
        )

        $result.Errors | Should -BeNullOrEmpty
        Should -Invoke Set-SecurityPolicyHC -Times 1 -Exactly -ParameterFilter {
            $Values.Count -eq 5 -and
            $Values.MinimumPasswordLength -eq 12 -and
            $Values.PasswordComplexity -eq 1 -and
            $Values.LockoutBadCount -eq 5 -and
            $Values.LockoutDuration -eq 15 -and
            $Values.ResetLockoutCount -eq 15
        }
        $result.Messages | Should -Contain (
            "Changed the minimum password length from '8' to '12'"
        )
        $result.Messages | Should -Contain (
            "Changed the account lockout duration in minutes from " +
            "'(not set)' to '15'"
        )
    }
    It 'reports a setting that Windows did not change' {
        Mock Set-SecurityPolicyHC {}
        $data = [pscustomobject]@{ MaximumPasswordAgeDays = 0 }

        $result = & $scriptPath -Action Import -Data $data -RootFolder (
            $TestDrive
        )

        $result.Errors | Should -Be @(
            ("Failed to set the maximum password age in days to '0': " +
                "Windows kept '42'")
        )
    }
    It 'changes nothing when the policy is already correct' {
        $data = [pscustomobject]@{
            MinimumPasswordLength = 8
            PasswordComplexity    = $false
            Comment               = 'Example'
        }

        $result = & $scriptPath -Action Import -Data $data -RootFolder (
            $TestDrive
        )

        Should -Invoke Set-SecurityPolicyHC -Times 0 -Exactly
        $result.Messages | Should -Be @('Account policy is already correct')
    }
    It 'reports when secedit fails' {
        Mock Get-SecurityPolicyHC { throw 'secedit /export failed' }
        $data = [pscustomobject]@{ MinimumPasswordLength = 12 }

        $result = & $scriptPath -Action Import -Data $data -RootFolder (
            $TestDrive
        )

        $result.Errors | Should -Be @(
            'Failed to import the account policy: secedit /export failed'
        )
    }
}
