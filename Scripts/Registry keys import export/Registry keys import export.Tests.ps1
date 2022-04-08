#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    Function Push-AclInheritanceHC {
        <#
            .SYNOPSIS
                Function to push the same permissions as the top folder to all of its subfolders and files.
        
            .DESCRIPTION
                This function erases the permissions of the subfolders and files and activates the inheritance on all of them,  so they have the same permissions as the top folder. In the process the local administrator is added with 'Full control' permissions on every subfolder and file, and he is added as 'Owner' of all the files and folders.
        
            .PARAMETER Target
                The top folder under which all the subfolders and files will inherit their permissions from.
        
            .EXAMPLE
                Push-AclInheritanceHC 'T:\Departments\Finance\Reports'
                All subfolders of 'Reports' will receive the same permissions as the folder 'Reports' itself, this includes files.
#>
        
        [CmdletBinding(SupportsShouldProcess = $True)]
        Param (
            [parameter(Mandatory = $true, HelpMessage = 'The path where we need to activate inheritance on all of its subfolders')]
            [ValidateScript({ Test-Path $_ -PathType Container })]
            [String]$Target
        )
        
        Begin {
            $ReadFolder = New-Item -Type Directory -Path "$env:TEMP\ACLfolder"
            $ReadFile = New-Item -Type File -Path "$env:TEMP\ACLfile"
        
            $AdjustTokenPrivileges = @"
        using System;
        using System.Runtime.InteropServices;
        
         public class TokenManipulator
         {
          [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
          internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
          ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
          [DllImport("kernel32.dll", ExactSpelling = true)]
          internal static extern IntPtr GetCurrentProcess();
          [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
          internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr
          phtok);
          [DllImport("advapi32.dll", SetLastError = true)]
          internal static extern bool LookupPrivilegeValue(string host, string name,
          ref long pluid);
          [StructLayout(LayoutKind.Sequential, Pack = 1)]
          internal struct TokPriv1Luid
          {
           public int Count;
           public long Luid;
           public int Attr;
          }
          internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
          internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
          internal const int TOKEN_QUERY = 0x00000008;
          internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
          public static bool AddPrivilege(string privilege)
          {
           try
           {
            bool retVal;
            TokPriv1Luid tp;
            IntPtr hproc = GetCurrentProcess();
            IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
            tp.Count = 1;
            tp.Luid = 0;
            tp.Attr = SE_PRIVILEGE_ENABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
            retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return retVal;
           }
           catch (Exception ex)
           {
            throw ex;
           }
          }
          public static bool RemovePrivilege(string privilege)
          {
           try
           {
            bool retVal;
            TokPriv1Luid tp;
            IntPtr hproc = GetCurrentProcess();
            IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
            tp.Count = 1;
            tp.Luid = 0;
            tp.Attr = SE_PRIVILEGE_DISABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
            retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return retVal;
           }
           catch (Exception ex)
           {
            throw ex;
           }
          }
         }
"@
        
        }
        
        Process {
            # Folders
            Get-ChildItem -Path $Target -Directory -Recurse | Select-Object -ExpandProperty FullName |
            ForEach-Object {
                Write-Verbose $_
                Add-Type $AdjustTokenPrivileges
                $Folder = Get-Item $_
                [void][TokenManipulator]::AddPrivilege("SeRestorePrivilege")
                [void][TokenManipulator]::AddPrivilege("SeBackupPrivilege")
                [void][TokenManipulator]::AddPrivilege("SeTakeOwnershipPrivilege")
                $Owner = New-Object System.Security.AccessControl.DirectorySecurity
                $Admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
                $Owner.SetOwner($Admin)
                $Folder.SetAccessControl($Owner)
        
                # Add folder Admins to ACL with Full Control to descend folder structure
                $acl = Get-Acl -Path $ReadFolder
                $aclr = New-Object  system.security.accesscontrol.filesystemaccessrule("BUILTIN\Administrators", "FullControl", "Allow")
                $acl.SetAccessRule($aclr)
                Set-Acl $_ $acl
            }
            Remove-Item $ReadFolder
        
        
            # Files
            Get-ChildItem -Path $Target -File -Recurse | Select-Object -ExpandProperty FullName |
            ForEach-Object {
                Write-Verbose $_
                $Admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
                $Owner = New-Object System.Security.AccessControl.FileSecurity
                $Owner.SetOwner($Admin)
                [System.IO.File]::SetAccessControl($_, $Owner)
        
                # Add file Admins to ACL with Full Control and activate inheritance
                $acl = Get-Acl -Path $ReadFile
                $aclr = New-Object  system.security.accesscontrol.filesystemaccessrule("BUILTIN\Administrators", "FullControl", "Allow")
                $acl.SetAccessRule($aclr)
                Set-Acl $_ $acl
            }
            Remove-Item $ReadFile
        }
    }

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

        if (Test-Path $testProfileFolder) {
            # Push-AclInheritanceHC $testProfileFolder
            Remove-Item $testProfileFolder -Recurse -Force
        }
        if (Get-LocalUser $testUserName -EA Ignore) {
            Remove-LocalUser $testUserName 
        }
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
        #endregion

        # Get-ChildItem $testProfileFolder | ForEach-Object {
        #     If ([System.IO.File]::Exists($_.FullName)) {
        #         $FileStream = [System.IO.File]::Open(
        #             $testNtUserFile, 'Open', 'Write')
          
        #         $FileStream.Close()
        #         $FileStream.Dispose()
        #     }
        # }
        # Start-Sleep -sec 5
        # Remove-LocalUser $testUserName
        # Remove-Item -Path $testProfileFolder -Recurse -Force
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