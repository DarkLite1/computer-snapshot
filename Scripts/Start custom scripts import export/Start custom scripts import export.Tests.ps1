#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
    }

    Function Invoke-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )
    }
    Mock Invoke-ScriptHC
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
        '1' | Out-File -LiteralPath "$testFolder\file.ps1"

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
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\test.txt"
        { .$testScript @testNewParams } | 
        Should -Throw "*Import folder '$($testNewParams.DataFolder)' empty: No PowerShell files found"
    }
}
Describe "when action is 'Export'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'

        .$testScript @testNewParams 
    }
    It 'create example .ps1 files in the data folder' {
        Get-ChildItem -Path $testNewParams.DataFolder -Filter '*.ps1' |
        Should -Not -BeNullOrEmpty
    }
}
Describe "when action is 'Import'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'

        's1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\test1.ps1"
        's2' | Out-File -LiteralPath "$($testNewParams.DataFolder)\test2.ps1"
    }
    It 'each script in the data folder is executed' {
        .$testScript @testNewParams
        Should -Invoke Invoke-ScriptHC -Exactly -Times 2 -Scope Describe
    }
} -Tag test