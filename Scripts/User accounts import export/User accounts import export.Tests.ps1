#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'UserAccounts.csv'
    }
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of user accounts when' {
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
Describe 'Fail the import of user accounts when' {
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
    It 'the data folder does not have the user accounts file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*user accounts file '$($testNewParams.DataFolder)\$($testNewParams.FileName)' not found"
    }
}
# Describe 'when all tests pass call the function' {
#     It "'Export-FirewallRulesHC' on action 'Export'" {
#         Get-ChildItem $testParams.DataFolder | Remove-Item
#         $testNewParams = $testParams.clone()
#         $testNewParams.Action = 'Export'

#         .$testScript @testNewParams 

#         Should -Invoke Export-FirewallRulesHC -Times 1 -Exactly
#     }
#     It "'Import-FirewallRulesHC' on action 'Export'" {
#         Get-ChildItem $testParams.DataFolder | Remove-Item
#         $testNewParams = $testParams.clone()
#         $testNewParams.Action = 'Import'
#         New-Item -Path "$($testParams.DataFolder)\$($testParams.FileName)" -ItemType File

#         .$testScript @testNewParams 

#         Should -Invoke Import-FirewallRulesHC -Times 1 -Exactly
#     }
# }