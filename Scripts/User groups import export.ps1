#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import User groups as a configuration section.
.DESCRIPTION
    Export reads each group's members. When Get-LocalGroupMember fails,
    typically because a member account no longer exists (an orphaned SID),
    the members are read through ADSI instead; orphaned members are skipped
    and reported, the other members are exported.

    Import creates missing groups, updates descriptions and adds members.
    Members are only added, never removed. Each failed group or member is
    reported in Errors and the remaining groups and members are still
    processed. A Description that is missing from the configuration is
    left unchanged; an empty Description clears it.
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
function Get-GroupMemberAdsiHC {
    <#
    .SYNOPSIS
        Read a local group's members through ADSI.
    .DESCRIPTION
        Unlike Get-LocalGroupMember, this also works when a member account
        no longer exists. Such a member has no Name, only its SID.
    #>
    param(
        [Parameter(Mandatory)][string]$GroupName
    )

    $group = [ADSI]"WinNT://./$GroupName,group"

    foreach ($member in @($group.psbase.Invoke('Members'))) {
        $sidBytes = $member.GetType().InvokeMember(
            'objectSid', 'GetProperty', $null, $member, $null
        )
        $sid = New-Object System.Security.Principal.SecurityIdentifier(
            $sidBytes, 0
        )

        $name = try {
            $sid.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            $null
        }

        [pscustomobject]@{
            Name = $name
            SID  = $sid.Value
        }
    }
}

function Set-LocalGroupDescriptionHC {
    # Set-LocalGroup cannot set an empty description
    # https://stackoverflow.com/questions/69041644/how-to-set-the-description-of-a-local-group-to-blank
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description
    )
    if ($Description) {
        Set-LocalGroup -Name $Name -Description $Description
    }
    else {
        $group = [ADSI]"WinNT://./$Name,group"
        $group.Put('Description', '')
        $group.SetInfo()
    }
}
function Test-ErrorKindHC {
    # Match by exception name and error id: the LocalAccounts exception types
    # only exist once that module is loaded, and PowerShell 7 may deserialize them
    param([Parameter(Mandatory)]$ErrorRecord, [Parameter(Mandatory)][string]$Kind)
    $ErrorRecord.Exception.GetType().Name -eq "${Kind}Exception" -or
    $ErrorRecord.FullyQualifiedErrorId -like "$Kind,*"
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
    $exportData = @(
        foreach ($group in @(Get-LocalGroup)) {
            Write-Verbose "Group '$($group.Name)'"
            try {
                $members = @(
                    Get-LocalGroupMember -Name $group.Name | ForEach-Object {
                        [pscustomobject]@{ Name = $_.Name; SID = [string]$_.SID }
                    }
                )
            }
            catch {
                # Usually an orphaned member: ADSI can still read the others
                $localGroupMemberError = $_.Exception.Message
                try {
                    $members = @(Get-GroupMemberAdsiHC -GroupName $group.Name)
                }
                catch {
                    $errors += "Failed to read the members of group '$($group.Name)': $localGroupMemberError; reading them through ADSI failed too: $($_.Exception.Message)"
                    continue
                }
            }

            foreach ($orphan in @($members | Where-Object { -not $_.Name })) {
                $messages += "Group '$($group.Name)': skipped member '$($orphan.SID)', an account that cannot be resolved (deleted, or its domain is unreachable)"
            }

            # Built-in members such as Everyone are exported by SID
            $memberNames = @(
                $members | Where-Object { $_.Name } | ForEach-Object {
                    ConvertTo-PortableAccountNameHC -Name $_.Name -Sid $_.SID
                }
            )
            $groupName = ConvertTo-PortableAccountNameHC -Name $group.Name -Sid ([string]$group.SID)
            if ($groupName -ne $group.Name) {
                # A built-in group: its name and description depend on the
                # Windows language, so it is stored by SID and its
                # description is left to Windows
                [ordered]@{
                    Name    = $groupName
                    Comment = "Built-in group '$($group.Name)', stored by SID so it works in every Windows language"
                    Members = $memberNames
                }
            }
            else {
                [ordered]@{
                    Name        = $group.Name
                    Description = $group.Description
                    Members     = $memberNames
                }
            }
        }
    )
    #endregion
    $messages = @('Exported User groups') + @($messages)
}
else {
    #region Apply section
    $knownGroups = @(Get-LocalGroup)
    foreach ($group in $Data) {
        Write-Verbose "Group '$($group.Name)'"
        $properties = @($group.PSObject.Properties | ForEach-Object { $_.Name })
        $hasDescription = $properties -contains 'Description'

        #region Create the group or update its description
        $groupName = $group.Name
        try {
            $isSid = $group.Name -match '^S-1-\d+(-\d+)+$'
            $existingGroup = $knownGroups | Where-Object {
                $_.Name -eq $group.Name -or ($isSid -and [string]$_.SID -eq $group.Name)
            } | Select-Object -First 1
            if ($existingGroup) { $groupName = $existingGroup.Name }
            if (-not $existingGroup -and $isSid) {
                throw "there is no group with SID '$($group.Name)' on '$env:COMPUTERNAME'"
            }
            if (-not $existingGroup) {
                $newGroupParams = @{ Name = $group.Name }
                if ($group.Description) { $newGroupParams.Description = $group.Description }
                $null = New-LocalGroup @newGroupParams
                $messages += "Created group '$($group.Name)'"
            }
            elseif ($hasDescription -and [string]$group.Description -ne [string]$existingGroup.Description) {
                Set-LocalGroupDescriptionHC -Name $groupName -Description $group.Description
                $messages += "Updated the description of group '$groupName'"
            }
            else {
                $messages += "Group '$groupName' already exists and is correct"
            }
        }
        catch {
            $errors += "Failed to create or update group '$groupName': $($_.Exception.Message)"
            # Without the group, adding members can only fail
            continue
        }
        #endregion

        #region Add members, one at a time
        foreach ($member in @($group.Members | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try {
                $accountName = Convert-AccountNameHC $member
                Add-LocalGroupMember -Group $groupName -Member $accountName
                if ($accountName -ne $member) {
                    $messages += "Added account '$member' as '$accountName' to group '$($groupName)'"
                }
                else {
                    $messages += "Added account '$member' to group '$($groupName)'"
                }
            }
            catch {
                if (Test-ErrorKindHC $_ 'MemberExists') {
                    $messages += "Account '$member' is already a member of group '$($groupName)'"
                }
                elseif (Test-ErrorKindHC $_ 'PrincipalNotFound') {
                    $errors += "Failed to add account '$member' to group '$($groupName)': account not found"
                }
                else {
                    $errors += "Failed to add account '$member' to group '$($groupName)': $($_.Exception.Message)"
                }
            }
        }
        #endregion
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }