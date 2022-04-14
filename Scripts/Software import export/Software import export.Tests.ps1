#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action         = 'Import'
        DataFolder     = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        ImportFileName = 'testImportFile.json'
    }

    $testJoinParams = @{
        Path      = $testParams.DataFolder
        ChildPath = $testParams.ImportFileName
    }
    $testFile = Join-Path @testJoinParams
    
    Function Remove-ApplicationHC {
        Param (
            [Parameter(Mandatory)]
            [String]$ApplicationName,
            [Parameter(Mandatory)]
            [String]$UninstallString
        )
    }
    Function Get-InstalledApplicationsHC {}

    Mock Get-InstalledApplicationsHC {
        [PSCustomObject]@{
            DisplayName          = 'Notepad++ (64-bit x64)'
            DisplayVersion       = '8.3.3'
            Publisher            = 'Notepad++ Team'
            UninstallString      = "C:\Program Files\Notepad++\uninstall.exe"
            QuietUninstallString = '"C:\Program Files\Notepad++\uninstall.exe" /S'
            InstallDate          = $null
        }
    }
    Mock Remove-ApplicationHC
    Mock Start-Process
    Mock Write-Output
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of the software packages file when' {
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
Describe 'Fail the import of the software packages file when' {
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
    It 'the data folder does not have the input file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*Input file '$($testNewParams.DataFolder)\$($testNewParams.ImportFileName)' not found"
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
    It 'output is generated' {
        Should -Invoke Write-Output -Exactly -Times 1 -Scope Describe -ParameterFilter {
            $InputObject -like 'Created example file*'
        }
    }
} -Tag test
Describe "With Action set to 'Import'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'software packages are removed' {
        BeforeAll {
            $testKey = @{
                Path  = 'TestRegistry:\testPath'
                Name  = 'testName'
                Value = '1'
                Type  = 'DWORD'
            }
            @{
                RunAsCurrentUser = @{
                    RegistryKeys = @($testKey)
                }
                RunAsOtherUser   = $null
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

            .$testScript @testNewParams
        
            $testGetParams = @{
                Path = $testKey.Path
                Name = $testKey.Name
            }
            
        }
        It 'when installed path is created' {
            $testKey.Path | Should -Exist
        }
        It 'the key name is created' {
            $actual | Should -Not -BeNullOrEmpty
        }
        It 'the key value is set' {
            $actual.($testKey.Name) | Should -Be $testKey.Value
        }
        It 'output is generated' {
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Describe -ParameterFilter {
                $InputObject -eq "Registry path '$($testKey.Path)' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)' did not exist. Created new registry key."
            }
        }
    }
}