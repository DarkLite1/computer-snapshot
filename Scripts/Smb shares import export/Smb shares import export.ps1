<#
    .SYNOPSIS
        Export or import smb shares.

    .DESCRIPTION
        This script should be run on a computer that has the correct smb shares configured, then it can be run to export the smb shares. On another 
        computer the exported shares can then be imported.
        
    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER ImportFolder
        Folder of the files containing all the smb shares data.

    .EXAMPLE
        $exportParams = @{
            Action     = 'Export'
            DataFolder = 'C:\SmbShares'
        }
        & 'C:\ImportExportSmbShares.ps1' @exportParams

        Export all smb shares on the current computer to the folder 'SmbShares'

    .EXAMPLE
        $importParams = @{
            Action     = 'Import'
            DataFolder = 'C:\SmbShares'
        }
        & 'C:\ImportExportSmbShares.ps1' @importParams

        Import all smb shares in the folder 'SmbShares'
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$smbSharesFileName = 'SmbShares.json',
    [String]$smbSharesAccessFileName = 'SmbSharesAccess.json'
)

Begin {    
    Function Convert-AccountNameHC {
        <#
            .SYNOPSIS
                Convert an account name coming from another computer to 
                an account name usable on the current computer.
    
            .EXAMPLE
                Convert-AccountNameHC -Name 'PC1\mike'
                Returns 'PC2\mike' when the computer name of the current
                computer is 'PC2'
    
            .EXAMPLE
                Convert-AccountNameHC -Name 'BUILTIN\Administrators'
                Returns 'BUILTIN\Administrators'
    
            .EXAMPLE
                Convert-AccountNameHC -Name 'CONTOSO\bob'
                Returns 'CONTOSO\bob'
    
            .EXAMPLE
                Convert-AccountNameHC -Name 'Everyone'
                Returns 'Everyone'
        #>
        Param (
            [Parameter(Mandatory)]
            [String]$Name
        )
    
        Try {
            $accountName = $Name
            If ($accountName -like '*\*') {
                $split = $accountName.Split('\')
                If ( 
                    ($split[0] -ne $env:USERDOMAIN) -and
                    ($split[0] -ne $env:COMPUTERNAME) -and
                    ($split[0] -ne 'BUILTIN') -and
                    ($split[0] -ne 'NT AUTHORITY')
                ) {
                    $accountName = "$env:COMPUTERNAME\$($split[1])"
                }
            }
            $accountName
        }
        Catch {
            throw "Failed to convert the account name of '$Name': $_"
        }
    }
    Function Test-AccountExistsHC {
        <#
            .SYNOPSIS
                Test if an account exists
    
            .DESCRIPTION
                Test if an account exists and can be used to set NTFS permissions. Returns true if valid and false when not valid.
    
            .EXAMPLE
                Returns true for all existing accounts:
                Test-AccountExistsHC -Name "$env:USERDOMAIN\$env:USERNAME"
                Test-AccountExistsHC -Name 'NT AUTHORITY\Everyone'
                Test-AccountExistsHC -Name 'Everyone'
                Test-AccountExistsHC -Name "$env:COMPUTERNAME\ExistingLocalAccount"
                Test-AccountExistsHC -Name 'ExistingLocalAccount'
                Test-AccountExistsHC -Name 'BUILTIN\Administrators'
    
                Returns false for all accounts that do not exist:
                Test-AccountExistsHC -Name "$env:USERDOMAIN\NonExisting"
                Test-AccountExistsHC -Name 'BUILTIN\Everyone'
                Test-AccountExistsHC -Name 'NonExisting'
        #>
        
        Param (
            [Parameter(Mandatory)]
            [String]$Name
        )
    
        Try {
            $tmpFile = New-TemporaryFile
    
            $acl = Get-Acl -LiteralPath $tmpFile.FullName
    
            Try {
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule(
                    (New-Object System.Security.AccessControl.FileSystemAccessRule(
                        [System.Security.Principal.NTAccount]$Name,
                        [System.Security.AccessControl.FileSystemRights]::FullControl,
                        [System.Security.AccessControl.InheritanceFlags]::None,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow
                    )
                    )
                )
                $acl | Set-Acl -LiteralPath $tmpFile.FullName -ErrorAction Stop
    
                Write-Verbose "Account '$Name' exists"
                $true
            }
            Catch {
                $Error.RemoveAt(0)
                Write-Verbose "Account '$Name' does not exist"
                $false
            }
        }
        Catch {
            throw "Failed to test if account '$Name' exists: $_"
        }
        Finally {
            $tmpFile | Remove-Item
        }
    }

    Try {
        $smbSharesFile = Join-Path -Path $DataFolder -ChildPath $smbSharesFileName
        $smbSharesAccessFile = Join-Path -Path $DataFolder -ChildPath $smbSharesAccessFileName

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
            If (-not (Test-Path -LiteralPath $smbSharesFile -PathType Leaf)) {
                throw "Smb shares file '$smbSharesFile' not found"
            }
            If (-not (Test-Path -LiteralPath $smbSharesAccessFile -PathType Leaf)) {
                throw "Smb shares access file '$smbSharesAccessFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action smb shares failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            If ($smbShares = @(Get-SmbShare)) {
                Write-Verbose "Smb shares '$($smbShares.Name -join "', '")'"
                Write-Verbose "Export smb shares to file '$smbSharesFile'"
                $smbShares | Select-Object -Property Name, Description, Path, 
                ScopeName, 
                @{
                    Name       = 'CachingMode';
                    Expression = { [String]$_.CachingMode } 
                }, 
                @{
                    Name       = 'SmbInstance'; 
                    Expression = { [String]$_.SmbInstance } 
                }, 
                @{
                    Name       = 'FolderEnumerationMode'; 
                    Expression = { [String]$_.FolderEnumerationMode } 
                }, 
                CATimeout, EncryptData, ThrottleLimit, ConcurrentUserLimit, 
                ContinuouslyAvailable | ConvertTo-Json | 
                Out-File -LiteralPath $smbSharesFile -Encoding utf8

                Write-Output "Exported $($smbShares.Count) smb shares"

                $smbSharesAccess = $smbShares | Get-SmbShareAccess
                Write-Verbose "Export smb share access permissions to file '$smbSharesAccessFile'"
                $smbSharesAccess | Select-Object -Property Name, 
                ScopeName, AccountName, 
                @{
                    Name       = 'AccessControlType'; 
                    Expression = { [String]$_.AccessControlType } 
                },
                @{
                    Name       = 'AccessRight'; 
                    Expression = { [String]$_.AccessRight } 
                } | ConvertTo-Json | 
                Out-File -LiteralPath $smbSharesAccessFile -Encoding utf8
                    
                Write-Output "Exported $($smbSharesAccess.Count) smb share accesses"

                $ntfsFolder = New-Item -Path (Join-Path $DataFolder 'NTFS') -ItemType Directory

                Foreach ($share in $smbShares | 
                    Where-Object { 
                        ($_.Path) -and
                        (Test-Path -LiteralPath $_.Path -PathType Container -EA Ignore)
                    }
                ) {
                    $ntfsFile = Join-Path -Path $ntfsFolder -ChildPath "$($share.Name).json"
                    $acl = Get-Acl -Path $share.Path
                    Write-Verbose "Smb share '$($share.Name)' export NTFS permissions to file '$ntfsFile'"

                    @{
                        Owner                   = $acl.Owner
                        AreAccessRulesProtected = $acl.AreAccessRulesProtected
                        Access                  = @(
                            $acl.Access | 
                            Where-Object { -not $_.IsInherited } | 
                            Select-Object -Property @{
                                Name       = 'IdentityReference'; 
                                Expression = { [String]$_.IdentityReference } 
                            },
                            @{
                                Name       = 'AccessControlType'; 
                                Expression = { [String]$_.AccessControlType } 
                            },
                            @{
                                Name       = 'FileSystemRights'; 
                                Expression = { [String]$_.FileSystemRights } 
                            },
                            @{
                                Name       = 'InheritanceFlags'; 
                                Expression = { [String]$_.InheritanceFlags } 
                            },
                            @{
                                Name       = 'PropagationFlags'; 
                                Expression = { [String]$_.PropagationFlags } 
                            } 
                        )
                    } | ConvertTo-Json | 
                    Out-File -LiteralPath $ntfsFile -Encoding utf8
                }

                if ($ntfsFile) {
                    Write-Output 'Exported NTFS permissions'
                }
            }
            else {
                throw "No Smb shares found on '$env:COMPUTERNAME'"
            }
        }
        else {
            $accountsValid = @{}

            Write-Verbose "Import smb shares from file '$smbSharesFile'"
            $smbShares = Get-Content -LiteralPath $smbSharesFile -Encoding UTF8 -Raw | ConvertFrom-Json
        
            Write-Verbose "Import smb shares access from file '$smbSharesAccessFile'"
            $smbSharesAccesses = Get-Content -LiteralPath $smbSharesAccessFile -Encoding UTF8 -Raw | ConvertFrom-Json
        
            foreach ($share in $smbShares) {
                Try {
                    Write-Verbose "Smb share '$($share.Name)' path '$($share.Path)'"
          
                    #region Create smb share
                    If (-not (Test-Path -LiteralPath $share.Path -PathType Container)) {
                        Write-Verbose 'Create folder'
                        $null = New-Item -Path $share.Path -ItemType Directory
                    }

                    if (-not (Get-SmbShare -Name $share.Name -EA Ignore)) {
                        # does not add Description and other properties
                        $null = New-SmbShare -Path $share.Path -Name $share.Name
                    }

                    Write-Verbose 'Create smb share'
                    # also adds possible non existing accounts
                    $null = $share | Set-SmbShare -Confirm:$false -ErrorAction Stop
                    Write-Output "Smb share '$($share.Name)' created"
                    #endregion

                    #region Remove smb share permissions
                    # because some accounts might be missing on this computer
                    Write-Verbose 'Remove smb share permissions'
                    Get-SmbShare -Name $share.Name | Get-SmbShareAccess | 
                    ForEach-Object {
                        $revokeParams = @{
                            Name        = $_.Name
                            AccountName = $_.AccountName
                            Confirm     = $false
                            ErrorAction = 'Stop'
                        }
                        $null = Revoke-SmbShareAccess @revokeParams
                    }
                    #endregion

                    #region Add smb share permissions
                    foreach ($ace in $smbSharesAccesses | 
                        Where-Object { $_.Name -eq $share.Name }) {
                        Try {
                            $accountName = Convert-AccountNameHC -Name $ace.AccountName

                            #region Test if account exists
                            if ($accountsValid.Keys -NotContains $accountName) {
                                $accountsValid[$accountName] = Test-AccountExistsHC -Name $accountName
                            }
                            if (-not $accountsValid[$accountName]) {
                                Throw "Account does not exist on '$env:COMPUTERNAME'"
                            }
                            #endregion

                            Write-Verbose "Add smb permission '$($ace.AccessRight)' for '$accountName'"
                            $grantParams = @{
                                Name        = $ace.Name
                                AccountName = $accountName
                                AccessRight = $ace.AccessRight
                                Confirm     = $false
                                ErrorAction = 'Stop'
                            }
                            $null = Grant-SmbShareAccess @grantParams
                            Write-Output "Smb share '$($share.Name)' added smb permission '$($ace.AccessRight)' for '$($ace.Name)'"
                        }
                        Catch {
                            Write-Error "Failed to grant account '$accountName' smb share permission '$($ace.AccessRight)' on share '$($ace.Name)' with path '$($share.Path)': $_"
                            $Error.RemoveAt(1)
                        }
                    }
                    #endregion
        
                    #region Add NTFS permissions
                    $ntfsFile = Join-Path -Path $DataFolder -ChildPath "NTFS\$($share.Name).json"
                    If (Test-Path -Path $ntfsFile -PathType Leaf) {
                        $aclImport = Get-Content -LiteralPath $ntfsFile -Encoding UTF8 | ConvertFrom-Json
                    
                        #region Create ACE's
                        $aceList = ForEach ($ace in $aclImport.Access) {
                            Try {
                                $accountName = Convert-AccountNameHC -Name $ace.IdentityReference
       
                                #region Test if account exists
                                if ($accountsValid.Keys -NotContains $accountName) {
                                    $accountsValid[$accountName] = Test-AccountExistsHC -Name $accountName
                                }
                                if (-not $accountsValid[$accountName]) {
                                    Throw "Account does not exist on '$env:COMPUTERNAME'"
                                }
                                #endregion

                                New-Object System.Security.AccessControl.FileSystemAccessRule(
                                    [System.Security.Principal.NTAccount]$accountName,
                                    [System.Security.AccessControl.FileSystemRights]$ace.FileSystemRights,
                                    [System.Security.AccessControl.InheritanceFlags]$ace.InheritanceFlags,
                                    [System.Security.AccessControl.PropagationFlags]$ace.PropagationFlags,
                                    [System.Security.AccessControl.AccessControlType]$ace.AccessControlType
                                )
                            }
                            Catch {
                                Write-Error "Failed to grant account '$accountName' NTFS permission '$($ace.FileSystemRights)' on folder '$($share.Path)' for share '$($share.Name)': $_"
                                $Error.RemoveAt(1)
                            }
                        }
                        #endregion

                        #region Remove non inherited ACE's
                        $acl = Get-Acl -LiteralPath $share.Path
                        $acl.Access | Where-Object { -not $_.isInherited } | 
                        ForEach-Object { $null = $acl.RemoveAccessRule($_) }
                        $acl | Set-Acl -LiteralPath $share.Path
                        #endregion

                        #region Set new ACL
                        try {
                            $ownerName = Convert-AccountNameHC -Name $aclImport.Owner

                            #region Test if account exists
                            if ($accountsValid.Keys -NotContains $ownerName) {
                                $accountsValid[$ownerName] = Test-AccountExistsHC -Name $ownerName
                            }
                            if (-not $accountsValid[$ownerName]) {
                                Throw "Account does not exist on '$env:COMPUTERNAME'"
                            }
                            #endregion

                            $ownerAccount = [System.Security.Principal.NTAccount]$ownerName
                        }
                        catch {
                            $ownerAccount = [System.Security.Principal.NTAccount]'BUILTIN\Administrators'
                            Write-Error "Failed to set account '$ownerName' as 'Owner' on folder '$($share.Path)' for share '$($share.Name)': $_"
                            $Error.RemoveAt(1)
                        }

                        $acl.SetAccessRuleProtection($aclImport.AreAccessRulesProtected, $false)
                        $acl.SetOwner($ownerAccount)
                        $aceList | ForEach-Object {
                            Write-Verbose "Add NTFS permission '$($_.FileSystemRights)' for account '$($_.IdentityReference)'"
                            $acl.AddAccessRule($_) 

                            Write-Output "Smb share '$($share.Name)' added NTFS permission '$($_.FileSystemRights)' for '$($_.IdentityReference)'"
                        }
                        if (-not $aceList) {
                            Write-Output "Smb share '$($share.Name)' no NTFS permission added as none were found in the import file. Most likely they are all inherited and not explicit permissions were set."
                        }
                        $acl | Set-Acl -LiteralPath $share.Path
                        #endregion
                    }
                    #endregion
                }
                Catch {
                    throw "Failed to create smb share '$($share.Name)': $_"
                }
            }
        }
    }
    Catch {
        throw "$Action smb shares failed: $_"
    }
}