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
      account running the restore cannot be removed, nor the last enabled
      local administrator. When the members of the Administrators group
      cannot be read, no account is removed.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written
    here.
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
    try {
        $identity.User.Value
    }
    finally {
        $identity.Dispose()
    }
}

function Assert-NotLastAdministratorHC {
    # Throws when the local account with Sid is the only enabled member of
    # the local Administrators group. Other enabled local accounts, domain
    # and Azure AD users and groups count as another administrator.
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalUsers
    )
    try {
        # The group name depends on the Windows language, its SID does not
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544')
    }
    catch {
        throw (
            'cannot read the members of the local Administrators group ' +
            "($($_.Exception.Message)); removal refused"
        )
    }

    $memberSids = @($members | ForEach-Object { [string]$_.SID })
    if ($memberSids -notcontains $Sid) {
        return
    }

    $enabledLocalSids = @(
        $LocalUsers |
        Where-Object { $_.Enabled } |
        ForEach-Object { [string]$_.SID }
    )
    $localSids = @($LocalUsers | ForEach-Object { [string]$_.SID })

    $otherAdministrators = @(
        $members | Where-Object {
            $memberSid = [string]$_.SID
            $memberSid -ne $Sid -and (
                $enabledLocalSids -contains $memberSid -or (
                    $localSids -notcontains $memberSid -and
                    [string]$_.PrincipalSource -in @(
                        'ActiveDirectory', 'AzureAD'
                    )
                )
            )
        }
    )
    if (-not $otherAdministrators.Count) {
        throw (
            "'$Name' is the last enabled local administrator; " +
            'removal refused'
        )
    }
}

function Set-UserPasswordHC {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password,
        [switch]$NewUser
    )
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    try {
        if ($NewUser) {
            $null = New-LocalUser -Name $UserName -Password $securePassword
        }
        else { Set-LocalUser -Name $UserName -Password $securePassword }
    }
    catch {
        # Match by name and error id: the exception type only exists once the
        # LocalAccounts module is loaded, and PowerShell 7 may deserialize it
        $isInvalidPassword = (
            $_.Exception.GetType().Name -eq 'InvalidPasswordException' -or
            $_.FullyQualifiedErrorId -like 'InvalidPassword*'
        )
        if (-not $isInvalidPassword) { throw }
        if ($NewUser) {
            # Windows can create the account before rejecting the password
            Write-Verbose "User '$UserName': password rejected, remove user"
            Remove-LocalUser -Name $UserName -ErrorAction Ignore
        }
        throw (
            'the password does not meet the length, complexity or history ' +
            'requirements of the password policy'
        )
    }
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import User accounts: section is empty, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export User accounts'
    $users = @(Get-LocalUser)
    Write-Verbose "Found $($users.Count) local user(s)"

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
    $messages.Insert(
        0,
        'Exported User accounts; restoring this export asks for the ' +
        'password of each user'
    )
}
else {
    #region Apply section
    Write-Verbose 'Import User accounts'
    $knownUserNames = @(Get-LocalUser | ForEach-Object { $_.Name })
    foreach ($user in $Data) {
        $isRemove = $user.Action -eq 'Remove'
        try {
            Write-Verbose "User '$($user.Name)'"
            $problems = @(Test-UserAccountEntryHC $user)
            if ($problems.Count) { throw ($problems -join '; ') }

            if ($isRemove) {
                Write-Verbose "User '$($user.Name)': remove"
                # Read the accounts again: earlier entries can have created
                # or removed accounts
                $currentUsers = @(Get-LocalUser)
                $matchingUsers = @(
                    $currentUsers | Where-Object { $_.Name -eq $user.Name }
                )
                if (-not $matchingUsers.Count) {
                    $messages.Add(
                        "User account '$($user.Name)' not found, " +
                        'nothing to remove'
                    )
                    continue
                }
                if ($matchingUsers.Count -ne 1) {
                    throw 'the name does not identify exactly one local account'
                }
                $sid = [string]$matchingUsers[0].SID
                if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-(\d+)$') {
                    throw 'cannot verify the local account SID; removal refused'
                }
                if ([long]$Matches[1] -lt 1000) {
                    throw 'built-in Windows accounts cannot be removed'
                }
                $currentSid = Get-CurrentUserSidHC
                if (-not $currentSid) {
                    throw (
                        'cannot identify the account running the restore; ' +
                        'removal refused'
                    )
                }
                if ($sid -eq $currentSid) {
                    throw 'the account running the restore cannot be removed'
                }
                $assertParams = @{
                    Sid        = $sid
                    Name       = $user.Name
                    LocalUsers = $currentUsers
                }
                Assert-NotLastAdministratorHC @assertParams
                Write-Verbose "Remove local user with SID '$sid'"
                Remove-LocalUser -SID $sid -Confirm:$false -ErrorAction Stop
                $knownUserNames = @(
                    $knownUserNames | Where-Object { $_ -ne $user.Name }
                )
                $messages.Add(
                    "Removed user account '$($user.Name)' (profile files kept)"
                )
                continue
            }

            $isNewUser = $knownUserNames -notcontains $user.Name

            #region Create the user, which requires a password
            if ($isNewUser) {
                if (-not $user.Password) {
                    throw (
                        'a Password is required to create a new user; ' +
                        'set one or use a {{password:...}} placeholder'
                    )
                }
                Write-Verbose "User '$($user.Name)': create"
                $passwordParams = @{
                    UserName = $user.Name
                    Password = $user.Password
                    NewUser  = $true
                }
                Set-UserPasswordHC @passwordParams
                $knownUserNames += $user.Name
            }
            #endregion

            #region Set user account details
            # Only Name is required: settings missing from the configuration
            # are left unchanged, because passing $null to a Boolean
            # parameter fails
            $properties = @(
                $user.PSObject.Properties | ForEach-Object { $_.Name }
            )
            $setUserParams = @{ Name = $user.Name }
            if ($properties -contains 'PasswordExpires') {
                # null means the password never expires
                $setUserParams.PasswordNeverExpires = (
                    -not [bool]$user.PasswordExpires
                )
            }
            if ($null -ne $user.FullName) {
                $setUserParams.FullName = $user.FullName
            }
            if ($null -ne $user.Description) {
                $setUserParams.Description = $user.Description
            }
            if ($null -ne $user.UserMayChangePassword) {
                $setUserParams.UserMayChangePassword = (
                    [bool]$user.UserMayChangePassword
                )
            }
            if ($properties -contains 'AccountExpires') {
                if ($user.AccountExpires) {
                    $setUserParams.AccountExpires = $user.AccountExpires
                }
                else {
                    $setUserParams.AccountNeverExpires = $true
                }
            }
            Write-Verbose "User '$($user.Name)': update account details"
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
                Write-Verbose "User '$($user.Name)': update password"
                Set-UserPasswordHC -UserName $user.Name -Password $user.Password
            }
            #endregion

            $state = if (
                $properties -notcontains 'Enabled' -or $null -eq $user.Enabled
            ) {
                ''
            }
            elseif ($user.Enabled) { ' (enabled)' }
            else { ' (disabled)' }
            if ($isNewUser) {
                $messages.Add("Created user '$($user.Name)'$state")
            }
            elseif ($user.Password) {
                $messages.Add(
                    "Updated user '$($user.Name)' and its password$state"
                )
            }
            else {
                $messages.Add(
                    "Updated user '$($user.Name)', password unchanged$state"
                )
            }
        }
        catch {
            $operation = if ($isRemove) { 'remove' }
            else { 'create or update' }
            $errors.Add(
                "Failed to $operation user account '$($user.Name)': " +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams