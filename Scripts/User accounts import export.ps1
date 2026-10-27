#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import User accounts as a configuration section.
.DESCRIPTION
    Import never prompts. A user that fails is reported in Errors and the
    remaining users are still processed.
    - New user without a Password: not created, reported as an error.
      Use a {{password:...}} placeholder to ask for it at restore time.
    - Existing user without a Password: the current password is kept.
    - Password rejected by the password policy: reported as an error; a
      user that was just created for it is removed again.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
function Set-UserPasswordHC {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password,
        [switch]$NewUser
    )
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    try {
        if ($NewUser) { $null = New-LocalUser -Name $UserName -Password $securePassword }
        else { Set-LocalUser -Name $UserName -Password $securePassword }
    }
    catch {
        # Match by name and error id: the exception type only exists once the
        # LocalAccounts module is loaded, and PowerShell 7 may deserialize it
        $isInvalidPassword = $_.Exception.GetType().Name -eq 'InvalidPasswordException' -or
            $_.FullyQualifiedErrorId -like 'InvalidPassword*'
        if (-not $isInvalidPassword) { throw }
        if ($NewUser) {
            # Windows can create the account before rejecting the password
            Remove-LocalUser -Name $UserName -ErrorAction Ignore
        }
        throw 'the password does not meet the length, complexity or history requirements of the password policy'
    }
}
#endregion
$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}
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
    $knownUserNames = @(Get-LocalUser | ForEach-Object { $_.Name })
    foreach ($user in $Data) {
        try {
            Write-Verbose "User '$($user.Name)'"
            $isNewUser = $knownUserNames -notcontains $user.Name

            #region Create the user, which requires a password
            if ($isNewUser) {
                if (-not $user.Password) {
                    throw 'a Password is required to create a new user; set one or use a {{password:...}} placeholder'
                }
                Set-UserPasswordHC -UserName $user.Name -Password $user.Password -NewUser
            }
            #endregion

            #region Set user account details
            # Only Name is required: settings missing from the configuration are left
            # unchanged, because passing $null to a Boolean parameter fails
            $properties = @($user.PSObject.Properties | ForEach-Object { $_.Name })
            $setUserParams = @{
                Name                 = $user.Name
                PasswordNeverExpires = ![Boolean]$user.PasswordExpires
            }
            if ($null -ne $user.FullName) { $setUserParams.FullName = $user.FullName }
            if ($null -ne $user.Description) { $setUserParams.Description = $user.Description }
            if ($null -ne $user.UserMayChangePassword) { $setUserParams.UserMayChangePassword = [bool]$user.UserMayChangePassword }
            if ($user.AccountExpires) { $setUserParams.AccountExpires = $user.AccountExpires }
            else { $setUserParams.AccountNeverExpires = $true }
            Set-LocalUser @setUserParams
            #endregion

            #region Enable or disable user account, only when configured
            if ($properties -contains 'Enabled' -and $null -ne $user.Enabled) {
                if ($user.Enabled) { Enable-LocalUser -Name $user.Name }
                else { Disable-LocalUser -Name $user.Name }
            }
            #endregion

            #region Update the password of an existing user
            if (-not $isNewUser -and $user.Password) {
                Set-UserPasswordHC -UserName $user.Name -Password $user.Password
            }
            #endregion

            $state = if ($properties -notcontains 'Enabled' -or $null -eq $user.Enabled) { '' }
            elseif ($user.Enabled) { ' (enabled)' } else { ' (disabled)' }
            if ($isNewUser) { $messages += "Created user '$($user.Name)'$state" }
            elseif ($user.Password) { $messages += "Updated user '$($user.Name)' and its password$state" }
            else { $messages += "Updated user '$($user.Name)', password unchanged$state" }
        }
        catch {
            $errors += "Failed to create or update user account '$($user.Name)': $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }