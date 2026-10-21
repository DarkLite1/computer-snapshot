#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\NTP time servers import export.ps1" -Name 'NTP time servers'

Describe 'NTP peer capture' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\NTP time servers import export.ps1"
    }
    BeforeEach {
        Mock Get-ItemProperty { [pscustomobject]@{ Type = 'NTP'; NtpServer = "  server1,0x9`tserver2,0x8   server3  " } }
        Mock w32tm { throw 'Manual peers must not query the current source' }
    }
    It 'exports every manual peer in order rather than only the first comma-delimited value' {
        $result = . $scriptPath -Action Export -RootFolder $TestDrive
        $result.Data.SyncTimeWithDomain | Should -BeFalse
        $result.Data.TimeServerNames | Should -Be @('server1', 'server2', 'server3')
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke w32tm -Times 0 -Exactly
    }
    It 'preserves the array shape for one peer' {
        Mock Get-ItemProperty { [pscustomobject]@{ Type = 'NTP'; NtpServer = 'server1,0x9' } }
        $result = . $scriptPath -Action Export -RootFolder $TestDrive
        $result.Data.TimeServerNames.GetType().IsArray | Should -BeTrue
        $result.Data.TimeServerNames | Should -Be @('server1')
    }
    It 'fails export when time-service settings cannot be read' {
        Mock Get-ItemProperty { throw 'Registry unavailable' }
        { . $scriptPath -Action Export -RootFolder $TestDrive } | Should -Throw '*Registry unavailable*'
    }
}