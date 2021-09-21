#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testFolders = @(
        (New-Item 'TestDrive:/B/B1/B11' -ItemType Directory).FullName,
        (New-Item 'TestDrive:/C/C1' -ItemType Directory).FullName
    )
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action          = 'Import'
        DataFolder      = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        foldersFileName = 'folders.txt'
    }

    Mock Write-Output
}
AfterAll {
    $testFolders | Remove-Item
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of folders when' {
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
Describe 'Fail the import of Folders when' {
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
    It 'the data folder does not have the folders file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*Folders file '$($testNewParams.DataFolder)\$($testNewParams.foldersFileName)' not found"
    }
}
Describe "With Action set to 'Import'" {
    BeforeAll {
        $testJoinParams = @{
            Path      = $testParams.DataFolder
            ChildPath = $testParams.foldersFileName
        }
        $testFoldersFile = Join-Path @testJoinParams
        $testFolders | Out-File -FilePath $testFoldersFile

        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    It 'folders are created when they do not exist' {
        $testFolders | Remove-Item

        .$testScript @testNewParams

        foreach ($testFolder in $testFolders) {
            $testFolder | Should -Exist
            
            Should -Invoke Write-Output -ParameterFilter {
                $InputObject -eq "Folder '$testFolder' created"
            }
        }
    }
    It 'folders are left alone when they already exist' {
        foreach ($testFolder in $testFolders) {
            New-Item -Path $testFolder -ItemType Directory -EA Ignore
        }

        .$testScript @testNewParams

        foreach ($testFolder in $testFolders) {
            $testFolder | Should -Exist

            Should -Invoke Write-Output -ParameterFilter {
                $InputObject -eq "Folder '$testFolder' exists already"
            }
        }
    }
    Context 'non terminating errors are generated when' {
        It 'a folder cannot be created' {
            'wrong' | Out-File -FilePath $testFoldersFile

            $Error.Clear()
            .$testScript @testNewParams -EA SilentlyContinue

            $Error.Exception.Message | Where-Object {
                $_ -like "*Failed to create folder 'wrong': Path not valid"
            } | Should -Not -BeNullOrEmpty
        }
    }
}
Describe "With Action set to 'Export'" {
    BeforeAll {
        $testJoinParams = @{
            Path      = $testParams.DataFolder
            ChildPath = $testParams.foldersFileName
        }
        $testFoldersFile = Join-Path @testJoinParams
        $testFolders | Out-File -FilePath $testFoldersFile
    }
    It 'a template file is exported to the data folder' {
        $testFolders | Remove-Item

        .$testScript @testParams

        foreach ($testFolder in $testFolders) {
            $testFolder | Should -Exist
            
            Should -Invoke Write-Output -ParameterFilter {
                $InputObject -eq "Folder '$testFolder' created"
            }
        }
    }
}
