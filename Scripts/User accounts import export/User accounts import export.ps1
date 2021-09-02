<#
    .SYNOPSIS
        Export or import user accounts

    .DESCRIPTION
        This script should be run with action 'Export' on a computer that has 
        all the required users already created. Then on another computer this
        script can be run with action 'Import' to recreate the exported user 
        accounts.

        Disabled and Enabled user accounts will be recreated with their 
        respective status. 
        
        TIP:
        It's encouraged to clean up the export file before running the script 
        with action 'Import'. Remove disabled user accounts, remove non 
        relevant user accounts, update user account details as desired, ...

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the user accounts

    .PARAMETER UserAccountsFileName
        Name of the file that contains all local user accounts

    .EXAMPLE
        $exportParams = @{
            Action               = 'Export'
            DataFolder           = 'C:\UserAccounts'
            UserAccountsFileName = 'UserAccounts.json'
        }
        & 'C:\UserAccounts.ps1' @exportParams

        Export all user accounts on the current computer to the folder 
        'C:\UserAccounts'

    .EXAMPLE
        $importParams = @{
            Action               = 'Import'
            DataFolder           = 'C:\UserAccounts'
            UserAccountsFileName = 'UserAccounts.json'
        }
        & 'C:\UserAccounts.ps1' @importParams

        Restore all user accounts in the folder 'C:\UserAccounts' on the 
        current computer

    .EXAMPLE
        $exportParams = @{
            Action               = 'Export'
            DataFolder           = 'C:\UserAccounts'
            UserAccountsFileName = 'UserAccounts.json'
        }
        & 'C:\UserAccounts.ps1' @exportParams

        $joinParams = @{
            Path      = $exportParams.DataFolder 
            ChildPath = $exportParams.UserAccountsFileName
        }
        $exportFile = Join-Path @joinParams

        $ExportedUsers = (Get-Content -Path $exportFile -Raw) | ConvertFrom-Json
        $ExportedUsers | Foreach-Object {$_.Enabled = $true}
        ($ExportedUsers[0..1]) | ConvertTo-Json | 
        Out-File -Path $exportFile -Encoding UTF8

        $exportParams.Action = 'Import'
        & 'C:\UserAccounts.ps1' @exportParams

        The first command exports all user accounts. The second command
        sets the status Enabled to $true for all exported user accounts and
        overwrites the exported file with the first 2 user accounts only.
        The last command creates all users in the exported file, being two
        users with status Enabled set to $true.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$UserAccountsFileName = 'UserAccounts.json'
)

