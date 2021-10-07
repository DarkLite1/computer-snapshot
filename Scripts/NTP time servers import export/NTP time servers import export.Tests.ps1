#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action      = 'Import'
        DataFolder  = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        ntpFileName = 'testNTP.json'
    }

    $testJoinParams = @{
        Path      = $testParams.DataFolder
        ChildPath = $testParams.ntpFileName
    }
    $testFile = Join-Path @testJoinParams
    
    Function Set-SynchronizeTimeWithServerHC {
        Param (
            [Parameter(Mandatory)]
            [String[]]$ComputerName
        )
    }
    Function Set-SynchronizeTimeWithDomainHC {}
    Mock Set-SynchronizeTimeWithServerHC
    Mock Set-SynchronizeTimeWithDomainHC
    Mock Restart-Service
    Mock Test-Connection { $true }
    Mock Write-Output
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of the NTP file when' {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'
    }
    It 'the data folder is not found' {
        $testNewParams.DataFolder = 'TestDrive:/xxx'

        { .$testScript @testNewParams } | 
        Should -Throw "*Export folder 'TestDrive:/xxx' not found"
    }
    It 'the data folder is not empty' {
        $testFolder = (New-Item 'TestDrive:/D' -ItemType Directory).FullName 
        '1' | Out-File -LiteralPath "$testFolder\file.txt"

        $testNewParams.DataFolder = $testFolder

        { .$testScript @testNewParams } | 
        Should -Throw "*Export folder '$testFolder' not empty"
    }
}
Describe 'Fail the import of the NTP file when' {
    BeforeEach {
        Get-ChildItem $testParams.DataFolder | Remove-Item
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    It 'the data folder is not found' {
        $testNewParams.DataFolder = 'TestDrive:/xxx'

        { .$testScript @testNewParams } | 
        Should -Throw "*Import folder 'TestDrive:/xxx' not found"
    }
    It 'the data folder is empty' {
        { .$testScript @testNewParams } | 
        Should -Throw "*Import folder '$($testNewParams.DataFolder)' empty"
    }
    It 'the data folder does not have the NTP file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*NTP file '$($testNewParams.DataFolder)\$($testNewParams.ntpFileName)' not found"
    }
} 
Describe "With Action set to 'Export'" {
    BeforeAll {
        $testFile | Remove-Item -EA Ignore
    
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'

        Function Get-TimeServerHC {}
        Mock Get-TimeServerHC {
            [PSCustomObject]@{
                TimeServer = @(' ntp1 ', ' ntp2 ')
                Type       = 'NTP'
            }
        }

        .$testScript @testNewParams
    }
    It 'a json file is created' {
        $testFile | Should -Exist
    }
    Context 'the json file contains the fields' {
        BeforeAll {
            $testJsonFile = Get-Content $testFile -Raw | ConvertFrom-Json
        }
        It 'SyncTimeWithDomain' {
            $testJsonFile.SyncTimeWithDomain | Should -BeFalse
        }
        It 'TimeServerNames' {
            $testJsonFile.TimeServerNames[0] | Should -Be 'ntp1'
            $testJsonFile.TimeServerNames[1] | Should -Be 'ntp2'
        }
    }
}
Describe "With Action set to 'Import'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'and SyncTimeWithDomain is true' {
        BeforeAll {
            @{
                SyncTimeWithDomain = $true
                TimeServerNames    = @(' ntp1 ', ' ntp2 ')
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile

            .$testScript @testNewParams
        }
        It 'time is synchronized with the domain' {
            Should -Invoke Set-SynchronizeTimeWithDomainHC -Exactly -Times 1 -Scope Context
        }
        It 'output is generated' {
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                $InputObject -eq 'Time synchronized with the domain'
            }
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                $InputObject -eq 'Custom time server names are disregarded'
            }
        }
        It 'the time service is restarted' {
            Should -Invoke Restart-Service -Exactly -Times 1 -Scope Context
        }
    }
    Context 'and SyncTimeWithDomain is false and TimeServerNames are given' {
        BeforeAll {
            @{
                SyncTimeWithDomain = $false
                TimeServerNames    = @(' ntp1 ', ' ntp2 ')
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile

            .$testScript @testNewParams
        }
        It 'each time server is pinged for connectivity' {
            Should -Invoke Test-Connection -Exactly -Times 1 -Scope Context -ParameterFilter {
                $ComputerName -eq 'ntp1'
            }
            Should -Invoke Test-Connection -Exactly -Times 1 -Scope Context -ParameterFilter {
                $ComputerName -eq 'ntp2'
            }
        }
        It 'time is synchronized with custom time servers' {
            Should -Invoke Set-SynchronizeTimeWithServerHC -Exactly -Times 1 -Scope Context -ParameterFilter {
                ($ComputerName[0] -eq 'ntp1') -and
                ($ComputerName[1] -eq 'ntp2')
            }
        }
        It 'output is generated' {
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                $InputObject -eq "Time synchronized with custom time servers 'ntp1 ntp2'"
            }
        }
        It 'the time service is restarted' {
            Should -Invoke Restart-Service -Exactly -Times 1 -Scope Context
        }
    }
    Context 'a terminating error is thrown when' {
        It 'SyncTimeWithDomain is false and TimeServerNames are blank' {
            @{
                SyncTimeWithDomain = $false
                TimeServerNames    = @()
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile

            { .$testScript @testNewParams } |
            Should -Throw "*No time server names found in the import file"
        }
    }
}

