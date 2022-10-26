#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        StartScript          = (New-Item 'TestDrive:/testStartScript.ps1' -ItemType File).FullName 
        ConfigurationsFolder = (New-Item 'TestDrive:/testConfigs' -ItemType Directory).FullName 
        NoConfirmQuestion    = $true
    }

    $testJoinParams = @{
        Path      = $testParams.ConfigurationsFolder
        ChildPath = 'testCaller.json'
    }
    $testConfigurationFile = Join-Path @testJoinParams

    'Param (
        $Action,
        $RestoreSnapshotFolder,
        $RebootComputer,
        $Snapshot
    )' | Out-File -FilePath $testParams.StartScript
    
    Function Test-IsStartedElevatedHC {}
    Function Invoke-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [HashTable]$Arguments
        )
    }
    Mock Invoke-ScriptHC
    Mock Out-GridView {
        [PSCustomObject]@{
            'File name' = 'testCaller'
        }
    }
    Mock Start-Sleep
    Mock Test-IsStartedElevatedHC { $true }
    Mock Write-Host
    Mock Write-Output
    Mock Write-Warning
}
Describe 'the script fails when' {
    BeforeEach {
        $testNewParams = $testParams.clone()
    }
    It 'the start script is not found' {
        $testNewParams.StartScript = 'TestDrive:/xxx.ps1'

        .$testScript @testNewParams 

        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Start script 'TestDrive:/xxx.ps1' not found"
        }
    }
    Context 'parameter ConfigurationsFolder' {
        It 'is a folder that does not exist' {
            $testNewParams.ConfigurationsFolder = 'TestDrive:/xxx'

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Configurations folder 'TestDrive:/xxx' not found"
            }
        } 
        It 'is a folder without .JSON files in it' {
            '1' | Out-File -LiteralPath "$($testParams.ConfigurationsFolder)\file.txt"

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "No .JSON file found in the configurations folder '$($testParams.ConfigurationsFolder)'. Please create a configuration file first."
            }
        }
    }
    Context 'parameter ConfigurationFile' {
        It 'is a non existing file' {
            $testNewParams.Remove('ConfigurationsFolder')
            $testNewParams.ConfigurationFile = 'TestDrive:/file'

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Configuration file 'TestDrive:/file' not found"
            }
        } 
        It 'is not a .JSON file' {
            $testNewParams.Remove('ConfigurationsFolder')
            $testNewParams.ConfigurationFile = 'TestDrive:/file.txt'
            '1\' | Out-File -LiteralPath $testNewParams.ConfigurationFile

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "File '*file.txt' is not a valid .JSON configuration file*"
            }
        }
    }
}
Describe 'when all tests pass' {
    BeforeAll {
        @{
            StartScript = @{
                Action                = 'A'
                RestoreSnapshotFolder = 'B'
                RebootComputer        = $true
                Snapshot              = @{
                    ScriptA = $true
                    ScriptB = $false
                }
            }
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testConfigurationFile
    }
    Context 'parameter ConfigurationsFolder' {
        It 'Start-Script.ps1 is called' {
            $testNewParams = $testParams.clone()
            $testNewParams.NoConfirmQuestion = $true

            . $testScript @testNewParams

            Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
                ($Path -eq $testParams.StartScript) -and
                ($Arguments.Action -eq 'A') -and
                ($Arguments.RestoreSnapshotFolder -eq 'B') -and
                ($Arguments.RebootComputer -eq $true) -and
                ($Arguments.Snapshot.ScriptA -eq $true) -and
                ($Arguments.Snapshot.ScriptB -eq $false)
            }
        }
        It 'ask confirmation before executing Start-Script.ps1' {
            Mock Read-Host { 'y' }

            $testNewParams = $testParams.clone()
            $testNewParams.NoConfirmQuestion = $false

            . $testScript @testNewParams

            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
            ($Prompt -eq 'Are you sure you want to continue (y/n)') 
            }
        }
    }
    Context 'parameter ConfigurationFile' {
        BeforeEach {
            $testNewParams = $testParams.clone()
            $testNewParams.Remove('ConfigurationsFolder')
            $testNewParams.ConfigurationFile = $testConfigurationFile
        }
        It 'Start-Script.ps1 is called' {
            $testNewParams.NoConfirmQuestion = $true

            . $testScript @testNewParams

            Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
                ($Path -eq $testParams.StartScript) -and
                ($Arguments.Action -eq 'A') -and
                ($Arguments.RestoreSnapshotFolder -eq 'B') -and
                ($Arguments.RebootComputer -eq $true) -and
                ($Arguments.Snapshot.ScriptA -eq $true) -and
                ($Arguments.Snapshot.ScriptB -eq $false)
            }
        }
        It 'ask confirmation before executing Start-Script.ps1' {
            Mock Read-Host { 'y' }

            $testNewParams = $testParams.clone()
            $testNewParams.NoConfirmQuestion = $false

            . $testScript @testNewParams

            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                ($Prompt -eq 'Are you sure you want to continue (y/n)') 
            }
        }
    }
}