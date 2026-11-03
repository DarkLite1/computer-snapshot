#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import User accounts as a configuration section.
.DESCRIPTION
    Export cannot read passwords, so it writes a {{password:...}} placeholder
    for each user: restoring the export asks for each password. Accounts that
    Windows manages itself (Guest, DefaultAccount, WDAGUtilityAccount) get an
    empty Password instead, so their current password is kept.

    Import never prompts. A user that fails is reported in Errors and the
    remaining users are still processed.
    - New user without a Password: not created, reported as an error.
      Use a {{password:...}} placeholder to ask for it at restore time.
    - Existing user without a Password: the current password is kept.
    - Password rejected by the password policy: reported as an error; a
      user that was just created for it is removed again.
    - Action Remove: remove the named local account, keeping profile files.
      An absent account is a successful no-op. Built-in accounts and the
      account running the restore cannot be removed.
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
function Get-CurrentUserSidHC {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $identity.User.Value }
    finally { $identity.Dispose() }
}

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

    $password = @{
        Name       = 'Password'
        Expression = {
            # Guest (501), DefaultAccount (503) and WDAGUtilityAccount (504)
            if ([string]$_.SID -match '-50[134]$') {
                ''
            }
            else {
                "{{password:Password for local user '$($_.Name)'}}"
            }
        }
    }

    $exportData = @(
        $users | Select-Object Name, FullName, Description, Enabled,
        PasswordExpires, UserMayChangePassword, $password
    )
    #endregion
    $messages = @(
        'Exported User accounts; restoring this export asks for the ' +
        'password of each user'
    )
}
else {
    #region Apply section
    $knownUserNames = @(Get-LocalUser | ForEach-Object { $_.Name })
    foreach ($user in $Data) {
        $isRemove = $user.Action -eq 'Remove'
        try {
            Write-Verbose "User '$($user.Name)'"
            $problems = @(Test-UserAccountEntryHC $user)
            if ($problems.Count) { throw ($problems -join '; ') }

            if ($isRemove) {
                $matchingUsers = @(Get-LocalUser | Where-Object { $_.Name -eq $user.Name })
                if (-not $matchingUsers.Count) {
                    $messages += "User account '$($user.Name)' not found, nothing to remove"
                    continue
                }
                if ($matchingUsers.Count -ne 1) { throw 'the name does not identify exactly one local account' }
                $sid = [string]$matchingUsers[0].SID
                if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-(\d+)$') {
                    throw 'cannot verify the local account SID; removal refused'
                }
                if ([long]$Matches[1] -lt 1000) {
                    throw 'built-in Windows accounts cannot be removed'
                }
                $currentSid = Get-CurrentUserSidHC
                if (-not $currentSid) { throw 'cannot identify the account running the restore; removal refused' }
                if ($sid -eq $currentSid) {
                    throw 'the account running the restore cannot be removed'
                }
                Remove-LocalUser -SID $sid -Confirm:$false -ErrorAction Stop
                $knownUserNames = @($knownUserNames | Where-Object { $_ -ne $user.Name })
                $messages += "Removed user account '$($user.Name)' (profile files kept)"
                continue
            }

            $isNewUser = $knownUserNames -notcontains $user.Name

            #region Create the user, which requires a password
            if ($isNewUser) {
                if (-not $user.Password) {
                    throw 'a Password is required to create a new user; set one or use a {{password:...}} placeholder'
                }
                Set-UserPasswordHC -UserName $user.Name -Password $user.Password -NewUser
                $knownUserNames += $user.Name
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
            $operation = if ($isRemove) { 'remove' } else { 'create or update' }
            $errors += "Failed to $operation user account '$($user.Name)': $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }