#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath  = "$PSScriptRoot\..\Engine\Scripts\Services import export.ps1"
    Name        = 'Services'
    EmptyExport = $true
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Services' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\Services import export.ps1"
        function Get-ServiceStartupTypeHC { param($Name) }
        function Set-ServiceStartupTypeHC { param($Name, $StartupType) }
    }
    BeforeEach {
        Mock Get-Service {
            [pscustomobject]@{
                Name        = 'Spooler'
                DisplayName = 'Print Spooler'
                Status      = 'Running'
            }
        } -ParameterFilter { $Name -eq 'Spooler' }
        Mock Get-Service {
            [pscustomobject]@{
                Name        = 'wuauserv'
                DisplayName = 'Windows Update'
                Status      = 'Stopped'
            }
        } -ParameterFilter { $Name -eq 'wuauserv' }
        Mock Get-Service {} -ParameterFilter { $Name -eq 'Missing' }
        Mock Get-ServiceStartupTypeHC { 'Automatic' }
        Mock Set-ServiceStartupTypeHC
        Mock Start-Service
        Mock Stop-Service
        $importParams = @{ Action = 'Import'; RootFolder = $TestDrive }
    }
    It 'sets the startup type first and then stops or starts the service' {
        $importParams.Data = @(
            [pscustomobject]@{
                Name        = 'Spooler'
                StartupType = 'Disabled'
                Status      = 'Stopped'
            }
            [pscustomobject]@{ Name = 'wuauserv'; Status = 'Running' }
        )

        $result = & $scriptPath @importParams

        $result.Errors | Should -BeNullOrEmpty
        Should -Invoke Set-ServiceStartupTypeHC -ParameterFilter {
            $Name -eq 'Spooler' -and $StartupType -eq 'Disabled'
        } -Times 1 -Exactly
        Should -Invoke Stop-Service -ParameterFilter {
            $Name -eq 'Spooler' -and $Force
        } -Times 1 -Exactly
        Should -Invoke Start-Service -ParameterFilter {
            $Name -eq 'wuauserv'
        } -Times 1 -Exactly
        $result.Messages | Should -Be @(
            ("Changed the startup type of service 'Spooler' (Print " +
                "Spooler) from 'Automatic' to 'Disabled'")
            "Stopped service 'Spooler' (Print Spooler)"
            "Started service 'wuauserv' (Windows Update)"
        )
    }
    It 'changes nothing when the service is already correct' {
        $importParams.Data = @(
            [pscustomobject]@{
                Name        = 'Spooler'
                StartupType = 'Automatic'
                Status      = 'Running'
            }
        )

        $result = & $scriptPath @importParams

        Should -Invoke Set-ServiceStartupTypeHC -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        $result.Messages | Should -Be @(
            "Service 'Spooler' (Print Spooler) is already correct"
        )
    }
    It 'reports a missing service and still configures the next one' {
        $importParams.Data = @(
            [pscustomobject]@{ Name = 'Missing'; StartupType = 'Manual' }
            [pscustomobject]@{ Name = 'Spooler'; StartupType = 'Manual' }
        )

        $result = & $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to configure service 'Missing': no service with this name"
        )
        Should -Invoke Set-ServiceStartupTypeHC -ParameterFilter {
            $Name -eq 'Spooler'
        } -Times 1 -Exactly
    }
    It 'refuses a service listed twice or Disabled and Running' {
        Import-Module (
            "$PSScriptRoot\..\Engine\Common\Configuration.psm1"
        ) -Force
        $configuration = @{
            SchemaVersion = 3
            Items         = @{
                Services = @(
                    @{ Name = 'Spooler'; StartupType = 'Manual' }
                    @{ Name = 'spooler'; Status = 'Stopped' }
                    @{
                        Name        = 'wuauserv'
                        StartupType = 'Disabled'
                        Status      = 'Running'
                    }
                )
            }
        }

        $problems = @(Test-ConfigurationHC $configuration $TestDrive) -join ';'

        $problems | Should -Match (
            "\[1\]\.Name: 'spooler' is already configured in \[0\]"
        )
        $problems | Should -Match (
            '\[2\]\.Status: a Disabled service cannot be Running'
        )

        $configuration.Items.Services = @(@{ Name = 'Win*' })
        $problems = @(Test-ConfigurationHC $configuration $TestDrive) -join ';'
        $problems | Should -Match '\[0\]\.Name: expected the exact service name'
    }
}
