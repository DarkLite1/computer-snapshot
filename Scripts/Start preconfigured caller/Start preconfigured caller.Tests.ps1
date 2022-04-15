#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        StartScript                = (New-Item 'TestDrive:/testStartScript.ps1' -ItemType File).FullName 
        PreconfiguredCallersFolder = (New-Item 'TestDrive:/testCallers' -ItemType Directory).FullName 
    }

    $testJoinParams = @{
        Path      = $testParams.PreconfiguredCallersFolder
        ChildPath = 'testCaller.json'
    }
    $testFile = Join-Path @testJoinParams
    
    Mock Write-Output
    Mock Start-Sleep
}
Describe 'the script fails when' {
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'
    }
    It 'the start script is not found' {
        $testNewParams.StartScript = 'TestDrive:/xxx.ps1'

        { .$testScript @testNewParams } | 
        Should -Throw "*Start script 'TestDrive:/xxx.ps1' not found"
    }
    It 'the preconfigured callers folder is not found' {
        $testNewParams.PreconfiguredCallersFolder = 'TestDrive:/xxx'

        { .$testScript @testNewParams } | 
        Should -Throw "*Preconfigured callers folder 'TestDrive:/xxx' not found"
    }
    It 'the preconfigured callers folder has no .JSON file' {
        '1' | Out-File -LiteralPath "$($testParams.PreconfiguredCallersFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*No .JSON file found in folder '$($testParams.PreconfiguredCallersFolder)'. Please create a pre-configuration file first."
    }
}