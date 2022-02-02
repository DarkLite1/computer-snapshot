#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'NetworkCards.json'
    }

    Mock Get-NetAdapter
    Mock Get-NetConnectionProfile
    Mock Set-NetConnectionProfile
    Mock Rename-NetAdapter
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
        Mock Get-NetAdapter {
            @(
                @{
                    Name                 = 'Ethernet0'
                    InterfaceDescription = 'bla Broadcom bla'
                }
                @{
                    Name                 = 'Ethernet1'
                    InterfaceDescription = 'bla Intel bla'
                }
            )
        }
        Mock Get-NetConnectionProfile {
            @(
                @{
                    InterfaceAlias  = 'Ethernet0'
                    InterfaceIndex  = '1'
                    NetworkCategory = 'Private'
                }
            )
        }
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
    Context 'the .json file contains' {
        BeforeAll {
            $testJson = Get-Content -Path $testExportFile -Raw | 
            ConvertFrom-Json
            $testBroadcomCard = $testJson | Where-Object {
                $_.NetworkCardDescription -like '*Broadcom*'
            }
            $testIntelCard = $testJson | Where-Object {
                $_.NetworkCardDescription -like '*Intel*'
            }
        }
        It 'an object for each network card' {
            $testJson | Should -HaveCount 2
            $testBroadcomCard | Should -Not -BeNullOrEmpty
            $testIntelCard | Should -Not -BeNullOrEmpty
        }
        Context 'the property' {
            It 'NetworkCardName' {
                $testBroadcomCard.NetworkCardName | 
                Should -Be 'Ethernet0'
                $testIntelCard.NetworkCardName | 
                Should -Be 'Ethernet1'
            }
            It 'NetworkCardDescription' {
                $testBroadcomCard.NetworkCardDescription | 
                Should -Be 'bla Broadcom bla'
                $testIntelCard.NetworkCardDescription | 
                Should -Be 'bla Intel bla'
            }
            It 'NetworkCategory' {
                $testBroadcomCard.NetworkCategory | 
                Should -Be 'Private'
                $testIntelCard.NetworkCategory | 
                Should -BeNullOrEmpty
            }
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
        It 'the field NetworkCardName is missing' {
            ConvertTo-Json @(
                @{
                    # NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel card'
                    NetworkCategory        = 'Private'
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'NetworkCardName' is required"
        }
        It 'the field NetworkCardDescription is missing' {
            ConvertTo-Json @(
                @{
                    NetworkCardName = 'LAN'
                    # NetworkCardDescription = 'Intel card'
                    NetworkCategory = $null
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'NetworkCardDescription' is required"
        }
        It 'the field NetworkCategory is missing' {
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel card'
                    # NetworkCategory        = 'Private'
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'NetworkCategory' is required"
        }
    } -Tag test
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
} 