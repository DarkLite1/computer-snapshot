#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

Describe 'Monitor SSD' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\..\Files\Monitor SSD.ps1"
        $testParams = @{
            SmtpServer = 'smtp.example.com'
            MailTo     = 'admin@example.com'
        }
        # The CDXML storage cmdlets cannot be mocked, functions take
        # precedence over them
        function Get-PhysicalDisk {}
        function Get-StorageReliabilityCounter {
            param([Parameter(ValueFromPipeline)]$PhysicalDisk)
        }
    }
    BeforeEach {
        Mock Get-PhysicalDisk {
            [pscustomobject]@{
                Model             = 'Good SSD'
                Size              = 512GB
                OperationalStatus = 'OK'
                HealthStatus      = 'Healthy'
                MediaType         = 'SSD'
            }
        }
        Mock Get-StorageReliabilityCounter {
            [pscustomobject]@{ Temperature = 40; Wear = 3 }
        }
        Mock Send-MailMessage
    }
    It 'sends no e-mail when all disks are healthy' {
        & $scriptPath @testParams

        Should -Invoke Send-MailMessage -Times 0 -Exactly
    }
    It 'sends one e-mail that describes the failing disk' {
        Mock Get-PhysicalDisk {
            [pscustomobject]@{
                Model             = 'Good SSD'
                Size              = 512GB
                OperationalStatus = 'OK'
                HealthStatus      = 'Healthy'
                MediaType         = 'SSD'
            }
            [pscustomobject]@{
                Model             = 'Bad SSD'
                Size              = 256GB
                OperationalStatus = 'Degraded'
                HealthStatus      = 'Warning'
                MediaType         = 'SSD'
            }
        }

        & $scriptPath @testParams

        Should -Invoke Send-MailMessage -Times 1 -Exactly -ParameterFilter {
            $To -eq 'admin@example.com' -and
            $SmtpServer -eq 'smtp.example.com' -and
            $Priority -eq 'High' -and
            $Body -like '*Failing hard drive:*' -and
            $Body -like '*<b>Bad SSD</b>*' -and
            $Body -notlike '*Good SSD*'
        }
    }
    It 'keeps the original error when the e-mail cannot be sent' {
        Mock Get-PhysicalDisk {
            [pscustomobject]@{
                Model             = 'Bad SSD'
                Size              = 256GB
                OperationalStatus = 'Degraded'
                HealthStatus      = 'Warning'
                MediaType         = 'SSD'
            }
        }
        Mock Send-MailMessage { throw 'SMTP server unavailable' }
        $Error.Clear()

        { & $scriptPath @testParams } |
            Should -Throw "Failed sending e-mail to 'admin@example.com':*"

        @(
            $Error | Where-Object {
                $_.Exception.Message -eq 'SMTP server unavailable'
            }
        ).Count | Should -BeGreaterThan 0
    }
    It 'requires <Name>' -ForEach @(
        @{ Name = 'SmtpServer'; Message = 'SMTP Server name is required' }
        @{ Name = 'MailTo'; Message = 'E-mail To field is required' }
    ) {
        $params = $testParams.Clone()
        $params.Remove($Name)

        { & $scriptPath @params } | Should -Throw $Message
    }
}
