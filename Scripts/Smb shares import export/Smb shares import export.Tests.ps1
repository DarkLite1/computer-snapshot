#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testLocalUserNames = @('TestUser1', 'TestUser2')
    $testSmbShareName = 'TestShare'
    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action                  = 'Export'
        DataFolder              = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        smbSharesFileName       = 'smbShares.xml'
        smbSharesAccessFileName = 'SmbSharesAccess.xml'
    }
}
AfterAll {
    $testLocalUserNames | ForEach-Object {
        Get-LocalUser -Name $_ -EA ignore | Remove-LocalUser
    }
    Remove-SmbShare -Name $testSmbShareName -EA Ignore -Confirm:$false
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'Fail the export of smb shares when' {
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
Describe 'Fail the import of smb shares when' {
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
    It 'the data folder does not have the smbShares file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*Smb shares file '$($testNewParams.DataFolder)\$($testNewParams.smbSharesFileName)' not found"
    }
    It 'the data folder does not have the smbSharesAccess file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\$($testNewParams.smbSharesFileName)"

        { .$testScript @testNewParams } | 
        Should -Throw "*Smb shares access file '$($testNewParams.DataFolder)\$($testNewParams.smbSharesAccessFileName)' not found"
    }
}
Describe 'Export the smb shares details to the data folder' {
    BeforeAll {
        $testSmbShare = @{
            Name         = $testSmbShareName
            Description  = 'test share'
            Path         = (New-Item 'TestDrive:/B' -ItemType Directory).FullName
            ChangeAccess = $env:USERNAME, 'dverhuls' 
            FullAccess   = 'Administrators' 
            ReadAccess   = 'Everyone'
        }
        Remove-SmbShare -Name $testSmbShare.Name -EA Ignore -Confirm:$false
        New-SmbShare @testSmbShare

        $testSmbExport = @{
            smbSharesFile       = Join-Path -Path $testParams.DataFolder -ChildPath $testParams.smbSharesFileName
            smbSharesAccessFile = Join-Path -Path $testParams.DataFolder -ChildPath $testParams.smbSharesAccessFileName
            ntfsFolder          = Join-Path -Path $testParams.DataFolder -ChildPath 'NTFS'
        }

        $testParams.Action = 'Export'
        .$testScript @testParams
    }
    It 'save the general configurations in the smbSharesFile' {
        $testSmbExport.smbSharesFile | Should -Exist
        Get-Content $testSmbExport.smbSharesFile | Should -Not -BeNullOrEmpty
    }
    It 'save the smb share permissions in the smbSharesAccessFile' {
        $testSmbExport.smbSharesAccessFile | Should -Exist
        Get-Content $testSmbExport.smbSharesAccessFile | 
        Should -Not -BeNullOrEmpty
    }
    It 'save the NTFS permissions in the NTFS folder' {
        $testSmbExport.ntfsFolder | Should -Exist
        $testNtfsFiles = @(Get-ChildItem $testSmbExport.ntfsFolder | Where-Object { $_.Name -eq "$($testSmbShare.Name).xml" })
        $testNtfsFiles | Should -Not -BeNullOrEmpty
        Get-Content $testNtfsFiles.FullName | Should -Not -BeNullOrEmpty
    }
}
Describe "With Action set to 'Import'" {
    BeforeAll {
        #region Create local test users
        $testLocalUserNames | ForEach-Object {
            $testUserParams = @{
                Name        = $_
                Password    = ConvertTo-SecureString "P@ssW0rD!" -AsPlainText -Force
                FullName    = 'testGivenName testSurname'
                Description = 'User created by Pester for testing purposes'
            }
            $null = New-LocalUser @testUserParams
        }
        #endregion

        #region Create smb test share
        $testSmbShare = @{
            Name                = $testSmbShareName
            Description         = 'test share'
            Path                = (New-Item 'TestDrive:/B' -ItemType Directory).FullName
            ChangeAccess        = $env:USERNAME, $testLocalUserNames[0]
            FullAccess          = 'Administrators' 
            ReadAccess          = 'Everyone', $testLocalUserNames[1]
            ConcurrentUserLimit = 2
        }
        Remove-SmbShare -Name $testSmbShare.Name -EA Ignore -Confirm:$false
        New-SmbShare @testSmbShare
        #endregion

        #region Apply custom NTFS permissions
        $acl = Get-Acl -Path $testSmbShare.Path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.NTAccount]'BUILTIN\Administrators',
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            )
        )
        $acl.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.NTAccount]$testLocalUserNames[0],
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            )
        )
        $acl.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.NTAccount]$testLocalUserNames[1],
                    [System.Security.AccessControl.FileSystemRights]::Read,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            )
        )
        $acl | Set-Acl -Path $testSmbShare.Path
        #endregion

        $testSmbExport = @{
            smbSharesFile       = Join-Path -Path $testParams.DataFolder -ChildPath $testParams.smbSharesFileName
            smbSharesAccessFile = Join-Path -Path $testParams.DataFolder -ChildPath $testParams.smbSharesAccessFileName
            ntfsFolder          = Join-Path -Path $testParams.DataFolder -ChildPath 'NTFS'
        }

        $testParams.Action = 'Export'
        .$testScript @testParams

        #region Remove folder and share
        Remove-SmbShare -Name $testSmbShare.Name -EA Ignore -Confirm:$false
        Get-SmbShare -Name $testSmbShare.Name -EA Ignore | Should -BeNullOrEmpty

        Remove-Item -LiteralPath $testSmbShare.Path
        #endregion

        #region Remove local user account
        $null = Remove-LocalUser -Name $testLocalUserNames[0]
        #endregion

        #region Only test on the test share
        $testSmbShareOnly = Import-Clixml -LiteralPath $testSmbExport.smbSharesFile | Where-Object Name -EQ $testSmbShare.Name
        $testSmbShareOnly | Export-Clixml -LiteralPath $testSmbExport.smbSharesFile
        #endregion

        $Error.clear()

        $testParams.Action = 'Import'
        .$testScript @testParams -ErrorAction SilentlyContinue
    }
    It 'the shares are recreated' {
        $testNewSmbShare = Get-SmbShare -Name $testSmbShare.Name -EA Ignore
        $testNewSmbShare | Should -Not -BeNullOrEmpty
        $testNewSmbShare.Name | Should -Be $testSmbShare.Name
        $testNewSmbShare.Description | Should -Be $testSmbShare.Description
        $testNewSmbShare.Path | Should -Be $testSmbShare.Path
    }
    It 'the shares smb permissions are set' {
        $testNewSmbShareAccess = Get-SmbShareAccess -Name $testSmbShare.Name -EA Ignore

        $testNewSmbShareAccess | Should -Not -BeNullOrEmpty
        $testNewSmbShareAccess | Should -HaveCount 4

        $testTmp = $testNewSmbShareAccess | 
        Where-Object AccountName -EQ 'Everyone'
        $testTmp.AccessControlType | Should -Be 'Allow'
        $testTmp.AccessRight | Should -Be 'Read'
        $testTmp.ScopeName | Should -Be '*'
        $testTmp = $testNewSmbShareAccess | 
        Where-Object {
            $_.AccountName -EQ "$env:USERDOMAIN\$env:USERNAME"
        }
        $testTmp.AccessControlType | Should -Be 'Allow'
        $testTmp.AccessRight | Should -Be 'Change'
        $testTmp.ScopeName | Should -Be '*'
        $testTmp = $testNewSmbShareAccess | 
        Where-Object {
            $_.AccountName -EQ 'BUILTIN\Administrators'
        }
        $testTmp.AccessControlType | Should -Be 'Allow'
        $testTmp.AccessRight | Should -Be 'Full'
        $testTmp.ScopeName | Should -Be '*'
        $testTmp = $testNewSmbShareAccess | Where-Object {
            $_.AccountName -EQ "$env:COMPUTERNAME\$($testLocalUserNames[1])"
        }
        $testTmp.AccessControlType | Should -Be 'Allow'
        $testTmp.AccessRight | Should -Be 'Read'
        $testTmp.ScopeName | Should -Be '*'
    }
    It 'the shares NTFS permissions are set' {
        $testNtfsPermissions = Get-Acl -Path $testSmbShare.Path
        $testNtfsPermissions.Access | Should -HaveCount 2

        $testTmp1 = $testNtfsPermissions.Access | Where-Object {
            $_.IdentityReference -EQ 'BUILTIN\Administrators'
        }
        $testTmp1 | Should -Not -BeNullOrEmpty
        $testTmp1.AccessControlType | Should -Be 'Allow'
        $testTmp1.FileSystemRights | Should -Be 'FullControl'
        $testTmp1.PropagationFlags | Should -Be 'None'
        $testTmp1.IsInherited | Should -BeFalse
        $testTmp2 = $testNtfsPermissions.Access | Where-Object {
            $_.IdentityReference -EQ "$env:COMPUTERNAME\$($testLocalUserNames[1])"
        }
        $testTmp2 | Should -Not -BeNullOrEmpty
        $testTmp2.AccessControlType | Should -Be 'Allow'
        $testTmp2.FileSystemRights | Should -Be 'Read, Synchronize'
        $testTmp2.PropagationFlags | Should -Be 'None'
        $testTmp2.IsInherited | Should -BeFalse
    }
    Context 'non terminating errors are generated when' {
        It 'an account is not available on the current computer NTFS' {
            $Error.Exception.Message | Where-Object {
                $_ -like "*Failed to grant account '$env:COMPUTERNAME\$($testLocalUserNames[0])' NTFS permission 'FullControl' on folder '$($testSmbShare.Path)' for share '$($testSmbShare.Name)': Account does not exist on '$env:COMPUTERNAME'*"
            } | Should -Not -BeNullOrEmpty
        }
        It 'an account is not available on the current computer Smb' {
            $Error.Exception.Message | Where-Object {
                $_ -like "*Failed to grant account '$env:COMPUTERNAME\$($testLocalUserNames[0])' smb share permission 'Change' on share '$($testSmbShare.Name)' with path '$($testSmbShare.Path)': Account does not exist on '$env:COMPUTERNAME'*"
            } | Should -Not -BeNullOrEmpty
        }
        It 'permission errors are clean' {
            $Error.Exception.Message | Should -HaveCount 2
        }
    }
}
