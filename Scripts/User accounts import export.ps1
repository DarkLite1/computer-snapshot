#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import User accounts as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
Function Compare-EncryptedPasswordsEqualHC {
        
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
            if (
                (-not $AllowBlankPassword) -and 
                ($compareParams.Password1.Length -eq 0)
            ) {
                $passwordsMatching = $false
                Write-Host 'Passwords can not be blank, please try again' -ForegroundColor Red
            }
        }
        until ($passwordsMatching)
    
        $compareParams.Password1
    }
Function Set-NewPasswordHC {
        
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
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}
$AllowBlankPassword = $true
if ($Action -eq 'Export') {
    #region Capture section
$users = @(Get-LocalUser)
$exportData = @($users | Select-Object Name, FullName, Description, Enabled, PasswordExpires,
    UserMayChangePassword, @{ Name = 'Password'; Expression = { '' } })
    #endregion
    $messages = @('Exported User accounts')
}
else {
    #region Apply section
    $messages = @(& {

$importedUsers = $Data
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
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
