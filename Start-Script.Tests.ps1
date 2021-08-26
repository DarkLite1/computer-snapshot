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
        SnapshotFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
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
    It 'the snapshot folder cannot be created' {
        $testNewParams.SnapshotFolder = 'x:/xxx'
        { .$testScript @testNewParams } | 
        Should -Throw "*Failed to created snapshot folder 'x:/xxx'*"
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
        Remove-Item $testParams.SnapshotFolder -Recurse -EA Ignore
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'RestoreSnapshot'
    }
    It 'no snapshot has been made yet' {
        $testNewParams.SnapshotFolder | Should -Not -Exist
        { .$testScript @testNewParams } | 
        Should -Throw "*Snapshot folder '$($testNewParams.SnapshotFolder)' not found. Please create your first snapshot with action 'CreateSnapshot'"
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
        New-Item $testNewParams.SnapshotFolder -ItemType Directory
        { .$testScript @testNewParams } | 
        Should -Throw "*No data found in snapshot folder '$($testNewParams.SnapshotFolder)' to restore. Please create a snapshot first with Action 'CreateSnapshot'"
    }
    It 'no data is found for the specified script to restore' {
        $testSnapshotFolder = New-Item "$($testNewParams.SnapshotFolder)/Snapshot1/Script2" -ItemType Directory
        { .$testScript @testNewParams } | 
        Should -Throw "*No data found for snapshot item 'Script2' in folder '$testSnapshotFolder'"
    }
    It 'the script does not exist' {
        New-Item "$($testNewParams.SnapshotFolder)\Snapshot1\Script1" -ItemType Directory
        New-Item "$($testNewParams.SnapshotFolder)\Snapshot1\Script1\Export.csv" -ItemType file
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
        Remove-Item $testParams.SnapshotFolder -Recurse -EA Ignore
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'RestoreSnapshot'
    }
    Context 'a script is called for enabled snapshot items only' {
        It 'on the most recently created snapshot' {
            $testSnapshot1 = (New-Item "$($testNewParams.SnapshotFolder)\Snapshot1\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot1\Export.csv" -ItemType file
            Start-Sleep -Milliseconds 1
            $testSnapshot2 = (New-Item "$($testNewParams.SnapshotFolder)\Snapshot2\Script2" -ItemType Directory).FullName
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
            $testSnapshotFolder = (New-Item "$($testNewParams.SnapshotFolder)\Snapshot1" -ItemType Directory).FullName
            $testSnapshot1 = (New-Item "$testSnapshotFolder\Script2" -ItemType Directory).FullName
            New-Item "$testSnapshot1\Export.csv" -ItemType file
            Start-Sleep -Milliseconds 1
            $testSnapshot2 = (New-Item "$($testNewParams.SnapshotFolder)\Snapshot2\Script2" -ItemType Directory).FullName
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