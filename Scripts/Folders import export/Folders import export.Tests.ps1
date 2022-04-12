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
        foldersFileName = 'testCreateFolders.json'
    }

    $testJoinParams = @{
        Path      = $testParams.DataFolder
        ChildPath = $testParams.foldersFileName
    }
    $testFile = Join-Path @testJoinParams

    Mock Write-Output
}
AfterAll {
    $testFile | Remove-Item -EA Ignore
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
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'

        $testFolders | Remove-Item -EA Ignore
    }
    It 'folders are created when they do not exist' {
        @{
            FolderPaths = @($testFolders)
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

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
            New-Item -Path $testFolder -ItemType Directory
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
            @{
                FolderPaths = @('wrong')
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

            $Error.Clear()
            .$testScript @testNewParams -EA SilentlyContinue

            $Error.Exception.Message | Where-Object {
                $_ -like "*Failed to create folder 'wrong': Path not valid"
            } | Should -Not -BeNullOrEmpty
        }
    }
    Context 'terminating errors are generated when' {
        It "the property 'FolderPaths' is empty in the .JSON file" {
            @{
                NotImportant = @('wrong')
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile


            {.$testScript @testNewParams} | Should -Throw "*Property 'FolderPaths' is empty, no folder to create. Please update the input file '$testFile'*"
        }
    }
}
Describe "With Action set to 'Export'" {
    BeforeAll {
        $testFile | Remove-Item -EA Ignore

        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'

        .$testScript @testNewParams
    }
    It 'a valid json file is created' {
        $testFile | Should -Exist
        { Get-Content $testFile -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'the .json file is a copy of Example.json' {
        $testJsonFile = Get-Content $testFile -Raw
        $testExampleJsonFile = Get-Content (Join-Path $PSScriptRoot 'Example.json') -Raw

        $testJsonFile | Should -Be $testExampleJsonFile
    }
}
