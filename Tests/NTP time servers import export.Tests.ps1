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
        $result = . $scriptPath -Action Export -RootFolder $TestDrive
        $result.Errors | Should -Be @('Failed to read the time service settings: Registry unavailable')
        $result.Data | Should -BeNullOrEmpty
    }
}

Describe 'NTP command failures' {
        BeforeAll {
            $scriptPath = "$PSScriptRoot\..\Scripts\NTP time servers import export.ps1"
            function w32tm {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                throw 'An unmocked time-service command must never run in tests'
            }
        }
        BeforeEach {
            $savedExitCode = $global:LASTEXITCODE
            Mock w32tm { $global:LASTEXITCODE = 0 }
            Mock Restart-Service
            Mock Test-Connection { $true }
            Mock Get-ItemProperty { [pscustomobject]@{ Type = 'NT5DS' } }
            $domainData = [pscustomobject]@{ SyncTimeWithDomain = $true }
            $manualData = [pscustomobject]@{ SyncTimeWithDomain = $false; TimeServerNames = @('server1', 'server2') }
        }
        AfterEach {
            $global:LASTEXITCODE = $savedExitCode
        }
        It 'reports source-query exit codes and diagnostics on export' {
            Mock w32tm { $global:LASTEXITCODE = 5; 'Access denied' }
            $result = . $scriptPath -Action Export -RootFolder $TestDrive
            $result.Errors[0] | Should -BeLike '*exit code 5*Access denied*'
        }
        It 'stops a domain import when configuration fails' {
            Mock w32tm { $global:LASTEXITCODE = 5; 'Access denied' } -ParameterFilter { $Arguments -contains '/config' }
            $result = . $scriptPath -Action Import -Data $domainData -RootFolder $TestDrive
            $result.Errors[0] | Should -BeLike 'Failed to configure the time service:*exit code 5*'
            Should -Invoke Restart-Service -Times 0 -Exactly
            Should -Invoke w32tm -Times 0 -Exactly -ParameterFilter { $Arguments -contains '/resync' }
        }
        It 'stops a manual import when configuration fails' {
            Mock w32tm { $global:LASTEXITCODE = 87; 'Invalid parameter' } -ParameterFilter { $Arguments -contains '/config' }
            $result = . $scriptPath -Action Import -Data $manualData -RootFolder $TestDrive
            $result.Errors[0] | Should -BeLike '*exit code 87*Invalid parameter*'
            Should -Invoke Restart-Service -Times 0 -Exactly
        }
        It 'reports resynchronization failures rather than returning a success result' {
            Mock w32tm { $global:LASTEXITCODE = 1; 'No time data available' } -ParameterFilter { $Arguments -contains '/resync' }
            $result = . $scriptPath -Action Import -Data $domainData -RootFolder $TestDrive
            $result.Errors[0] | Should -BeLike 'Failed to synchronize the time now (the settings were applied):*exit code 1*No time data available*'
            $result.Messages | Should -Not -Contain 'Time synchronized with the domain'
        }
        It 'stops before resynchronization if restarting the service fails' {
            Mock Restart-Service { Write-Error 'Service restart failed' }
            $result = . $scriptPath -Action Import -Data $domainData -RootFolder $TestDrive
            $result.Errors | Should -Be @('Failed to restart the time service: Service restart failed')
            Should -Invoke w32tm -Times 0 -Exactly -ParameterFilter { $Arguments -contains '/resync' }
        }
        It 'configures all manual peers in one argument and resynchronizes once' {
            $result = . $scriptPath -Action Import -Data $manualData -RootFolder $TestDrive
            $result.Messages | Should -Contain "Time synchronized with custom time servers 'server1 server2'"
            Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '/config' -and $Arguments -contains '/manualpeerlist:server1 server2' -and $Arguments -contains '/update'
            }
            Should -Invoke Restart-Service -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
            Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter { $Arguments -contains '/resync' }
            Should -Invoke w32tm -Times 2 -Exactly
        }
        It 'does not require ICMP reachability to configure and synchronize NTP' {
            Mock Test-Connection { $false }
            $result = . $scriptPath -Action Import -Data $manualData -RootFolder $TestDrive -ErrorAction Stop
            $result.Messages | Should -Contain "Time synchronized with custom time servers 'server1 server2'"
            Should -Invoke Test-Connection -Times 0 -Exactly
            Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter { $Arguments -contains '/resync' }
        }
            It 'reports missing time servers without touching the time service' {
            $result = . $scriptPath -Action Import -Data ([pscustomobject]@{ SyncTimeWithDomain = $false; TimeServerNames = @('', ' ') }) -RootFolder $TestDrive
            $result.Errors[0] | Should -BeLike '*no time server names are configured*'
            Should -Invoke w32tm -Times 0 -Exactly
            Should -Invoke Restart-Service -Times 0 -Exactly
        }
    }