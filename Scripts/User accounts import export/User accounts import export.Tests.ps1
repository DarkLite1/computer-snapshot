#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $testUsers = @(
        @{
            Name        = 'testUser1'
            FullName    = 'Test User1'
            Description = 'User created for testing purposes'
            Enabled     = $true
        }
        @{
            Name        = 'testUser2'
            FullName    = 'Test User2'
            Description = 'User created for testing purposes'
            Enabled     = $true
        }
        @{
            Name        = 'testUser3'
            FullName    = 'Test User3'
            Description = 'User created for testing purposes'
            Enabled     = $false
        }
    )

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Action     = 'Export'
        DataFolder = (New-Item 'TestDrive:/A' -ItemType Directory).FullName
        FileName   = 'UserAccounts.csv'
    }
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach 'Action', 'DataFolder' {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe "Throw an error on action 'Export' when" {
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
Describe "Throw an error on action 'Import' when" {
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
        Should -Throw "*user accounts file '$($testNewParams.DataFolder)\$($testNewParams.FileName)' not found"
    }
}
Describe "On action 'Export' a .csv file" {
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

        $testParams.Action = 'Export'
        .$testScript @testParams

        $testImportParams = @{
            LiteralPath = "$($testParams.DataFolder)\$($testParams.FileName)"
            Encoding    = 'UTF8'
            Delimiter   = ';'
            ErrorAction = 'Ignore'
        }
        $testImportCsv = Import-Csv @testImportParams
    }
    It 'is created' {
        $testImportParams.LiteralPath | Should -Exist
    }

    It 'only contains enabled local user accounts' {
        foreach ($testUser in $testUsers | Where-Object { $_.Enabled }) {
            $testUserDetails = $testImportCsv | Where-Object { 
                $_.Name -eq $testUser.Name 
            }
            $testUserDetails | Should -Not -BeNullOrEmpty
            $testUserDetails.FullName | Should -Be $testUser.FullName
            $testUserDetails.Description | Should -Be $testUser.Description
        }
    }
    It 'does not contain disabled local user accounts' {
        $testImportCsv | Where-Object { -not $_.Enabled } | 
        Should -BeNullOrEmpty
    }
}
