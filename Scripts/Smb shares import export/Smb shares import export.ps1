#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Smb shares as a configuration section.
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
. "$PSScriptRoot\..\Common\Section.ps1"
#region Windows helpers
Function Convert-AccountNameHC {
        
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
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$shares = @(Get-SmbShare)
$exportData = [ordered]@{
    Shares = @($shares | Select-Object Name, Description, Path, ScopeName,
        @{Name='CachingMode';Expression={[string]$_.CachingMode}},
        @{Name='SmbInstance';Expression={[string]$_.SmbInstance}},
        @{Name='FolderEnumerationMode';Expression={[string]$_.FolderEnumerationMode}},
        CATimeout, EncryptData, ThrottleLimit, ConcurrentUserLimit, ContinuouslyAvailable)
    Access = @($shares | Get-SmbShareAccess | Select-Object Name, ScopeName, AccountName,
        @{Name='AccessControlType';Expression={[string]$_.AccessControlType}},
        @{Name='AccessRight';Expression={[string]$_.AccessRight}})
    Ntfs = @(foreach ($share in $shares | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container -ErrorAction Ignore) }) {
        $acl = Get-Acl -Path $share.Path
        [ordered]@{
            Name = $share.Name
            Owner = $acl.Owner
            AreAccessRulesProtected = $acl.AreAccessRulesProtected
            Access = @($acl.Access | Where-Object { -not $_.IsInherited } | Select-Object
                @{Name='IdentityReference';Expression={[string]$_.IdentityReference}},
                @{Name='AccessControlType';Expression={[string]$_.AccessControlType}},
                @{Name='FileSystemRights';Expression={[string]$_.FileSystemRights}},
                @{Name='InheritanceFlags';Expression={[string]$_.InheritanceFlags}},
                @{Name='PropagationFlags';Expression={[string]$_.PropagationFlags}})
        }
    })
}
    #endregion
    $messages = @('Exported Smb shares')
}
else {
    #region Apply section
    $messages = @(& {
$accountsValid = @{}

$smbShares = $Data.Shares

$smbSharesAccesses = $Data.Access
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

                    If ($Data.Ntfs | Where-Object { $_.Name -eq $share.Name }) {
                        $aclImport = $Data.Ntfs | Where-Object { $_.Name -eq $share.Name }
                    
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
                    Write-Error "Failed to create smb share '$($share.Name)': $_"
                    $Error.RemoveAt(1)
                }
            }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
