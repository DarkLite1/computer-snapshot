#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'testCopy.json'
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
    }
    It 'create an example .json import file in the data folder' {
        $testFile = "$($testNewParams.DataFolder)\$($testNewParams.FileName)"
        $testFile | Should -Exist
        {
            Get-Content -Path $testFile -Raw | ConvertFrom-Json -EA Stop
        } | Should -Not -Throw
    }
    It 'create an example copy file in the data folder' {
        $testFile = "$($testNewParams.DataFolder)\Monitor SSD.ps1"
        $testFile | Should -Exist
    }
}
Describe "when action is 'Import'" {
    Context 'an non terminating error is generated when' {
        BeforeAll {
            $testFile = "$($testParams.DataFolder)\$($testParams.FileName)"
            $testNewParams = $testParams.clone()
            $testNewParams.Action = 'Import'
        }
        It 'the field To is missing' {
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
    }
} -Tag test