#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'testRegionalSettings.json'
    }

    Function Start-ScriptHC {
        Param (
            [Parameter(Mandatory)]
            [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
            [String]$Path
        )
    }

    Mock Get-WinSystemLocale {
        @{Name = 'en-US' }
    }
    Mock Get-TimeZone {
        @{Id = 'Sao Tome Standard Time' }
    }
    Mock Get-WinHomeLocation {
        @{GeoId = '200' }
    }
    Mock Get-Culture {
        @{Name = 'en-GB' }
    }
    Mock Set-WinSystemLocale
    Mock Set-TimeZone
    Mock Set-WinHomeLocation
    Mock Set-Culture
    Mock Start-ScriptHC
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
            $testJson.WinSystemLocaleName | Should -Be 'en-US'
        }
        It 'TimeZoneId' {
            $testJson.TimeZoneId | Should -Be 'Sao Tome Standard Time'
        }
        It 'WinHomeLocationGeoId' {
            $testJson.WinHomeLocationGeoId | Should -Be 200
        }
        It 'CultureName' {
            $testJson.CultureName | Should -Be 'en-GB'
        }
    }
}
Describe "when action is 'Import'" {
    BeforeAll {
        $testFile = "$($testParams.DataFolder)\$($testParams.FileName)"
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'a terminating error is generated when' {
        It 'the field WinSystemLocaleName is missing' {
            ConvertTo-Json @(
                @{
                    # WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'Central Europe Standard Time'
                    CultureName          = 'en-US'
                    WinHomeLocationGeoId = 244
                    
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'WinSystemLocaleName' is required"
        }
        It 'the field TimeZoneId is missing' {
            ConvertTo-Json @(
                @{
                    WinSystemLocaleName  = 'en-US'
                    # TimeZoneId           = 'Central Europe Standard Time'
                    CultureName          = 'en-US'
                    WinHomeLocationGeoId = 244
                    
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'TimeZoneId' is required"
        }
        It 'the field CultureName is missing' {
            ConvertTo-Json @(
                @{
                    WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'Central Europe Standard Time'
                    # CultureName          = 'en-US'
                    WinHomeLocationGeoId = 244
                    
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'CultureName' is required"
        }
        It 'the field WinHomeLocationGeoId is missing' {
            ConvertTo-Json @(
                @{
                    WinSystemLocaleName = 'en-US'
                    TimeZoneId          = 'Central Europe Standard Time'
                    CultureName         = 'en-US'
                    # WinHomeLocationGeoId = 244
                    
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } | 
            Should -Throw "*The field 'WinHomeLocationGeoId' is required"
        }
        It 'the NewAccountsScriptName file is not found' {
            $testNewParams2 = $testParams.clone()
            $testNewParams2.Action = 'Import'
            $testNewParams2.NewAccountsScriptName = 'xxx.ps1'
    
            ConvertTo-Json @(
                @{
                    WinSystemLocaleName  = 'en-US'
                    TimeZoneId           = 'Central Europe Standard Time'
                    CultureName          = 'en-US'
                    WinHomeLocationGeoId = 244
                    
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams2 } | 
            Should -Throw "*Script file '*\xxx.ps1' not found"
        }
    }
    Context 'Regional settings are applied by calling' {
        BeforeAll {
            ConvertTo-Json @(
                @{
                    WinSystemLocaleName  = 'de-DE'
                    TimeZoneId           = 'Central Europe Standard Time'
                    CultureName          = 'nl-BE'
                    WinHomeLocationGeoId = 244
                }
            ) | Out-File -FilePath $testFile

            { .$testScript @testNewParams -EA Stop } |
            Should -Not -Throw
        }
        It 'Set-WinSystemLocale' {
            Should -Invoke Set-WinSystemLocale -Times 1 -Exactly -Scope Context -ParameterFilter {
                $SystemLocale -eq 'de-DE'
            }
        }
        It 'Set-TimeZone' {
            Should -Invoke Set-TimeZone -Times 1 -Exactly -Scope Context -ParameterFilter {
                $Id -eq 'Central Europe Standard Time'
            }
        }
        It 'Set-WinHomeLocation' {
            Should -Invoke Set-WinHomeLocation -Times 1 -Exactly -Scope Context -ParameterFilter {
                $GeoId -eq '244'
            }
        }
        It 'Set-Culture' {
            Should -Invoke Set-Culture -Times 1 -Exactly -Scope Context -ParameterFilter {
                $CultureInfo -eq 'nl-BE'
            }
        }
        It 'Start-ScriptHC for newly created accounts' {
            Should -Invoke Start-ScriptHC -Times 1 -Exactly -Scope Context -ParameterFilter {
                $Path -like '*\Regional settings new accounts.ps1'
            }
        }
    }
}