<#
    .SYNOPSIS
        Export or import user rules.

    .DESCRIPTION
        This script should be run on a machine that has all the required
        users already created on the computer. Then run the script with action
        'Export' which will create a file containing the user accounts.
        On another machine this script can be run with action 'Import' to
        recreate the required user accounts.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the user accounts

    .EXAMPLE
        & 'C:\UserAccounts.ps1' -DataFolder 'C:\UserAccounts' -Action 'Export'

        Export all user accounts on the current computer to the folder 
        'C:\UserAccounts'

    .EXAMPLE
        & 'C:\UserAccounts.ps1' -DataFolder 'C:\UserAccounts' -Action 'Import'

        Restore all user accounts in the folder 'C:\UserAccounts' on the current computer
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$UserAccountsFileName = 'UserAccounts.xml'
)

Begin {
    Try {
        $exportFile = Join-Path -Path $DataFolder -ChildPath $UserAccountsFileName

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
            If (-not (Test-Path -LiteralPath $exportFile -PathType Leaf)) {
                throw "User accounts file '$exportFile' not found"
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
            Write-Verbose "Export user accounts to file '$exportFile'"
            If ($users = Get-LocalUser | Where-Object { $_.Enabled }) {
                $users | ForEach-Object {
                    Write-Verbose "User account '$($_.Name)' description '$($_.description)'"
                }
                Write-Verbose "Export to file '$exportFile'"
                $users | Export-Clixml -LiteralPath $exportFile -EA Stop
            }
            else {
                throw 'No enabled local user accounts found'
            }
        }
        else {
            Write-Verbose "Import user accounts from file '$exportFile'"
            $importedUsers = Import-Clixml -LiteralPath $exportFile -EA Stop

            $knownComputerUsers = Get-LocalUser

            foreach ($user in $importedUsers) {
                try {                    
                    Write-Verbose "User '$($user.Name)'"
                    if ($knownComputerUsers.Name -NotContains $user.Name) {
                        $password = ConvertTo-SecureString 'P@s/-%*D!' -AsPlainText -Force
                        # $Password = Read-Host -AsSecureString
                        $newParams = @{
                            Name        = $user.Name 
                            Password    = $password 
                            ErrorAction = 'Stop'
                        }
                        New-LocalUser @newParams
                    }
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