#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action         = 'CreateSnapshot'
        Snapshot       = @{
            Script1 = $false
            Script2 = $true
        }
        Script         = @{
            Script1 = (New-Item 'TestDrive:/1.ps1' -ItemType File).FullName
            Script2 = (New-Item 'TestDrive:/2.ps1' -ItemType File).FullName
        }
        SnapshotsFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
    }

    Function Invoke-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [String]$DataFolder,
            [Parameter(Mandatory)]
            [ValidateSet('Export', 'Import')]
            [String]$Type
        )
    }
    Mock Invoke-ScriptHC {
        Write-Verbose "Invoke script '$Path' on data folder '$DataFolder' for '$Type'"
    }
}
Describe "Throw a terminating error for action 'CreateSnapshot' when" {
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'CreateSnapshot'
    }
    It 'the snapshots folder cannot be created' {
        $testNewParams.SnapshotsFolder = 'x:/xxx'
        { .$testScript @testNewParams } | 
        Should -Throw "*Failed to create snapshots folder 'x:/xxx'*"
    }
    It 'the script does not exist' {
        $testNewParams.Snapshot = @{
            Script1 = $true
        }
        $testNewParams.Script = @{
            Script1 = 'TestDrive:/xxx.ps1'
        }
        { .$testScript @testNewParams } | 
        Should -Throw "*Script file 'TestDrive:/xxx.ps1' not found for snapshot item 'Script1'"
    }
    It 'a snapshot is requested for an item that does not exist' {
        $testNewParams.Snapshot = @{
            Unknown = $true
        }
        { .$testScript @testNewParams } | 
        Should -Throw "*No script found for snapshot item 'Unknown'"
    }
}
Describe "Throw a terminating error for action 'RestoreSnapshot' when" {
    BeforeEach {
        Remove-Item $testParams.SnapshotsFolder -Recurse -EA Ignore
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'RestoreSnapshot'
    }
    It 'no snapshot has been made yet' {
        $testNewParams.SnapshotsFolder | Should -Not -Exist
        { .$testScript @testNewParams } | 
        Should -Throw "*Snapshot folder '$($testNewParams.SnapshotsFolder)' not found. Please create your first snapshot with action 'CreateSnapshot'"
    }
    It "the 'RestoreSnapshotFolder' folder is not found'" {
        $testNewParams.RestoreSnapshotFolder = 'TestDrive:/xxx'
        { .$testScript @testNewParams } | 
        Should -Throw "*Restore snapshot folder 'TestDrive:/xxx' not found"
    }
    It "the 'RestoreSnapshotFolder' is empty" {
        $testNewParams.RestoreSnapshotFolder = (New-Item 'TestDrive:/B' -ItemType Directory).FullName
        { .$testScript @testNewParams } | 
        Should -Throw "*No data found in snapshot folder '$($testNewParams.RestoreSnapshotFolder)'"
    }
    It 'no data is found in the snapshot folder' {
        New-Item $testNewParams.SnapshotsFolder -ItemType Directory
        { .$testScript @testNewParams } | 
        Should -Throw "*No data found in snapshot folder '$($testNewParams.SnapshotsFolder)' to restore. Please create a snapshot first with Action 'CreateSnapshot'"
    }
    It 'no data is found for the specified script to restore' {
        $testSnapshotFolder = New-Item "$($testNewParams.SnapshotsFolder)/Snapshot1/Script2" -ItemType Directory
        { .$testScript @testNewParams } | 
        Should -Throw "*No data found for snapshot item 'Script2' in folder '$testSnapshotFolder'"
    }
    It 'the script does not exist' {
        New-Item "$($testNewParams.SnapshotsFolder)\Snapshot1\Script1" -ItemType Directory
        New-Item "$($testNewParams.SnapshotsFolder)\Snapshot1\Script1\Export.csv" -ItemType file
        $testNewParams.Snapshot = @{
            Script1 = $true
        }
        $testNewParams.Script = @{
            Script1 = 'TestDrive:/xxx.ps1'
        }
        { .$testScript @testNewParams } | 
        Should -Throw "*Script file 'TestDrive:/xxx.ps1' not found for snapshot item 'Script1'"
    }
}
Describe "When action is 'CreateSnapshot'" {
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'CreateSnapshot'
    }
    It 'a script is called for enabled snapshot items only' {
        .$testScript @testNewParams
        Should -Invoke Invoke-ScriptHC -Exactly -Times 1
        Should -Invoke Invoke-ScriptHC -Exactly -Times 1 -ParameterFilter {
            ($Path -eq $testNewParams.Script.Script2) -and
            ($DataFolder -like '*Script2*') -and
            ($Type -eq 'Export')
        }
    }
}
Describe "When action is 'RestoreSnapshot'" {
    BeforeEach {
        Remove-Item $testParams.SnapshotsFolder -Recurse -EA Ignore
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'RestoreSnapshot'
    }
    Context 'a script is called for enabled snapshot items only' {
        It 'on the most recently created snapshot' {
            $testSnapshot1 = (New-Item "$($testNewParams.SnapshotsFolder)\Snapshot1\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot1\Export.csv" -ItemType file
            Start-Sleep -Milliseconds 1
            $testSnapshot2 = (New-Item "$($testNewParams.SnapshotsFolder)\Snapshot2\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot2\Export.csv" -ItemType file

            .$testScript @testNewParams
            Should -Invoke Invoke-ScriptHC -Exactly -Times 1
            Should -Invoke Invoke-ScriptHC -Exactly -Times 1 -ParameterFilter {
                ($Path -eq $testNewParams.Script.Script2) -and
                ($DataFolder -eq $testSnapshot2) -and
                ($Type -eq 'Import')
            }
        }
        It "on the snapshot in the folder 'RestoreSnapshotFolder'" {
            $testSnapshotFolder = (New-Item "$($testNewParams.SnapshotsFolder)\Snapshot1" -ItemType Directory).FullName
            $testSnapshot1 = (New-Item "$testSnapshotFolder\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot1\Export.csv" -ItemType file
            Start-Sleep -Milliseconds 1
            $testSnapshot2 = (New-Item "$($testNewParams.SnapshotsFolder)\Snapshot2\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot2\Export.csv" -ItemType file

            $testNewParams.RestoreSnapshotFolder = $testSnapshotFolder

            .$testScript @testNewParams
            Should -Invoke Invoke-ScriptHC -Exactly -Times 1
            Should -Invoke Invoke-ScriptHC -Exactly -Times 1 -ParameterFilter {
                ($Path -eq $testNewParams.Script.Script2) -and
                ($DataFolder -eq $testSnapshot1) -and
                ($Type -eq 'Import')
            }
        }
    }
}
Describe 'When a child script fails with a non terminating error' {
    BeforeEach {
        Get-ChildItem -Path 'TestDrive:/' -Filter '*.ps1' |
        Remove-Item

        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'CreateSnapshot'
        $testNewParams.Snapshot = @{
            Script1 = $true
            Script2 = $true
            Script3 = $true
        }
        $testNewParams.Script = @{
            Script1 = (New-Item 'TestDrive:/1.ps1' -ItemType File).FullName
            Script2 = (New-Item 'TestDrive:/2.ps1' -ItemType File).FullName
            Script3 = (New-Item 'TestDrive:/3.ps1' -ItemType File).FullName
        }

        Mock Invoke-ScriptHC {
            Write-Error 'Script2 non terminating error'
        } -ParameterFilter { $Path -eq $testNewParams.Script.Script2 }
        Mock Write-Warning

        .$testScript @testNewParams -ErrorAction SilentlyContinue
    }
    It 'other scripts are still executed' {
        Should -Invoke Invoke-ScriptHC -Times 3 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script1 
        }
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script2 
        }
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script3 
        }
    }
    It "the error is reported as a 'Blocking error'" {
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { 
            $Message -like '*Script2 non terminating error*' 
        }
    }
}
Describe 'When a child script fails with a terminating error' {
    BeforeEach {
        Get-ChildItem -Path 'TestDrive:/' -Filter '*.ps1' |
        Remove-Item

        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'CreateSnapshot'
        $testNewParams.Snapshot = @{
            Script1 = $true
            Script2 = $true
            Script3 = $true
        }
        $testNewParams.Script = @{
            Script1 = (New-Item 'TestDrive:/1.ps1' -ItemType File).FullName
            Script2 = (New-Item 'TestDrive:/2.ps1' -ItemType File).FullName
            Script3 = (New-Item 'TestDrive:/3.ps1' -ItemType File).FullName
        }

        Mock Invoke-ScriptHC {
            throw 'Script2 terminating error'
        } -ParameterFilter { $Path -eq $testNewParams.Script.Script2 }
        Mock Write-Host

        .$testScript @testNewParams
    }
    It 'other scripts are still executed' {
        Should -Invoke Invoke-ScriptHC -Times 3 -Exactly
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script1 
        }
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script2 
        }
        Should -Invoke Invoke-ScriptHC -Times 1 -Exactly -ParameterFilter { 
            $Path -eq $testNewParams.Script.Script3 
        }
    }
    It "the error is reported as a 'Blocking error'" {
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { 
            ($Object -like '*Script2 terminating error*') -and
            ($ForegroundColor -eq 'Red')
        }
    }
}