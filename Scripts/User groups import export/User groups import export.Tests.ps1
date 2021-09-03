#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testUserNames = @('TestUser1', 'TestUser2', 'TestUser3')
    $testGroups = @(
        @{
            Name            = 'testGroup1'
            Description     = 'group 1 created for testing purposes'
            Members         = @(
                @{
                    Name            = $testUserNames[0]
                    ObjectClass     = 'User'
                    PrincipalSource = 'Local'
                }
            )
            ObjectClass     = 'Group'
            PrincipalSource = 'Local'
        }
        @{
            Name            = 'testGroup2'
            Description     = 'group 2 created for testing purposes'
            Members         = @(
                @{
                    Name            = $testUserNames[0]
                    ObjectClass     = 'User'
                    PrincipalSource = 'Local'
                }
                @{
                    Name            = $testUserNames[1]
                    ObjectClass     = 'User'
                    PrincipalSource = 'Local'
                }
                @{
                    Name            = $testUserNames[2]
                    ObjectClass     = 'User'
                    PrincipalSource = 'Local'
                }
                # local groups can not be added to other local groups
            )
            ObjectClass     = 'Group'
            PrincipalSource = 'Local'
        }
        @{
            Name            = 'testGroup3'
            Description     = 'group 3 created for testing purposes'
            ObjectClass     = 'Group'
            PrincipalSource = 'Local'
        }
        @{
            Name            = 'testGroup4'
            Description     = '' # $null not accepted by New-LocalGroup
            ObjectClass     = 'Group'
            PrincipalSource = 'Local'
        }
    )

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action         = 'Export'
        DataFolder     = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        GroupsFileName = 'Groups.json'
    }
}
AfterAll {
    $testGroups | ForEach-Object {
        Remove-LocalGroup -Name $_.Name -EA Ignore
    }
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe "Throw a terminating error on action 'Export' when" {
    BeforeEach {
        $testNewParams = $testParams.clone()
        $testNewParams.Action = 'Export'
        Get-ChildItem $testNewParams.DataFolder | Remove-Item
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
Describe "Throw a terminating error on action 'Import' when" {
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
    It 'the data folder does not have the groups file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*groups file '$($testNewParams.DataFolder)\$($testNewParams.GroupsFileName)' not found"
    }
}
Describe 'on action Export' {
    BeforeAll {
        Get-ChildItem -Path $testParams.DataFolder | Remove-Item
        $testGroups | ForEach-Object { 
            Remove-LocalGroup -Name $_.Name -EA Ignore
        }
        
        $testUserNames | ForEach-Object {
            $testUserParams = @{
                Name        = $_
                Password    = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
                ErrorAction = 'Ignore'
            }
            $null = New-LocalUser @testUserParams
        }
        
        ForEach ($testGroup in $testGroups) {
            $testGroupParams = @{
                Name        = $testGroup.Name
                Description = $testGroup.Description
            }
            $null = New-LocalGroup @testGroupParams

            if ($testMembers = $testGroup.Members) {
                $testMembers | ForEach-Object {
                    $testGroupMemberParams = @{
                        Group  = $testGroup.Name 
                        Member = $_.Name
                    }
                    Add-LocalGroupMember @testGroupMemberParams
                }
            }
        }

        $testParams.Action = 'Export'
        .$testScript @testParams -EA SilentlyContinue

        $testImportParams = @{
            LiteralPath = "$($testParams.DataFolder)\$($testParams.GroupsFileName)"
            Raw         = $true
        }
        $testImport = Get-Content @testImportParams | ConvertFrom-Json -EA Stop
    }
    It 'a json file is created' {
        $testImportParams.LiteralPath | Should -Exist
    }
    It 'the json file contains all local groups with their members' {
        foreach ($testGroup in $testGroups) {
            $actual = $testImport | Where-Object { 
                $_.Name -eq $testGroup.Name 
            }
            $actual | Should -Not -BeNullOrEmpty
            $actual.Description | Should -Be $testGroup.Description
            $actual.ObjectClass | Should -Be $testGroup.ObjectClass
            $actual.PrincipalSource | Should -Be $testGroup.PrincipalSource
            
            foreach ($testMember in $testGroup.Members) {
                $actualMember = $actual.Members | Where-Object {
                    $_.Name -eq "$env:COMPUTERNAME\$($testMember.Name)"
                }

                $actualMember | Should -Not -BeNullOrEmpty
                $actualMember.ObjectClass | Should -Be $testMember.ObjectClass
                $actualMember.PrincipalSource | 
                Should -Be $testMember.PrincipalSource
            }
        }
    }
}
Describe 'on action Import' {
    BeforeAll {
        Mock Write-Output

        $testFile = Join-Path $testParams.DataFolder $testParams.GroupsFileName
        $testParams.Action = 'Import'
    }
    BeforeEach {
        $testFile | Remove-Item -EA Ignore

        $testUserNames | ForEach-Object {
            Remove-LocalUser -Name $_ -EA Ignore
        }
        $testGroups | ForEach-Object {
            Remove-LocalGroup -Name $_.Name -EA Ignore
        }
    }
    Context 'a new group is created' {
        It 'Description $null' {
            @{
                Name            = $testGroups[0].Name
                Description     = $null
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Description | Should -Be ''

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' created"
            }
        }
        It 'Description empty string' {
            @{
                Name            = $testGroups[0].Name
                Description     = ''
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Description | Should -Be ''

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' created"
            }
        }
        It 'Description' {
            @{
                Name            = $testGroups[0].Name
                Description     = 'test description'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Description | Should -Be 'test description'

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' created"
            }
        }
    }
    Context 'an existing group is updated' {
        It 'Description $null' {
            New-LocalGroup -Name $testGroups[0].Name -Description 'wrong'

            @{
                Name            = $testGroups[0].Name
                Description     = $null
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            
            $actual.Description | Should -Be ' ' 

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Updated description of group '$($testGroups[0].Name)'"
            }

            .$testScript @testParams
            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            
            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' exists already and is correct"
            }
        }
        It 'Description empty string' {
            New-LocalGroup -Name $testGroups[0].Name -Description 'wrong'

            @{
                Name            = $testGroups[0].Name
                Description     = ''
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual.Description | Should -Be ' ' 

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Updated description of group '$($testGroups[0].Name)'"
            }

            .$testScript @testParams
            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            
            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' exists already and is correct"
            }
        }
        It 'Description' {
            New-LocalGroup -Name $testGroups[0].Name -Description 'wrong'

            @{
                Name            = $testGroups[0].Name
                Description     = 'test description'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = $null
            } | 
            ConvertTo-Json | Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroup -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Description | Should -Be 'test description'

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Updated description of group '$($testGroups[0].Name)'"
            }
        }
    }
    Context 'group members' {
        It 'are added to a new group' {
            $testUserParams = @{
                Name     = $testUserNames[0]
                Password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
            }
            New-LocalUser @testUserParams

            @{
                Name            = $testGroups[0].Name
                Description     = 'test group'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = @(
                    @{
                        Name            = $testUserNames[0]
                        ObjectClass     = 'User'
                        PrincipalSource = 'Local'
                    }
                )
            } | 
            ConvertTo-Json -Depth 5 | 
            Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroupMember -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Name | Should -Be "$env:COMPUTERNAME\$($testUserNames[0])"

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' added account member '$($testUserNames[0])'"
            }
        }
        It 'are added to an existing group' {
            $testUserParams = @{
                Name     = $testUserNames[0]
                Password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
            }
            New-LocalUser @testUserParams
            New-LocalGroup -Name $testGroups[0].Name

            @{
                Name            = $testGroups[0].Name
                Description     = 'test group'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = @(
                    @{
                        Name            = $testUserNames[0]
                        ObjectClass     = 'User'
                        PrincipalSource = 'Local'
                    }
                )
            } | 
            ConvertTo-Json -Depth 5 | 
            Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroupMember -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Name | Should -Be "$env:COMPUTERNAME\$($testUserNames[0])"

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' added account member '$($testUserNames[0])'"
            }
        }
        It 'are reported when they are already a member of the group' {
            $testUserParams = @{
                Name     = $testUserNames[0]
                Password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
            }
            New-LocalUser @testUserParams
            New-LocalGroup -Name $testGroups[0].Name
            Add-LocalGroupMember -Group $testGroups[0].Name -Member $testUserNames[0]

            @{
                Name            = $testGroups[0].Name
                Description     = 'test group'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = @(
                    @{
                        Name            = $testUserNames[0]
                        ObjectClass     = 'User'
                        PrincipalSource = 'Local'
                    }
                )
            } | 
            ConvertTo-Json -Depth 5 | 
            Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams    

            $actual = Get-LocalGroupMember -Name $testGroups[0].Name -EA Ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Name | Should -Be "$env:COMPUTERNAME\$($testUserNames[0])"

            Should -Invoke Write-Output -Times 1 -Exactly -ParameterFilter {
                $InputObject -eq "Group '$($testGroups[0].Name)' account '$($testUserNames[0])' is already a member"
            }
        }
        It 'are reported as non terminating error when they do not exist' {
            Mock Write-Error

            @{
                Name            = $testGroups[0].Name
                Description     = 'test group'
                ObjectClass     = 'Group'
                PrincipalSource = 'Local'
                Members         = @(
                    @{
                        Name            = 'NotExisting'
                        ObjectClass     = 'User'
                        PrincipalSource = 'Local'
                    }
                )
            } | 
            ConvertTo-Json -Depth 5 | 
            Out-File -LiteralPath $testFile -Encoding utf8
        
            .$testScript @testParams 

            Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Failed to add member account 'NotExisting' to group '$($testGroups[0].Name)': member account not found"
            }
        }
    }   
}