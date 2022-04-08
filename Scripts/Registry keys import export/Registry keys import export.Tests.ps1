#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action               = 'Import'
        DataFolder           = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        RegistryKeysFileName = 'testRegKeys.json'
    }

    $testJoinParams = @{
        Path      = $testParams.DataFolder
        ChildPath = $testParams.RegistryKeysFileName
    }
    $testFile = Join-Path @testJoinParams
    
    Mock Write-Output
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of the registry keys file when' {
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
Describe 'Fail the import of the registry keys file when' {
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
    It 'the data folder does not have the registry keys file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*registry keys file '$($testNewParams.DataFolder)\$($testNewParams.RegistryKeysFileName)' not found"
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
            $InputObject -like 'Created example registry keys file*'
        }
    }
}
Describe "With Action set to 'Import' for 'RunAsCurrentUser'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'
    }
    Context 'and the registry path does not exist' {
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
            $actual = Get-ItemProperty @testGetParams
        }
        It 'the path is created' {
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
    Context 'and the registry path exists' {
        Context 'but the key name does not exist' {
            BeforeAll {
                $testKey = @{
                    Path  = 'TestRegistry:\testPath'
                    Name  = 'testNameSomethingElse'
                    Value = '2'
                    Type  = 'DWORD'
                }
                @{
                    RunAsCurrentUser = @{
                        RegistryKeys = @($testKey)
                    }
                    RunAsOtherUser   = $null
                } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

                $null = New-Item -Path $testKey.Path -Force

                .$testScript @testNewParams
        
                $testGetParams = @{
                    Path = $testKey.Path
                    Name = $testKey.Name
                }
                $actual = Get-ItemProperty @testGetParams
            }
            It 'the path is still there' {
                $testKey.Path | Should -Exist
            }
            It 'the key name is created' {
                $actual | Should -Not -BeNullOrEmpty
            }
            It 'the key value is set' {
                $actual.($testKey.Name) | Should -Be $testKey.Value
            }
            It 'output is generated' {
                Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                    $InputObject -eq "Registry path '$($testKey.Path)' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)'. Created key name and value on existing path."
                }
            }
        }
        Context 'and the key name exists but the value is wrong' {
            BeforeAll {
                $testKey = @{
                    Path  = 'TestRegistry:\testPath'
                    Name  = 'testNameSomethingElse'
                    Value = '3'
                    Type  = 'DWORD'
                }
                @{
                    RunAsCurrentUser = @{
                        RegistryKeys = @($testKey)
                    }
                    RunAsOtherUser   = $null
                } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

                $null = New-Item -Path $testKey.Path -Force

                $testNewItemParams = @{
                    Path  = $testKey.Path
                    Name  = $testKey.Name
                    Value = '5'
                    Type  = $testKey.Value
                }
                $null = New-ItemProperty @testNewItemParams

                .$testScript @testNewParams
        
                $testGetParams = @{
                    Path = $testKey.Path
                    Name = $testKey.Name
                }
                $actual = Get-ItemProperty @testGetParams
            }
            It 'the path is still there' {
                $testKey.Path | Should -Exist
            }
            It 'the key name is still correct' {
                $actual | Should -Not -BeNullOrEmpty
            }
            It 'the key value is updated' {
                $actual.($testKey.Name) | Should -Be $testKey.Value
            }
            It 'output is generated' {
                Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                    $InputObject -eq "Registry path '$($testKey.Path)' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)' not correct. Updated old value '$($testNewItemParams.Value)' with new value '$($testKey.Value)'."
                }
            }
        }
        Context 'and the complete registry key is correct' {
            BeforeAll {
                $testKey = @{
                    Path  = 'TestRegistry:\testPath'
                    Name  = 'testNameSomethingElse'
                    Value = '3'
                    Type  = 'DWORD'
                }
                @{
                    RunAsCurrentUser = @{
                        RegistryKeys = @($testKey)
                    }
                    RunAsOtherUser   = $null
                } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

                $null = New-Item -Path $testKey.Path -Force
                $null = New-ItemProperty @testKey

                .$testScript @testNewParams
        
                $testGetParams = @{
                    Path = $testKey.Path
                    Name = $testKey.Name
                }
                $actual = Get-ItemProperty @testGetParams
            }
            It 'the path is still there' {
                $testKey.Path | Should -Exist
            }
            It 'the key name still exists' {
                $actual | Should -Not -BeNullOrEmpty
            }
            It 'the key value is still correct' {
                $actual.($testKey.Name) | Should -Be $testKey.Value
            }
            It 'output is generated' {
                Should -Invoke Write-Output -Exactly -Times 1 -Scope Context -ParameterFilter {
                    $InputObject -eq "Registry path '$($testKey.Path)' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)' correct. Nothing to update."
                }
            }
        }
    }
    Context 'a non terminating error is created when' {
        It 'a registry key can not be created' {
            $testKey = @{
                Path  = 'TestRegistry:\testPath'
                Name  = 'testNameSomethingElse'
                Value = 'stringWhereNumberIsExpected'
                Type  = 'DWORD'
            }
            @{
                RunAsCurrentUser = @{
                    RegistryKeys = @($testKey)
                }
                RunAsOtherUser   = $null
            } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile

            Mock Write-Error
        
            .$testScript @testNewParams

            Should -Invoke Write-Error -Exactly -Times 1 -ParameterFilter {
                $Message -like "Failed to set registry path '$($testKey.Path)' with key name '$($testKey.Name)' to value '$($testKey.Value)' with type '$($testKey.Type)':*"
            }
        }
    }
}
Describe "With Action set to 'Import' for 'RunAsOtherUser'" {
    BeforeAll {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Import'

        #region Create test user
        $testUserName = 'pesterTestUser'
        $testUserPassword = 'te2@!Dst' 

        $testSecurePassword = ConvertTo-SecureString $testUserPassword -AsPlainText -Force
        $testCredential = New-Object System.Management.Automation.PSCredential $testUserName, $testSecurePassword

        $testProfileFolder = "C:\Users\$testUserName"

        Remove-Item $testProfileFolder -Recurse -Force -EA Ignore
        Remove-LocalUser $testUserName -EA Ignore
        New-LocalUser $testUserName -Password $testSecurePassword
        #endregion

        #region Create test .json file
        $testKey = @{
            Path  = 'HKCU:\testPath'
            Name  = 'testName'
            Value = '1'
            Type  = 'DWORD'
        }
        @{
            RunAsCurrentUser = @{
                RegistryKeys = $null
            }
            RunAsOtherUser   = @{
                UserName     = $testUserName  
                UserPassword = $testUserPassword  
                RegistryKeys = @($testKey)
            }
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $testFile
        #endregion

        .$testScript @testNewParams

        $testNtUserFile = "C:\Users\$testUserName\NTUSER.DAT"
        $testTempKey = "HKEY_USERS\$testUserName"

        #region Load other user's profile
        $testStartParams = @{
            FilePath     = 'reg.exe'
            ArgumentList = "load `"$testTempKey`" `"$testNtUserFile`"" 
            WindowStyle  = 'Hidden'
            Wait         = $true
        }
        Start-Process @testStartParams
        #endregion
    
        $testGetParams = @{
            Path = "Registry::HKEY_USERS\$testUserName\testPath"
            Name = $testKey.Name
        }
        $actual = Get-ItemProperty @testGetParams
    }
    AfterAll {
        #region Unload user's profile
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()

        $startParams = @{
            FilePath     = 'reg.exe'
            ArgumentList = "unload `"$testTempKey`""
            WindowStyle  = 'Hidden'
            Wait         = $true
        }
        $testProcess = Start-Process @startParams
        if ($testProcess.ExitCode) {
            throw "Failed to unload the test temporary profile: exit code $($testProcess.ExitCode)"
        }

        Remove-Item $testProfileFolder -Recurse -Force -EA Ignore
        Remove-LocalUser $testUserName -EA Ignore
        #endregion
    }
    Context 'and the registry path does not exist' {
        It 'the path is created' {
            $testGetParams.Path | Should -Exist
        } 
        It 'the key name is created' {
            $actual | Should -Not -BeNullOrEmpty
        }
        It 'the key value is set' {
            $actual.($testKey.Name) | Should -Be $testKey.Value
        }
        It 'output is generated' {
            Should -Invoke Write-Output -Exactly -Times 1 -Scope Describe -ParameterFilter {
                $InputObject -eq "Registry path 'Registry::HKEY_USERS\$testUserName\testPath' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)' did not exist. Created new registry key."
            }
            # Should -Invoke Write-Output -Exactly -Times 1 -Scope Describe -ParameterFilter {
            #     $InputObject -eq "Registry path 'HKU:\$testUserName\testPath' key name '$($testKey.Name)' value '$($testKey.Value)' type '$($testKey.Type)' did not exist. Created new registry key."
            # }
        }
    } 
} -Tag test