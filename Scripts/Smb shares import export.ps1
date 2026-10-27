#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Smb shares as a configuration section.
.DESCRIPTION
    Import creates or updates each share, then brings its share and NTFS
    permissions in line with the configuration. Permissions are changed in a
    way that never leaves a share with less access than configured:
    - Share permissions: configured entries are granted (Allow) or blocked
      (Deny) first; existing entries that are not configured are only removed
      when every configured entry could be applied.
    - NTFS permissions: the complete new ACL is built in memory and written
      once; when any configured entry cannot be built, the folder's current
      permissions are kept.
    A share without configured share or NTFS entries keeps its current
    permissions. Administrative shares (ADMIN$, IPC$, C$, ...) are managed by
    Windows: they are not exported and are skipped on import. Each problem is
    reported in Errors and the remaining shares are still processed.
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
function Convert-AccountNameHC {
    param([Parameter(Mandatory)][string]$Name)
    $accountName = $Name
    if ($accountName -like '*\*') {
        $split = $accountName.Split('\')
        if (
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
function Test-AccountExistsHC {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $accountExists.ContainsKey($Name)) {
        try {
            $null = ([System.Security.Principal.NTAccount]$Name).Translate([System.Security.Principal.SecurityIdentifier])
            $accountExists[$Name] = $true
        }
        catch { $accountExists[$Name] = $false }
    }
    $accountExists[$Name]
}
function Resolve-AccountNameHC {
    # Convert the account name and fail when it does not exist on this computer
    param([Parameter(Mandatory)][string]$Name)
    $accountName = Convert-AccountNameHC -Name $Name
    if (-not (Test-AccountExistsHC -Name $accountName)) {
        throw "account '$accountName' does not exist on '$env:COMPUTERNAME'"
    }
    $accountName
}
function Test-AdministrativeShareHC {
    param([string]$Name)
    $Name -match '^(ADMIN|IPC|[A-Za-z])\$$'
}
#endregion
$exportData = $null
$messages = @()
$errors = @()
$accountExists = @{}
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}

if ($Action -eq 'Export') {
    #region Capture section
    $shares = @(Get-SmbShare | Where-Object { -not $_.Special -and -not (Test-AdministrativeShareHC $_.Name) })
    $exportData = [ordered]@{
        Shares = @($shares | Select-Object Name, Description, Path, ScopeName,
            @{Name = 'CachingMode'; Expression = { [string]$_.CachingMode } },
            @{Name = 'SmbInstance'; Expression = { [string]$_.SmbInstance } },
            @{Name = 'FolderEnumerationMode'; Expression = { [string]$_.FolderEnumerationMode } },
            CATimeout, EncryptData, ThrottleLimit, ConcurrentUserLimit, ContinuouslyAvailable)
        Access = @($shares | Get-SmbShareAccess | Select-Object Name, ScopeName, AccountName,
            @{Name = 'AccessControlType'; Expression = { [string]$_.AccessControlType } },
            @{Name = 'AccessRight'; Expression = { [string]$_.AccessRight } })
        NTFS   = @(foreach ($share in $shares | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container -ErrorAction Ignore) }) {
                try {
                    $acl = Get-Acl -LiteralPath $share.Path
                    [ordered]@{
                        Name                    = $share.Name
                        Owner                   = $acl.Owner
                        AreAccessRulesProtected = $acl.AreAccessRulesProtected
                        Access                  = @($acl.Access | Where-Object { -not $_.IsInherited } | Select-Object @{Name = 'IdentityReference'; Expression = { [string]$_.IdentityReference } },
                            @{Name = 'AccessControlType'; Expression = { [string]$_.AccessControlType } },
                            @{Name = 'FileSystemRights'; Expression = { [string]$_.FileSystemRights } },
                            @{Name = 'InheritanceFlags'; Expression = { [string]$_.InheritanceFlags } },
                            @{Name = 'PropagationFlags'; Expression = { [string]$_.PropagationFlags } })
                    }
                }
                catch {
                    $errors += "Failed to read the NTFS permissions of share '$($share.Name)' on '$($share.Path)': $($_.Exception.Message)"
                }
            })
    }
    #endregion
    $messages = @('Exported Smb shares')
}
else {
    #region Apply section
    foreach ($share in @($Data.Shares)) {
        if (Test-AdministrativeShareHC $share.Name) {
            $messages += "Skipped share '$($share.Name)': administrative shares are managed by Windows"
            continue
        }
        Write-Verbose "Smb share '$($share.Name)' path '$($share.Path)'"

        #region Create or update the share
        try {
            if ([string]::IsNullOrWhiteSpace($share.Path)) { throw 'the share has no Path' }
            if (-not (Test-Path -LiteralPath $share.Path -PathType Container)) {
                $null = New-Item -Path $share.Path -ItemType Directory
            }
            $isNewShare = -not (Get-SmbShare -Name $share.Name -ErrorAction Ignore)
            if ($isNewShare) {
                $null = New-SmbShare -Path $share.Path -Name $share.Name
            }
            # Only configured settings; an empty value would fail on settings
            # such as CachingMode, which only accept specific values
            $setShareParams = @{ Name = $share.Name; Confirm = $false }
            foreach ($setting in @('Description', 'ScopeName', 'CachingMode', 'FolderEnumerationMode',
                    'CATimeout', 'EncryptData', 'ThrottleLimit', 'ConcurrentUserLimit', 'ContinuouslyAvailable')) {
                $value = $share.$setting
                if ($null -ne $value -and -not ($value -is [string] -and $value -eq '')) { $setShareParams[$setting] = $value }
            }
            $null = Set-SmbShare @setShareParams
            if ($isNewShare) { $messages += "Created share '$($share.Name)' on '$($share.Path)'" }
            else { $messages += "Updated share '$($share.Name)' on '$($share.Path)'" }
        }
        catch {
            $errors += "Failed to create or update share '$($share.Name)': $($_.Exception.Message)"
            # Without the share, its permissions cannot be set
            continue
        }
        #endregion

        #region Share permissions: apply configured entries, then remove the others
        $configuredAccess = @($Data.Access | Where-Object { $_.Name -eq $share.Name })
        if ($configuredAccess.Count) {
            $wanted = @()
            $accessFailed = $false
            foreach ($ace in $configuredAccess) {
                try {
                    $accountName = Resolve-AccountNameHC -Name $ace.AccountName
                    $isDeny = [string]$ace.AccessControlType -eq 'Deny'
                    $wanted += [pscustomobject]@{ AccountName = $accountName; IsDeny = $isDeny; AccessRight = [string]$ace.AccessRight }
                    if ($isDeny) {
                        # A Deny entry must never be applied as an Allow entry
                        $null = Block-SmbShareAccess -Name $share.Name -AccountName $accountName -Force
                        $messages += "Share '$($share.Name)': denied access for '$accountName'"
                    }
                    else {
                        $null = Grant-SmbShareAccess -Name $share.Name -AccountName $accountName -AccessRight $ace.AccessRight -Force
                        $messages += "Share '$($share.Name)': granted '$($ace.AccessRight)' access to '$accountName'"
                    }
                }
                catch {
                    $accessFailed = $true
                    $errors += "Failed to set share permission '$($ace.AccessControlType) $($ace.AccessRight)' for '$($ace.AccountName)' on share '$($share.Name)': $($_.Exception.Message)"
                }
            }
            if ($accessFailed) {
                $errors += "Share '$($share.Name)': existing share permissions that are not in the configuration were kept, because not all configured permissions could be applied"
            }
            else {
                foreach ($current in @(Get-SmbShareAccess -Name $share.Name)) {
                    $isDeny = [string]$current.AccessControlType -eq 'Deny'
                    $isWanted = $wanted | Where-Object {
                        $_.AccountName -eq $current.AccountName -and $_.IsDeny -eq $isDeny -and
                        ($isDeny -or $_.AccessRight -eq [string]$current.AccessRight)
                    }
                    if ($isWanted) { continue }
                    try {
                        if ($isDeny) { $null = Unblock-SmbShareAccess -Name $share.Name -AccountName $current.AccountName -Force }
                        else { $null = Revoke-SmbShareAccess -Name $share.Name -AccountName $current.AccountName -Force }
                        $messages += "Share '$($share.Name)': removed share permission for '$($current.AccountName)'"
                    }
                    catch {
                        $errors += "Failed to remove the share permission of '$($current.AccountName)' on share '$($share.Name)': $($_.Exception.Message)"
                    }
                }
            }
        }
        #endregion

        #region NTFS permissions: build the complete ACL and write it once
        $aclImport = @($Data.NTFS | Where-Object { $_.Name -eq $share.Name }) | Select-Object -First 1
        if ($aclImport) {
            try {
                $ntfsProblems = @()
                $rules = foreach ($ace in @($aclImport.Access)) {
                    try {
                        $accountName = Resolve-AccountNameHC -Name $ace.IdentityReference
                        New-Object System.Security.AccessControl.FileSystemAccessRule(
                            [System.Security.Principal.NTAccount]$accountName,
                            [System.Security.AccessControl.FileSystemRights]$ace.FileSystemRights,
                            [System.Security.AccessControl.InheritanceFlags]$ace.InheritanceFlags,
                            [System.Security.AccessControl.PropagationFlags]$ace.PropagationFlags,
                            [System.Security.AccessControl.AccessControlType]$ace.AccessControlType
                        )
                    }
                    catch {
                        $ntfsProblems += "Failed to prepare NTFS permission '$($ace.AccessControlType) $($ace.FileSystemRights)' for '$($ace.IdentityReference)' on share '$($share.Name)': $($_.Exception.Message)"
                    }
                }
                if ($ntfsProblems.Count) {
                    $errors += $ntfsProblems
                    throw 'the current NTFS permissions were kept, because not all configured permissions could be prepared'
                }
                $acl = Get-Acl -LiteralPath $share.Path
                foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) {
                    $null = $acl.RemoveAccessRule($rule)
                }
                $acl.SetAccessRuleProtection([bool]$aclImport.AreAccessRulesProtected, $false)
                foreach ($rule in @($rules)) { $acl.AddAccessRule($rule) }
                if ($aclImport.Owner) {
                    try {
                        $acl.SetOwner([System.Security.Principal.NTAccount](Resolve-AccountNameHC -Name $aclImport.Owner))
                    }
                    catch {
                        $errors += "Failed to set owner '$($aclImport.Owner)' on share '$($share.Name)', the current owner was kept: $($_.Exception.Message)"
                    }
                }
                Set-Acl -LiteralPath $share.Path -AclObject $acl
                $messages += "Share '$($share.Name)': set $(@($rules).Count) NTFS permission(s) on '$($share.Path)'"
            }
            catch {
                $errors += "Failed to set the NTFS permissions on '$($share.Path)' for share '$($share.Name)': $($_.Exception.Message)"
            }
        }
        #endregion
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }