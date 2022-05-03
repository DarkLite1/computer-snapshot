#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        StartScript                = (New-Item 'TestDrive:/testStartScript.ps1' -ItemType File).FullName 
        PreconfiguredCallersFolder = (New-Item 'TestDrive:/testCallers' -ItemType Directory).FullName 
        NoConfirmQuestion          = $true
    }

    $testJoinParams = @{
        Path      = $testParams.PreconfiguredCallersFolder
        ChildPath = 'testCaller.json'
    }
    $testFile = Join-Path @testJoinParams

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
    Mock Write-Output
    Mock Write-Host
    Mock Write-Warning
    Mock Start-Sleep
    Mock Test-IsStartedElevatedHC { $true }
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
                Action                = 'A'
                RestoreSnapshotFolder = 'B'
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
            ($Arguments.Action -eq 'A') -and
            ($Arguments.RestoreSnapshotFolder -eq 'B') -and
            ($Arguments.RebootComputer -eq $true) -and
            ($Arguments.Snapshot.ScriptA -eq $true) -and
            ($Arguments.Snapshot.ScriptB -eq $false)
        }
    } -tag test
    It 'ask confirmation before executing Start-Script.ps1' {
        Mock Read-Host { 'y' }
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
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

        $testNewParams = $testParams.clone()
        $testNewParams.NoConfirmQuestion = $false

        . $testScript @testNewParams

        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
            ($Prompt -eq 'Are you sure you want to continue (y/n)') 
        }
    }
}