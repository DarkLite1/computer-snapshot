#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Scripts\NTP time servers import export.ps1"
    Name       = 'NTP time servers'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'NTP peer capture' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'NTP time servers import export.ps1'
    }

    BeforeEach {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                Type      = 'NTP'
                NtpServer = "  server1,0x9`tserver2,0x8   server3  "
            }
        }
        Mock w32tm { throw 'Manual peers must not query the current source' }
    }
    It ('exports every manual peer in order rather than only the first ' +
        'comma-delimited value') {
        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Data.SyncTimeWithDomain | Should -BeFalse
        $result.Data.TimeServerNames |
            Should -Be @('server1', 'server2', 'server3')
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq (
                'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
            ) -and
            $ErrorAction -eq 'Stop'
        }
        Should -Invoke w32tm -Times 0 -Exactly
    }
    It 'preserves the array shape for one peer' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ Type = 'NTP'; NtpServer = 'server1,0x9' }
        }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Data.TimeServerNames.GetType().IsArray | Should -BeTrue
        $result.Data.TimeServerNames | Should -Be @('server1')
    }
    It 'exports no time servers for domain synchronization' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ Type = 'NT5DS'; NtpServer = 'time.windows.com' }
        }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors.Count | Should -Be 0
        $result.Messages | Should -Be @('Exported NTP time servers')
        $result.Data.SyncTimeWithDomain | Should -BeTrue
        $result.Data.TimeServerNames.Count | Should -Be 0
        Should -Invoke w32tm -Times 0 -Exactly
    }
    It 'exports the configured servers for type <Type>' -ForEach @(
        @{ Type = 'AllSync' }
        @{ Type = 'NoSync' }
    ) {
        Mock Get-ItemProperty {
            [pscustomobject]@{ Type = $Type; NtpServer = 'server1,0x9' }
        }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors.Count | Should -Be 0
        $result.Messages[1] | Should -BeLike "*type is '$Type'*"
        $result.Data.SyncTimeWithDomain | Should -BeFalse
        $result.Data.TimeServerNames | Should -Be @('server1')
        Should -Invoke w32tm -Times 0 -Exactly
    }
    It 'fails export when time-service settings cannot be read' {
        Mock Get-ItemProperty { throw 'Registry unavailable' }

        $result = . $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors | Should -Be @(
            'Failed to read the time service settings: Registry unavailable'
        )
        $result.Data | Should -BeNullOrEmpty
    }
}

Describe 'NTP command failures' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'NTP time servers import export.ps1'
        function w32tm {
            param(
                [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
            )
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
        $manualData = [pscustomobject]@{
            SyncTimeWithDomain = $false
            TimeServerNames    = @('server1', 'server2')
        }
    }
    AfterEach {
        $global:LASTEXITCODE = $savedExitCode
    }
    It 'stops a domain import when configuration fails' {
        Mock w32tm {
            $global:LASTEXITCODE = 5; 'Access denied'
        } -ParameterFilter { $Arguments -contains '/config' }

        $testParams = @{
            Action     = 'Import'
            Data       = $domainData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Errors[0] |
            Should -BeLike 'Failed to configure the time service:*exit code 5*'
        Should -Invoke Restart-Service -Times 0 -Exactly
        Should -Invoke w32tm -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '/resync'
        }
    }
    It 'stops a manual import when configuration fails' {
        Mock w32tm {
            $global:LASTEXITCODE = 87; 'Invalid parameter'
        } -ParameterFilter { $Arguments -contains '/config' }

        $testParams = @{
            Action     = 'Import'
            Data       = $manualData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Errors[0] | Should -BeLike '*exit code 87*Invalid parameter*'
        Should -Invoke Restart-Service -Times 0 -Exactly
    }
    It ('reports resynchronization failures rather than returning a ' +
        'success result') {
        Mock w32tm {
            $global:LASTEXITCODE = 1; 'No time data available'
        } -ParameterFilter { $Arguments -contains '/resync' }

        $testParams = @{
            Action     = 'Import'
            Data       = $domainData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Errors[0] | Should -BeLike (
            'Failed to synchronize the time now (the settings were ' +
            'applied):*exit code 1*No time data available*'
        )
        $result.Messages |
            Should -Not -Contain 'Time synchronized with the domain'
    }
    It 'stops before resynchronization if restarting the service fails' {
        Mock Restart-Service { Write-Error 'Service restart failed' }

        $testParams = @{
            Action     = 'Import'
            Data       = $domainData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Errors | Should -Be @(
            'Failed to restart the time service: Service restart failed'
        )
        Should -Invoke w32tm -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '/resync'
        }
    }
    It 'configures all manual peers in one argument and resynchronizes once' {
        $testParams = @{
            Action     = 'Import'
            Data       = $manualData
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Messages | Should -Contain (
            "Time synchronized with custom time servers 'server1 server2'"
        )
        Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '/config' -and
            $Arguments -contains '/manualpeerlist:server1 server2' -and
            $Arguments -contains '/update' -and
            $Arguments -contains '/reliable:NO' -and
            $Arguments -notcontains '/reliable:YES'
        }
        Should -Invoke Restart-Service -Times 1 -Exactly -ParameterFilter {
            $ErrorAction -eq 'Stop'
        }
        Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '/resync'
        }
        Should -Invoke w32tm -Times 2 -Exactly
    }
    It 'does not require ICMP reachability to configure and synchronize NTP' {
        Mock Test-Connection { $false }

        $testParams = @{
            Action      = 'Import'
            Data        = $manualData
            RootFolder  = $TestDrive
            ErrorAction = 'Stop'
        }
        $result = . $scriptPath @testParams

        $result.Messages | Should -Contain (
            "Time synchronized with custom time servers 'server1 server2'"
        )
        Should -Invoke Test-Connection -Times 0 -Exactly
        Should -Invoke w32tm -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '/resync'
        }
    }
    It 'reports missing time servers without touching the time service' {
        $data = [pscustomobject]@{
            SyncTimeWithDomain = $false
            TimeServerNames    = @('', ' ')
        }

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = . $scriptPath @testParams

        $result.Errors[0] |
            Should -BeLike '*no time server names are configured*'
        Should -Invoke w32tm -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
    }
}