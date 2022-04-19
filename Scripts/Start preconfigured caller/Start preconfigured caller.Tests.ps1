#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        StartScript                = (New-Item 'TestDrive:/testStartScript.ps1' -ItemType File).FullName 
        PreconfiguredCallersFolder = (New-Item 'TestDrive:/testCallers' -ItemType Directory).FullName 
    }

    $testJoinParams = @{
        Path      = $testParams.PreconfiguredCallersFolder
        ChildPath = 'testCaller.json'
    }
    $testFile = Join-Path @testJoinParams
    
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
    Mock Out-GridView
    Mock Write-Output
    Mock Write-Warning
    Mock Start-Sleep
    Mock Test-IsStartedElevatedHC { $true }
}
Describe 'the script fails when' {
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'
    }
    It 'the start script is not found' {
        $testNewParams.StartScript = 'TestDrive:/xxx.ps1'

        .$testScript @testNewParams 

        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Start script 'TestDrive:/xxx.ps1' not found"
        }
    }
    Context 'parameter PreconfiguredCallerFilePath not used' {
        It 'the preconfigured callers folder is not found' {
            $testNewParams.PreconfiguredCallersFolder = 'TestDrive:/xxx'

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Preconfigured callers folder 'TestDrive:/xxx' not found"
            }
        } 
        It 'the preconfigured callers folder has no .JSON file' {
            '1' | Out-File -LiteralPath "$($testParams.PreconfiguredCallersFolder)\file.txt"

            .$testScript @testNewParams 

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "No .JSON file found in folder '$($testParams.PreconfiguredCallersFolder)'. Please create a pre-configuration file first."
            }
        }
    }
}
Describe 'when all tests pass' {
    It 'Start-Script.ps1 is called' {
        @{
            StartScript = @{
                Action                = 'CreateSnapshot'
                RestoreSnapshotFolder = 'Snapshots\Special PC config'
                RebootComputer        = $true
                Snapshot              = @{
                    ScriptA = $true
                    ScriptB = $false
                }
            }
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

        . $testScript @testParams

        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter {
            ($Path -eq $testParams.StartScript) -and
            ($Arguments)
        }
    }
}