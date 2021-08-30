#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testUsers = @(
        @{
            Name        = 'testUser1'
            FullName    = 'Test User1'
            Description = 'User 1 created for testing purposes'
            Enabled     = $true
        }
        @{
            Name        = 'testUser2'
            FullName    = 'Test User2'
            Description = 'User 2 created for testing purposes'
            Enabled     = $true
        }
        @{
            Name        = 'testUser3'
            FullName    = 'Test User3'
            Description = 'User 3 created for testing purposes'
            Enabled     = $false
        }
    )

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action               = 'Export'
        DataFolder           = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        UserAccountsFileName = 'UserAccounts.xml'
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
    It 'there are no enabled user accounts found on the computer' {
        Mock Get-LocalUser
        
        { .$testScript @testNewParams } | 
        Should -Throw '*No enabled local user accounts found'
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
    It 'the data folder does not have the user accounts file' {
        '1' | Out-File -LiteralPath "$($testNewParams.DataFolder)\file.txt"

        { .$testScript @testNewParams } | 
        Should -Throw "*user accounts file '$($testNewParams.DataFolder)\$($testNewParams.UserAccountsFileName)' not found"
    }
}
Describe "On action 'Export' a user accounts xml file" {
    BeforeAll {
        Get-ChildItem -Path $testParams.DataFolder | Remove-Item
        $testUsers | ForEach-Object { 
            Remove-LocalUser -Name $_.Name -EA Ignore
        }

        $testUsers | ForEach-Object {
            $testUserParams = @{
                Name        = $_.Name
                FullName    = $_.FullName
                Description = $_.Description
                Password    = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
            }
            $null = New-LocalUser @testUserParams
        }

        $testUsers | Where-Object { -not $_.Enabled } | ForEach-Object {
            Disable-LocalUser -Name $_.Name
        }

        $testParams.Action = 'Export'
        .$testScript @testParams

        $testImportParams = @{
            LiteralPath = "$($testParams.DataFolder)\$($testParams.UserAccountsFileName)"
        }
        $testImport = Import-Clixml @testImportParams
    }
    It 'is created' {
        $testImportParams.LiteralPath | Should -Exist
    }
    It 'contains only enabled local user accounts' {
        foreach ($testUser in $testUsers | Where-Object { $_.Enabled }) {
            $testUserDetails = $testImport | Where-Object { 
                $_.Name -eq $testUser.Name 
            }
            $testUserDetails | Should -Not -BeNullOrEmpty
            $testUserDetails.FullName | Should -Be $testUser.FullName
            $testUserDetails.Description | Should -Be $testUser.Description
        }
    }
    It 'contains and empty password property for each user' {
        foreach ($testUser in $testUsers | Where-Object { $_.Enabled }) {
            $testUserDetails = $testImport | Where-Object { 
                $_.Name -eq $testUser.Name 
            }
            $testUserDetails | Should -Not -BeNullOrEmpty
            [bool](
                $testUserDetails.PsObject.Properties.name -match 'Password'
            ) | Should -BeTrue
            $testUserDetails.Password | Should -BeNullOrEmpty
        }
    }
}
Describe "On action 'Import' the exported xml file is read and" {
    BeforeAll {
        $testParams.Action = 'Import'
        $testJoinParams = @{
            Path      = $testParams.DataFolder 
            ChildPath = $testParams.UserAccountsFileName
        }
        $testXmlFile = Join-Path @testJoinParams
    }
    BeforeEach {
        $testUser = @{
            Name     = $testUsers[0].Name
            Password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
        }
        Remove-Item -Path $testXmlFile -EA Ignore
        Remove-LocalUser -Name $testUser.Name -EA Ignore
    }
    Context 'a non existing user account is created with' {
        It 'Name only' {
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.FullName | Should -BeNullOrEmpty
            $actual.Description | Should -BeNullOrEmpty
        }
        It 'FullName Description' {
            $testUserDetails = @{
                FullName    = 'bob lee'
                Description = 'Test user'
            }
            New-LocalUser @testUser @testUserDetails | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.FullName | Should -Be $testUserDetails.FullName
            $actual.Description | Should -Be $testUserDetails.Description
        }
        It 'PasswordNeverExpires true' {
            $testUser.PasswordNeverExpires = $true
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.PasswordExpires | Should -BeNullOrEmpty
        }
        It 'PasswordNeverExpires false' {
            $testUser.PasswordNeverExpires = $false
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.PasswordExpires | Should -Not -BeNullOrEmpty
        }
        It 'UserMayChangePassword true' {
            $testUser.UserMayNotChangePassword = $false
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.UserMayChangePassword | Should -BeTrue
        }
        It 'UserMayChangePassword false' {
            $testUser.UserMayNotChangePassword = $true
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.UserMayChangePassword | Should -BeFalse
        }
        It 'AccountExpires' {
            $testUser.AccountExpires = (Get-Date).AddDays(3) 
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.AccountExpires | Should -Not -BeNullOrEmpty
        }
        It 'AccountNeverExpires' {
            $testUser.AccountNeverExpires = $true
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.AccountExpires | Should -BeNullOrEmpty
        }
        It 'Enabled' {
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            Remove-LocalUser -Name $testUser.Name
        
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Enabled | Should -BeTrue
        }
        It 'not Enabled' {
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            Remove-LocalUser -Name $testUser.Name

            $testImport = Import-Clixml -LiteralPath $testXmlFile
            $testImport.Enabled = $false
            $testImport | Export-Clixml -LiteralPath $testXmlFile
            
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Enabled | Should -BeFalse
        }
    }
    Context 'an existing user account is updated' {
        It 'FullName Description' {
            $testUserDetails = @{
                FullName    = 'bob'
                Description = 'Test user bob'
            }
            New-LocalUser @testUser @testUserDetails | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name
            $testUserDetailsWrong = @{
                FullName    = 'mike'
                Description = 'Test user mike'
            }
            New-LocalUser @testUser @testUserDetailsWrong

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.FullName | Should -Be $testUserDetails.FullName
            $actual.Description | Should -Be $testUserDetails.Description
        }
        It 'PasswordNeverExpires true' {
            New-LocalUser @testUser -PasswordNeverExpires | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.PasswordExpires | Should -BeNullOrEmpty
        }
        It 'PasswordNeverExpires false' {
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser -PasswordNeverExpires

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.PasswordExpires | Should -Not -BeNullOrEmpty
        }
        It 'UserMayChangePassword true' {
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser -UserMayNotChangePassword

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.UserMayChangePassword | Should -BeTrue
        }
        It 'UserMayChangePassword false' {
            New-LocalUser @testUser -UserMayNotChangePassword | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser
        
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.UserMayChangePassword | Should -BeFalse
        }
        It 'AccountExpires' {
            New-LocalUser @testUser -AccountExpires (Get-Date).AddDays(3) | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
        
            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser -AccountNeverExpires

            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.AccountExpires | Should -Not -BeNullOrEmpty
        }
        It 'AccountNeverExpires' {
            New-LocalUser @testUser -AccountNeverExpires | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            Remove-LocalUser -Name $testUser.Name
            New-LocalUser @testUser -AccountExpires (Get-Date).AddDays(3)
        
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.AccountExpires | Should -BeNullOrEmpty
        }
        It 'to Enabled' {
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            Disable-LocalUser -Name $testUser.Name
        
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Enabled | Should -BeTrue
        }
        It 'to not Enabled' {
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile

            $testImport = Import-Clixml -LiteralPath $testXmlFile
            $testImport.Enabled = $false
            $testImport | Export-Clixml -LiteralPath $testXmlFile
            
            .$testScript @testParams
        
            $actual = Get-LocalUser -Name $testUser.Name -EA ignore
            $actual | Should -Not -BeNullOrEmpty
            $actual.Enabled | Should -BeFalse
        }
    }
    Context 'a non terminating error is created when' {
        It 'creating a user account fails' {
            $testXmlFile = Join-Path @testJoinParams
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
    
            Mock Set-LocalUser {
                Write-Error 'Non terminating error Set-LocalUser'
            }
            $Error.Clear()
            .$testScript @testParams -EA SilentlyContinue
            $Error.Exception.Message | Should -Be "Failed to create user account '$($testUser.Name)': Non terminating error Set-LocalUser"
        }
        It 'updating a user account fails' {
            $testXmlFile = Join-Path @testJoinParams
            New-LocalUser @testUser | 
            Select-Object -Property *, 
            @{Name = 'Password'; Expression = { 'P@s/-%*D!' } } | 
            Export-Clixml -LiteralPath $testXmlFile
    
            Remove-LocalUser -Name $testUser.Name

            Mock Enable-LocalUser
            Mock New-LocalUser {
                Write-Error 'Non terminating error New-LocalUser'
            }
            $Error.Clear()
            .$testScript @testParams -EA SilentlyContinue
            $Error.Exception.Message | Should -Be "Failed to create user account '$($testUser.Name)': Non terminating error New-LocalUser"
        }
    }
}
Describe "on 'Import' a user account password" {
    BeforeAll {
        $ConvertToSecureString = Get-Command ConvertTo-SecureString
        Mock ConvertTo-SecureString {
            & $ConvertToSecureString -String 'P@s/-%*D!' -AsPlainText -Force
        }
        Mock Set-LocalUser

        $testParams.Action = 'Import'
        $testJoinParams = @{
            Path      = $testParams.DataFolder 
            ChildPath = $testParams.UserAccountsFileName
        }
        $testXmlFile = Join-Path @testJoinParams
        $testUser = @{
            Name     = $testUsers[0].Name
            Password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
        }
    }
    BeforeEach {
        Remove-Item -Path $testXmlFile -EA Ignore
        Remove-LocalUser -Name $testUser.Name -EA Ignore
    }
    Context 'is always set when the import file has a password' {
        It 'for an existing user account' {
            $testNewPassword = 'P@s/-%*D!newPassword'

            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { $testNewPassword } } | 
            Export-Clixml -LiteralPath $testXmlFile

            .$testScript @testParams

            Should -Invoke ConvertTo-SecureString -Times 1 -Exactly -ParameterFilter {
                ($String -eq $testNewPassword)
            }
            Should -Invoke Set-LocalUser -Times 1 -Exactly -ParameterFilter {
                ($Password) -and ($Name -eq $testUser.Name) 
            }
        }
        It 'for a new user account' {
            $testNewPassword = 'P@s/-%*D!newPassword'
            
            New-LocalUser @testUser | Select-Object -Property *, 
            @{Name = 'Password'; Expression = { $testNewPassword } } | 
            Export-Clixml -LiteralPath $testXmlFile
            
            Remove-LocalUser -Name $testUser.Name -EA Ignore
            
            Mock New-LocalUser
            Mock Enable-LocalUser
            .$testScript @testParams

            Should -Invoke ConvertTo-SecureString -Times 1 -Exactly -ParameterFilter {
                ($String -eq $testNewPassword)
            }
            Should -Invoke New-LocalUser -Times 1 -Exactly -ParameterFilter {
                ($Password) -and ($Name -eq $testUser.Name) 
            }
            Should -Not -Invoke Set-LocalUser -ParameterFilter {
                ($Password) -and ($Name -eq $testUser.Name) 
            }
        }
    }
    Context 'is always asked in the console when the import file has no password' {
        Context 'for an existing user account' {
            It 'the password can be updated' {
                New-LocalUser @testUser | Select-Object -Property *, 
                @{Name = 'Password'; Expression = { '' } } | 
                Export-Clixml -LiteralPath $testXmlFile

                $testEncryptedPassword = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force

                Mock Read-Host { 'y' } -ParameterFilter {
                    ($Prompt -eq "Would you like to set a new password for user account '$($testUser.Name)'? [Y]es or [N]o")
                }
                Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
                    ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
                }
                Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
                    ($Prompt -eq "Type the password again to confirm it's correct")
                }
                .$testScript @testParams

                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                    ($Prompt -eq "Would you like to set a new password for user account '$($testUser.Name)'? [Y]es or [N]o")
                }
                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                    ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
                }
                Should -Invoke Set-LocalUser -Times 1 -Exactly -ParameterFilter {
                    ($Password) -and ($Name -eq $testUser.Name) 
                }
            }
            It 'the password does not need to be updated' {
                New-LocalUser @testUser | Select-Object -Property *, 
                @{Name = 'Password'; Expression = { '' } } | 
                Export-Clixml -LiteralPath $testXmlFile

                Mock Read-Host { 'n' } -ParameterFilter {
                ($Prompt -eq "Would you like to set a new password for user account '$($testUser.Name)'? [Y]es or [N]o")
                }
        
                .$testScript @testParams

                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                    ($Prompt -eq "Would you like to set a new password for user account '$($testUser.Name)'? [Y]es or [N]o")
                }
                Should -Not -Invoke ConvertTo-SecureString
                Should -Not -Invoke Set-LocalUser -ParameterFilter {
                    ($Password) -and ($Name -eq $testUser.Name) 
                }
            }
        }
        Context 'for a new user account' {
            It 'the password must be set' {
                New-LocalUser @testUser | Select-Object -Property *, 
                @{Name = 'Password'; Expression = { '' } } | 
                Export-Clixml -LiteralPath $testXmlFile
                Remove-LocalUser -Name $testUser.Name -EA Ignore

                $testEncryptedPassword = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force

                Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
                    ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
                }
                Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
                    ($Prompt -eq "Type the password again to confirm it's correct")
                }

                Mock New-LocalUser
                Mock Enable-LocalUser
                .$testScript @testParams

                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                    ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
                }
                Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                    ($Prompt -eq "Type the password again to confirm it's correct")
                }
                Should -Invoke New-LocalUser -Times 1 -Exactly -ParameterFilter {
                    ($Password) -and ($Name -eq $testUser.Name) 
                }
            }
        }
    }
    It 'is asked in the console when it is not complex enough' {
        New-LocalUser @testUser | Select-Object -Property *, 
        @{Name = 'Password'; Expression = { '123' } } | 
        Export-Clixml -LiteralPath $testXmlFile
        Remove-LocalUser $testUser.Name -EA ignore

        Mock ConvertTo-SecureString {
            & $ConvertToSecureString -String '123' -AsPlainText -Force
        } -ParameterFilter {
            ($String -eq '123')
        }
        Mock ConvertTo-SecureString {
            & $ConvertToSecureString -String 'P@s/-%*D!' -AsPlainText -Force
        } -ParameterFilter {
            ($String -eq 'P@s/-%*D!')
        }

        $testEncryptedPassword = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force

        Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
            ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
        }
        Mock Read-Host { $testEncryptedPassword } -ParameterFilter {
            ($Prompt -eq "Type the password again to confirm it's correct")
        }

        Mock Write-Host
        Mock Enable-LocalUser
        .$testScript @testParams

        Should -Invoke Write-Host -ParameterFilter {
            ($Object -like "Password not accepted*")
        }
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
            ($Prompt -eq "Please type a password for user account '$($testUser.Name)'")
        }
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
            ($Prompt -eq "Type the password again to confirm it's correct")
        }
        Should -Invoke Enable-LocalUser -Times 1 -Exactly -ParameterFilter {
            ($Name -eq $testUser.Name) 
        }
    }
}
