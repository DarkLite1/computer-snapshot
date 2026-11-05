#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Smb shares as a configuration section.
.DESCRIPTION
    Data is a list of shares. Each share has its settings, its share
    permissions in Access and the NTFS permissions of its folder in NTFS.

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
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Smb shares: section is empty, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    # One entry per share, with its share permissions (Access) and the NTFS
    # permissions of its folder (NTFS). Built-in accounts such as Everyone
    # get their English name, which a restore translates to the Windows
    # language of that computer.
    Write-Verbose 'Export Smb shares'
    $shares = @(
        Get-SmbShare | Where-Object {
            -not $_.Special -and
            -not (Test-AdministrativeShareHC $_.Name)
        }
    )
    Write-Verbose "Found $($shares.Count) non-administrative share(s)"

    $ntfsAccessProperties = @(
        @{
            Name       = 'IdentityReference'
            Expression = {
                ConvertTo-PortableAccountNameHC -Name (
                    [string]$_.IdentityReference
                )
            }
        },
        @{
            Name       = 'AccessControlType'
            Expression = { [string]$_.AccessControlType }
        },
        @{
            Name       = 'FileSystemRights'
            Expression = { [string]$_.FileSystemRights }
        },
        @{
            Name       = 'InheritanceFlags'
            Expression = { [string]$_.InheritanceFlags }
        },
        @{
            Name       = 'PropagationFlags'
            Expression = { [string]$_.PropagationFlags }
        }
    )

    $exportData = @(
        foreach ($share in $shares) {
            Write-Verbose "Share '$($share.Name)': export"
            $entry = [ordered]@{
                Name                  = $share.Name
                Description           = $share.Description
                Path                  = $share.Path
                ScopeName             = $share.ScopeName
                CachingMode           = [string]$share.CachingMode
                SmbInstance           = [string]$share.SmbInstance
                FolderEnumerationMode = [string]$share.FolderEnumerationMode
                CATimeout             = $share.CATimeout
                EncryptData           = $share.EncryptData
                ThrottleLimit         = $share.ThrottleLimit
                ConcurrentUserLimit   = $share.ConcurrentUserLimit
                ContinuouslyAvailable = $share.ContinuouslyAvailable
                Access                = @(
                    Get-SmbShareAccess -Name $share.Name | ForEach-Object {
                        [ordered]@{
                            AccountName       = (
                                ConvertTo-PortableAccountNameHC -Name (
                                    [string]$_.AccountName
                                )
                            )
                            AccessControlType = [string]$_.AccessControlType
                            AccessRight       = [string]$_.AccessRight
                        }
                    }
                )
            }

            $testPathParams = @{
                LiteralPath = $share.Path
                PathType    = 'Container'
                ErrorAction = 'Ignore'
            }
            if ($share.Path -and (Test-Path @testPathParams)) {
                try {
                    $acl = Get-Acl -LiteralPath $share.Path
                    $entry.NTFS = [ordered]@{
                        Owner                   = if ($acl.Owner) {
                            ConvertTo-PortableAccountNameHC -Name $acl.Owner
                        }
                        else { $acl.Owner }
                        AreAccessRulesProtected = $acl.AreAccessRulesProtected
                        Access                  = @(
                            $acl.Access |
                            Where-Object { -not $_.IsInherited } |
                            Select-Object $ntfsAccessProperties
                        )
                    }
                }
                catch {
                    $errors.Add(
                        'Failed to read the NTFS permissions of share ' +
                        "'$($share.Name)' on '$($share.Path)': " +
                        "$($_.Exception.Message)"
                    )
                }
            }
            else {
                Write-Verbose "Share '$($share.Name)': no folder, skip NTFS"
            }

            $entry
        }
    )
    #endregion

    $messages.Insert(0, 'Exported Smb shares')
}
else {
    #region Apply section
    Write-Verbose 'Import Smb shares'
    foreach ($share in @($Data | Where-Object { $null -ne $_ })) {
        if (Test-AdministrativeShareHC $share.Name) {
            Write-Verbose "Share '$($share.Name)': administrative, skip"
            $messages.Add(
                "Skipped share '$($share.Name)': " +
                'administrative shares are managed by Windows'
            )
            continue
        }
        Write-Verbose "Smb share '$($share.Name)' path '$($share.Path)'"

        #region Create or update the share
        try {
            if ([string]::IsNullOrWhiteSpace($share.Path)) {
                throw 'the share has no Path'
            }
            if (-not (Test-Path -LiteralPath $share.Path -PathType Container)) {
                Write-Verbose "Create folder '$($share.Path)'"
                $null = New-Item -Path $share.Path -ItemType Directory
            }
            $isNewShare = -not (
                Get-SmbShare -Name $share.Name -ErrorAction Ignore
            )
            if ($isNewShare) {
                Write-Verbose "Share '$($share.Name)': create"
                $null = New-SmbShare -Path $share.Path -Name $share.Name
            }
            # Only configured settings; an empty value would fail on settings
            # such as CachingMode, which only accept specific values
            $setShareParams = @{ Name = $share.Name; Confirm = $false }
            $settings = @(
                'Description', 'ScopeName', 'CachingMode',
                'FolderEnumerationMode', 'CATimeout', 'EncryptData',
                'ThrottleLimit', 'ConcurrentUserLimit', 'ContinuouslyAvailable'
            )
            foreach ($setting in $settings) {
                $value = $share.$setting
                if (
                    $null -ne $value -and
                    -not ($value -is [string] -and $value -eq '')
                ) {
                    $setShareParams[$setting] = $value
                }
            }
            Write-Verbose "Share '$($share.Name)': update settings"
            $null = Set-SmbShare @setShareParams
            if ($isNewShare) {
                $messages.Add(
                    "Created share '$($share.Name)' on '$($share.Path)'"
                )
            }
            else {
                $messages.Add(
                    "Updated share '$($share.Name)' on '$($share.Path)'"
                )
            }
        }
        catch {
            $errors.Add(
                "Failed to create or update share '$($share.Name)': " +
                "$($_.Exception.Message)"
            )
            # Without the share, its permissions cannot be set
            continue
        }
        #endregion

        #region Share permissions: apply configured, then remove the others
        $configuredAccess = @($share.Access | Where-Object { $null -ne $_ })
        if ($configuredAccess.Count) {
            Write-Verbose (
                "Share '$($share.Name)': apply " +
                "$($configuredAccess.Count) share permission(s)"
            )
            $wanted = @()
            $accessFailed = $false
            foreach ($ace in $configuredAccess) {
                try {
                    $accountName = Resolve-AccountNameHC -Name $ace.AccountName
                    $isDeny = [string]$ace.AccessControlType -eq 'Deny'
                    $wanted += [pscustomobject]@{
                        AccountName = $accountName
                        IsDeny      = $isDeny
                        AccessRight = [string]$ace.AccessRight
                    }
                    if ($isDeny) {
                        # A Deny entry must never be applied as an Allow entry
                        $blockParams = @{
                            Name        = $share.Name
                            AccountName = $accountName
                            Force       = $true
                        }
                        $null = Block-SmbShareAccess @blockParams
                        $messages.Add(
                            "Share '$($share.Name)': " +
                            "denied access for '$accountName'"
                        )
                    }
                    else {
                        $grantParams = @{
                            Name        = $share.Name
                            AccountName = $accountName
                            AccessRight = $ace.AccessRight
                            Force       = $true
                        }
                        $null = Grant-SmbShareAccess @grantParams
                        $messages.Add(
                            "Share '$($share.Name)': granted " +
                            "'$($ace.AccessRight)' access to '$accountName'"
                        )
                    }
                }
                catch {
                    $accessFailed = $true
                    $errors.Add(
                        'Failed to set share permission ' +
                        "'$($ace.AccessControlType) $($ace.AccessRight)' " +
                        "for '$($ace.AccountName)' on share " +
                        "'$($share.Name)': $($_.Exception.Message)"
                    )
                }
            }
            if ($accessFailed) {
                $errors.Add(
                    "Share '$($share.Name)': existing share permissions " +
                    'that are not in the configuration were kept, because ' +
                    'not all configured permissions could be applied'
                )
            }
            else {
                Write-Verbose (
                    "Share '$($share.Name)': remove share permissions " +
                    'that are not configured'
                )
                foreach ($current in @(Get-SmbShareAccess -Name $share.Name)) {
                    $isDeny = [string]$current.AccessControlType -eq 'Deny'
                    $isWanted = $wanted | Where-Object {
                        $_.AccountName -eq $current.AccountName -and
                        $_.IsDeny -eq $isDeny -and
                        (
                            $isDeny -or
                            $_.AccessRight -eq [string]$current.AccessRight
                        )
                    }
                    if ($isWanted) { continue }
                    try {
                        $removeParams = @{
                            Name        = $share.Name
                            AccountName = $current.AccountName
                            Force       = $true
                        }
                        if ($isDeny) {
                            $null = Unblock-SmbShareAccess @removeParams
                        }
                        else {
                            $null = Revoke-SmbShareAccess @removeParams
                        }
                        $messages.Add(
                            "Share '$($share.Name)': removed share " +
                            "permission for '$($current.AccountName)'"
                        )
                    }
                    catch {
                        $errors.Add(
                            'Failed to remove the share permission of ' +
                            "'$($current.AccountName)' on share " +
                            "'$($share.Name)': $($_.Exception.Message)"
                        )
                    }
                }
            }
        }
        else {
            Write-Verbose (
                "Share '$($share.Name)': no share permissions configured, " +
                'keep current'
            )
        }
        #endregion

        #region NTFS permissions: build the complete ACL and write it once
        $aclImport = $share.NTFS
        if ($aclImport) {
            Write-Verbose "Share '$($share.Name)': set NTFS permissions"
            try {
                $ntfsProblems = @()
                $ruleType = 'System.Security.AccessControl.FileSystemAccessRule'
                $rules = foreach ($ace in @($aclImport.Access)) {
                    try {
                        $accountName = Resolve-AccountNameHC -Name (
                            $ace.IdentityReference
                        )
                        $ruleArgs = @(
                            [System.Security.Principal.NTAccount]$accountName,
                            [System.Security.AccessControl.FileSystemRights](
                                $ace.FileSystemRights
                            ),
                            [System.Security.AccessControl.InheritanceFlags](
                                $ace.InheritanceFlags
                            ),
                            [System.Security.AccessControl.PropagationFlags](
                                $ace.PropagationFlags
                            ),
                            [System.Security.AccessControl.AccessControlType](
                                $ace.AccessControlType
                            )
                        )
                        New-Object -TypeName $ruleType -ArgumentList $ruleArgs
                    }
                    catch {
                        $ntfsProblems += (
                            'Failed to prepare NTFS permission ' +
                            "'$($ace.AccessControlType) " +
                            "$($ace.FileSystemRights)' for " +
                            "'$($ace.IdentityReference)' on share " +
                            "'$($share.Name)': $($_.Exception.Message)"
                        )
                    }
                }
                if ($ntfsProblems.Count) {
                    $errors.AddRange([string[]]@($ntfsProblems))
                    throw (
                        'the current NTFS permissions were kept, because ' +
                        'not all configured permissions could be prepared'
                    )
                }
                $acl = Get-Acl -LiteralPath $share.Path
                $explicitRules = @(
                    $acl.Access | Where-Object { -not $_.IsInherited }
                )
                foreach ($rule in $explicitRules) {
                    $null = $acl.RemoveAccessRule($rule)
                }
                $acl.SetAccessRuleProtection(
                    [bool]$aclImport.AreAccessRulesProtected, $false
                )
                foreach ($rule in @($rules)) { $acl.AddAccessRule($rule) }
                if ($aclImport.Owner) {
                    try {
                        $owner = Resolve-AccountNameHC -Name $aclImport.Owner
                        $acl.SetOwner(
                            [System.Security.Principal.NTAccount]$owner
                        )
                    }
                    catch {
                        $errors.Add(
                            "Failed to set owner '$($aclImport.Owner)' on " +
                            "share '$($share.Name)', the current owner was " +
                            "kept: $($_.Exception.Message)"
                        )
                    }
                }
                Write-Verbose "Write ACL on '$($share.Path)'"
                Set-Acl -LiteralPath $share.Path -AclObject $acl
                $messages.Add(
                    "Share '$($share.Name)': set $(@($rules).Count) " +
                    "NTFS permission(s) on '$($share.Path)'"
                )
            }
            catch {
                $errors.Add(
                    'Failed to set the NTFS permissions on ' +
                    "'$($share.Path)' for share '$($share.Name)': " +
                    "$($_.Exception.Message)"
                )
            }
        }
        else {
            Write-Verbose (
                "Share '$($share.Name)': no NTFS permissions configured, " +
                'keep current'
            )
        }
        #endregion
    }
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams
