#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'testRegionalSettings.json'
    }
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export when' {
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
        $testFolder = (New-Item 'TestDrive:/B' -ItemType Directory).FullName 
        '1' | Out-File -LiteralPath "$testFolder\file.txt"

        $testNewParams.DataFolder = $testFolder

        { .$testScript @testNewParams } | 
        Should -Throw "*Export folder '$testFolder' not empty"
    }
}
Describe 'Fail the import when' {
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
    It 'the data folder does not have the .json file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\test.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*Import file '$($testNewParams.DataFolder)\$($testNewParams.FileName)' not found"
    }
}
Describe "when action is 'Export'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'

        .$testScript @testNewParams

        $testExportFile = (Get-ChildItem $testNewParams.DataFolder | 
        Where-Object { $_.Name -eq "$($testNewParams.FileName)" }).FullName
    }
    It 'a .json file is created in the data folder' {
        $testExportFile | Should -Exist
        $testExportFile | Should -Not -BeNullOrEmpty

        {
            Get-Content -Path $testExportFile -Raw | ConvertFrom-Json -EA Stop
        } | Should -Not -Throw
    }
    Context 'the .json file contains the property' {
        BeforeAll {
            $testJson = Get-Content -Path $testExportFile -Raw | 
            ConvertFrom-Json
        }
        It 'WinSystemLocaleName' {
            $testJson.WinSystemLocaleName | Should -Not -BeNullOrEmpty
        }
        It 'TimeZoneId' {
            $testJson.TimeZoneId | Should -Not -BeNullOrEmpty
        }
        It 'WinHomeLocationGeoId' {
            $testJson.WinHomeLocationGeoId | Should -Not -BeNullOrEmpty
        }
        It 'CultureName' {
            $testJson.CultureName | Should -Not -BeNullOrEmpty
        }
    }
}
Describe "when action is 'Import'" {
    BeforeAll {
        $testFile = "$($testParams.DataFolder)\$($testParams.FileName)"
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'an error is generated when' {
        It 'the field From is missing' {
            ConvertTo-Json @(
                @{
                    From = ''
                    To   = $testParams.DataFolder
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*Failed to copy from '' to '$($testParams.DataFolder)': The field 'From' is required"
        }
        It 'the field To is missing' {
            ConvertTo-Json @(
                @{
                    From = $testParams.DataFolder
                    To   = ''
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*Failed to copy from '$($testParams.DataFolder)' to '': The field 'To' is required"
        }
        It 'the source file or folder is not found' {
            ConvertTo-Json @(
                @{
                    From = 'Non existing'
                    To   = $testParams.DataFolder
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*Failed to copy from 'Non existing' to '$($testParams.DataFolder)': File or folder '$($testParams.DataFolder)\Non existing' not found"

            ConvertTo-Json @(
                @{
                    From = 'C:\Non existing'
                    To   = $testParams.DataFolder
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*Failed to copy from 'C:\Non existing' to '$($testParams.DataFolder)': File or folder 'C:\Non existing' not found"
        }
    }
    Context 'and the source is a file it is copied to the destination folder' {
        It 'when the folder already exists' {
            $testNewItemParams = @{
                Path     = Join-Path $testParams.DataFolder 'Destination'
                ItemType = 'Directory'
            }
            New-Item @testNewItemParams
            ConvertTo-Json @(
                @{
                    From = $testFile
                    To   = $testNewItemParams.Path
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            "$($testNewItemParams.Path)\$($testParams.FileName)" | Should -Exist
        }
        It 'when the folder does not exist' {
            $notExistingFolder = Join-Path $testParams.DataFolder 'NotExistingFolder'
            
            ConvertTo-Json @(
                @{
                    From = $testFile
                    To   = "$notExistingFolder\$($testParams.FileName)"
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            "$notExistingFolder\$($testParams.FileName)" | Should -Exist
        }
    }
    Context 'and the source is a folder the content of the source folder is copied to the destination folder' {
        BeforeAll {
            $testSourceParams = @{
                Path     = Join-Path $testParams.DataFolder 'SourceFolder'
                ItemType = 'Directory'
            }
            New-Item @testSourceParams

            '1' | Out-File -FilePath "$($testSourceParams.Path)\test.txt"
        }
        It 'when the folder already exists' {
            $testDestinationParams = @{
                Path     = Join-Path $testParams.DataFolder 'DestinationFolder'
                ItemType = 'Directory'
            }
            New-Item @testDestinationParams

            ConvertTo-Json @(
                @{
                    From = $testSourceParams.Path
                    To   = $testDestinationParams.Path
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            "$($testDestinationParams.Path)\test.txt" | Should -Exist
        } -Tag test
        It 'when the folder does not exist' {
            $notExistingFolder = Join-Path $testParams.DataFolder 'NotExistingFolder'
            
            ConvertTo-Json @(
                @{
                    From = $testSourceParams.Path
                    To   = $notExistingFolder
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            "$notExistingFolder\test.txt" | Should -Exist
        }
    }
} -Skip