Begin {
    Function Compare-EncryptedPasswordsEqualHC {
        <#
            .SYNOPSIS
                Compare two encrypted passwords to see if they match
    
            .DESCRIPTION
                Users must enter a password twice to make sure they 
                didn't miss type
    
            .EXAMPLE
                $compareParams = @{
                    Password1 = ConvertTo-SecureString -String '1' -AsPlainText -Force
                    Password2 = ConvertTo-SecureString -String '1' -AsPlainText -Force
                }
                Compare-EncryptedPasswordsEqualHC @compareParams
    
                Both passwords match, so true is returned
    
            .EXAMPLE
                $compareParams = @{
                    Password1 = ConvertTo-SecureString -String '1' -AsPlainText -Force
                    Password2 = ConvertTo-SecureString -String '2' -AsPlainText -Force
                }
                Compare-EncryptedPasswordsEqualHC @compareParams
    
                Both passwords do not match, so false is returned
        #>
        Param (
            [Parameter(Mandatory)]
            [System.Security.SecureString]$Password1, 
            [Parameter(Mandatory)]
            [System.Security.SecureString]$Password2
        )
    
        if ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringtoBSTR($password1)) -ne [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringtoBSTR($password2))) {
            $false
        }
        else {
            $true
        }
    }
    Function Request-PasswordHC {
        <#
            .SYNOPSIS
                Ask the user to type a password in the console

            .DESCRIPTION
                The password typed will be checked by asking the users to type
                it twice and confirming it's a match. In case it's not matching
                we'll ask again.
        #>

        [OutputType([System.Security.SecureString])]
        Param (
            [Parameter(Mandatory)]
            [String]$UserName
        )
        do {
            $compareParams = @{
                Password1 = Read-Host "Please type a password for user account '$UserName'" -AsSecureString
                Password2 = Read-Host "Type the password again to confirm it's correct" -AsSecureString
            }
            $passwordsMatching = Compare-EncryptedPasswordsEqualHC @compareParams
    
            if (-not $passwordsMatching) {
                Write-Host 'Passwords are not matching, please try again' -ForegroundColor Red
            }
            if ($compareParams.Password1.Length -eq 0) {
                $passwordsMatching = $false
                Write-Host 'Passwords can not be blank, please try again' -ForegroundColor Red
            }
        }
        until ($passwordsMatching)
    
        $compareParams.Password1
    }    
    Function Set-NewPasswordHC {
        <#
            .SYNOPSIS
                Create a new user account or update an existing user account
                with the provided plain string password

            .PARAMETER UserName
                Name of the user account

            .PARAMETER UserPassword
                Plain string containing the user account password

            .PARAMETER NewUser
                If used a new user is created with the requested password
                otherwise an existing user is updated with the requested
                password

            .EXAMPLE
                Set-NewPasswordHC -UserName 'bob' -UserPassword 'P@s/-%*D!'

                Updates the existing user 'bob' with the new password

            .EXAMPLE
                Set-NewPasswordHC -UserName 'mike' -UserPassword 'P@s/-%*D!' -NewUser

                Creates the new user 'mike' and set his password
        #>
        Param (
            [Parameter(Mandatory)]
            [String]$UserName,
            [String]$UserPassword,
            [Switch]$NewUser
        )

        if (-not $UserPassword) {
            $encryptedPassword = Request-PasswordHC -UserName $UserName
            # $UserPassword = Read-Host "Please type a password for user account '$UserName':"
        }
        else {
            $encryptedPassword = ConvertTo-SecureString $UserPassword -AsPlainText -Force
        }

        Do {
            try {
                $isPasswordAccepted = $false
                $params = @{
                    Name        = $user.Name 
                    Password    = $encryptedPassword
                    ErrorAction = 'Stop'
                }
                if ($NewUser) {
                    New-LocalUser @params
                }
                else {
                    Set-LocalUser @params
                }
                $isPasswordAccepted = $true
            }
            catch [Microsoft.PowerShell.Commands.InvalidPasswordException] {
                if ($NewUser) {
                    # a user account is created first and only
                    # afterwards the password is set. So a user will
                    # be created when the password is not complex enough
                    Remove-LocalUser -Name $UserName -EA Ignore
                }
                Write-Host 'Password not accepted: The value provided for the password does not meet the length, complexity, or history requirements of the domain.' -ForegroundColor Red
                $encryptedPassword = Request-PasswordHC -UserName $UserName
                $Error.RemoveAt(0)
            }
        }
        while (-not $isPasswordAccepted)
    }

    Try {
        $UserAccountsFile = Join-Path -Path $DataFolder -ChildPath $UserAccountsFileName

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $UserAccountsFile -PathType Leaf)) {
                throw "User accounts file '$UserAccountsFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action user accounts failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose "Export user accounts to file '$UserAccountsFile'"
            If ($users = Get-LocalUser) {
                $users | ForEach-Object {
                    Write-Verbose "User account '$($_.Name)' description '$($_.description)'"
                }
                Write-Verbose "Export users to file '$UserAccountsFile'"
                (
                    $users | Select-Object -Property Name, FullName,
                    Description, Enabled, PasswordExpires, 
                    UserMayChangePassword, 
                    @{Name = 'Password'; Expression = { '' } } 
                ) | 
                ConvertTo-Json | 
                Out-File -FilePath $UserAccountsFile -Encoding UTF8

                Write-Output "Exported $($users.count) user accounts"
            }
            else {
                throw 'No enabled local user accounts found'
            }
        }
        else {
            Write-Verbose "Import user accounts from file '$UserAccountsFile'"
            $importedUsers = (
                Get-Content -LiteralPath $UserAccountsFile -Raw
            ) | ConvertFrom-Json -EA Stop

            $knownComputerUsers = Get-LocalUser

            foreach ($user in $importedUsers) {
                try {                    
                    Write-Verbose "User '$($user.Name)'"
                    $passwordParams = @{
                        UserName     = $user.Name 
                        UserPassword = $user.Password 
                        NewUser      = $false
                    }

                    #region Create incomplete user
                    if ($knownComputerUsers.Name -notContains $user.Name) {
                        $passwordParams.NewUser = $true
                        Set-NewPasswordHC @passwordParams
                    }
                    #endregion

                    #region Set user account details
                    $setUserParams = @{
                        Name                  = $user.Name
                        Description           = $user.Description
                        FullName              = $user.FullName
                        PasswordNeverExpires  = ![Boolean]$user.PasswordExpires
                        UserMayChangePassword = $user.UserMayChangePassword
                        ErrorAction           = 'Stop'
                    }
                    if ($user.AccountExpires) {
                        $setUserParams.AccountExpires = $user.AccountExpires
                    }
                    else {
                        $setUserParams.AccountNeverExpires = $true
                    }
                    Set-LocalUser @setUserParams
                    #endregion

                    #region Enable or disable user account
                    if ($user.Enabled) {
                        Enable-LocalUser -Name $user.Name
                    }
                    else {
                        Write-Warning "Disable user account '$($user.Name)' as requested in the import file"
                        Disable-LocalUser -Name $user.Name
                    }
                    #endregion

                    if (-not $passwordParams.NewUser) {
                        if ($user.Password) {
                            Set-NewPasswordHC @passwordParams
                        }
                        else {
                            do { 
                                $answer = (
                                    Read-Host "Would you like to set a new password for user account '$($user.Name)'? [Y]es or [N]o"
                                ).ToLower()
                            } 
                            until ('y', 'n' -contains $answer)
                            if ($answer -eq 'y') {
                                Set-NewPasswordHC @passwordParams
                            }
                        }
                    }

                    if ($passwordParams.NewUser) {
                        Write-Output "Created user '$($User.Name)'"
                    }
                    else {
                        Write-Output "updated user '$($User.Name)'"
                    }
                }
                catch {
                    Write-Error "Failed to create user account '$($user.Name)': $_"
                    $Error.RemoveAt(1)
                }
            }
        }
    }
    Catch {
        throw "$Action user accounts failed: $_"
    }
}