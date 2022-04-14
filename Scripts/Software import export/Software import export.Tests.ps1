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

    $testJoinParams = @{
        Path      = $testParams.DataFolder
        ChildPath = 'Software'
    }
    $testSoftwareFolder = Join-Path @testJoinParams
    
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
    It 'the software folder is empty' {
        @{
            SoftwarePackages = @{
                Remove  = $null
                Install = $null
            }
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

        { 
            .$testScript @testNewParams 
        } | 
        Should -Throw "*Software folder '$testSoftwareFolder' empty"
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
    It 'an empty Software folder is created' {
        $testSoftwareFolder | Should -Exist
    }
} 
Describe "With Action set to 'Import'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'software packages are removed' {
        BeforeAll {
            New-Item -Path $testSoftwareFolder -ItemType Directory
            '1' | Out-File -FilePath "$testSoftwareFolder\package1.exe"

            Mock Get-InstalledApplicationsHC {
                [PSCustomObject]@{
                    DisplayName          = 'Package1'
                    UninstallString      = "C:\Program Files\app\uninstall.exe"
                    QuietUninstallString = '"C:\Program Files\app\install.exe" /S'
                }
            }

            @{
                SoftwarePackages = @{
                    Remove  = @('Package1')
                    Install = $null
                }
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

            .$testScript @testNewParams
        }
        It 'when their name is in the Remove property' {
            Should -Invoke Remove-ApplicationHC -Scope Context -Times 1 -Exactly -ParameterFilter {
                ($ApplicationName -eq 'Package1') -and
                ($UninstallString -eq '"C:\Program Files\app\install.exe" /S')
            }
        }
    }
    Context 'software packages are installed' {
        BeforeAll {
            New-Item -Path $testSoftwareFolder -ItemType Directory
            '1' | Out-File -FilePath "$testSoftwareFolder\package1.exe"

            @{
                SoftwarePackages = @{
                    Remove  = $null
                    Install = @(
                        @{
                            ExecutableName = "package1.exe"
                            Arguments      = '\x \x \z'
                        }
                    )
                }
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

            .$testScript @testNewParams
        }
        It 'when their ExecutableName is in the Install property' {
            Should -Invoke Start-Process -Scope Context -Times 1 -Exactly -ParameterFilter {
                ($FilePath -eq "$testSoftwareFolder\Package1.exe") -and
                ($ArgumentList -eq '\x \x \z')
            }
        }
        It 'output is generated' {
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                $InputObject -like "Installed executable 'package1.exe' with arguments '\x \x \z'"
            }
        }
    }
}