#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'NetworkCards.json'
    }

    Mock Get-DnsClient
    Mock Get-NetAdapter
    Mock Get-NetConnectionProfile
    Mock Set-NetConnectionProfile
    Mock Set-DnsClient
    Mock Rename-NetAdapter
    Mock Write-Output
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
        Mock Get-DnsClient {
            @(
                @{
                    InterfaceIndex           = '1'
                    ConnectionSpecificSuffix = 'CONTOSO.COM'
                }
                @{
                    InterfaceIndex           = '2'
                    ConnectionSpecificSuffix = ''
                }
            )
        }
        Mock Get-NetAdapter {
            @(
                @{
                    InterfaceIndex       = '1'
                    Name                 = 'Ethernet0'
                    InterfaceDescription = 'bla Broadcom bla'
                }
                @{
                    InterfaceIndex       = '2'
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
            It 'NetworkCardDnsSuffix' {
                $testBroadcomCard.NetworkCardDnsSuffix | 
                Should -Be 'CONTOSO.COM'
                $testIntelCard.NetworkCardDnsSuffix | 
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
    }
    Context 'the network card name is' {
        It 'renamed when it is wrong' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'WrongName'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'WrongName'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'NewName'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = $null
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Invoke Rename-NetAdapter -Times 1 -Exactly -ParameterFilter {
                ($Name -eq 'WrongName') -and
                ($NewName -eq 'NewName')
            }
            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                ($InputObject -eq "Renamed network card with description 'bla Intel bla' from 'WrongName' to 'NewName'") 
            }
        }
        It 'not renamed when it is correct' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = $null
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Rename-NetAdapter
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Renamed network card *") 
            }
        }
        It 'not renamed when NetworkCardName is null' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = $null
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = $null
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Rename-NetAdapter
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Renamed network card *") 
            }
        }
    }
    Context 'the network category is' {
        It 'corrected when it is wrong' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = 'Public'
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter {
                ($InterfaceIndex -eq '1') -and
                ($NetworkCategory -eq 'Public')
            }
            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                ($InputObject -eq "Changed network category on card 'LAN' from 'Private' to 'Public'") 
            }
        }
        It 'not corrected when it is correct' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = $null
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = 'Private'
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Set-NetConnectionProfile
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Changed network category*") 
            }
        }
        It 'not changed when NetworkCategory is null' {
            Mock Get-NetAdapter {
                @(
                    @{
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = $null
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Set-NetConnectionProfile
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Changed network category*") 
            }
        }
    }
    Context 'the network DNS suffix is' {
        It 'corrected when it is wrong' {
            Mock Get-DnsClient {
                @(
                    @{
                        InterfaceIndex           = '1'
                        ConnectionSpecificSuffix = ''
                    }
                )
            }
            Mock Get-NetAdapter {
                @(
                    @{
                        InterfaceIndex       = '1'
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = 'Private'
                    NetworkCardDnsSuffix   = 'CONTOSO.COM'
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Invoke Set-DnsClient -Times 1 -Exactly -ParameterFilter {
                ($InterfaceIndex -eq '1') -and
                ($ConnectionSpecificSuffix -eq 'CONTOSO.COM')
            }
            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                ($InputObject -eq "Changed DNS suffix for network card with id '1' and description 'bla Intel bla' from '' to 'CONTOSO.COM'") 
            }
        }
        It 'not corrected when it is correct' {
            Mock Get-DnsClient {
                @(
                    @{
                        InterfaceIndex           = '1'
                        ConnectionSpecificSuffix = 'CONTOSO.COM'
                    }
                )
            }
            Mock Get-NetAdapter {
                @(
                    @{
                        InterfaceIndex       = '1'
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = 'Private'
                    NetworkCardDnsSuffix   = 'CONTOSO.COM'
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Set-DnsClient
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Changed DNS suffix*") 
            }
        }
        It 'not changed when NetworkCardDnsSuffix is null' {
            Mock Get-DnsClient {
                @(
                    @{
                        InterfaceIndex           = '1'
                        ConnectionSpecificSuffix = 'CONTOSO.COM'
                    }
                )
            }
            Mock Get-NetAdapter {
                @(
                    @{
                        InterfaceIndex       = '1'
                        Name                 = 'LAN'
                        InterfaceDescription = 'bla Intel bla'
                    }
                )
            }
            Mock Get-NetConnectionProfile {
                @(
                    @{
                        InterfaceAlias  = 'LAN'
                        InterfaceIndex  = '1'
                        NetworkCategory = 'Private'
                    }
                )
            }
            ConvertTo-Json @(
                @{
                    NetworkCardName        = 'LAN'
                    NetworkCardDescription = 'Intel'
                    NetworkCategory        = 'Private'
                    NetworkCardDnsSuffix   = ''
                }
            ) | Out-File -FilePath $testFile

            .$testScript @testNewParams 

            Should -Not -Invoke Set-DnsClient
            Should -Not -Invoke Write-Output -ParameterFilter {
                ($InputObject -like "Changed DNS suffix*") 
            }
        }
    }
} 