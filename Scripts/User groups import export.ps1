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
    # https://stackoverflow.com/questions/69041644
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
    # Match by exception name and error id: the LocalAccounts exception
    # types only exist once that module is loaded, and PowerShell 7 may
    # deserialize them
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [Parameter(Mandatory)][string]$Kind
    )
    $ErrorRecord.Exception.GetType().Name -eq "${Kind}Exception" -or
    $ErrorRecord.FullyQualifiedErrorId -like "$Kind,*"
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import User groups: section is empty, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export User groups'
    $exportData = @(
        foreach ($group in @(Get-LocalGroup)) {
            Write-Verbose "Group '$($group.Name)'"
            try {
                $members = @(
                    Get-LocalGroupMember -Name $group.Name | ForEach-Object {
                        [pscustomobject]@{
                            Name = $_.Name
                            SID  = [string]$_.SID
                        }
                    }
                )
            }
            catch {
                # Usually an orphaned member: ADSI can still read the others
                $localGroupMemberError = $_.Exception.Message
                Write-Verbose (
                    "Group '$($group.Name)': read the members through ADSI"
                )
                try {
                    $members = @(Get-GroupMemberAdsiHC -GroupName $group.Name)
                }
                catch {
                    $errors.Add(
                        'Failed to read the members of group ' +
                        "'$($group.Name)': $localGroupMemberError; " +
                        'reading them through ADSI failed too: ' +
                        "$($_.Exception.Message)"
                    )
                    continue
                }
            }

            foreach ($orphan in @($members | Where-Object { -not $_.Name })) {
                $messages.Add(
                    "Group '$($group.Name)': skipped member " +
                    "'$($orphan.SID)', an account that cannot be resolved " +
                    '(deleted, or its domain is unreachable)'
                )
            }

            # Built-in members such as Everyone get their English name
            $memberNames = @(
                $members | Where-Object { $_.Name } | ForEach-Object {
                    ConvertTo-PortableAccountNameHC -Name $_.Name -Sid $_.SID
                }
            )
            $portableParams = @{
                Name = $group.Name
                Sid  = [string]$group.SID
            }
            $groupName = ConvertTo-PortableAccountNameHC @portableParams
            if ($groupName -ne $group.Name) {
                # A built-in group: its name and description depend on the
                # Windows language, so it is stored by its English name,
                # without BUILTIN\, and its description is left to Windows
                Write-Verbose "Group '$($group.Name)': built-in"
                [ordered]@{
                    Name    = $groupName.Split('\')[-1]
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

    $messages.Insert(0, 'Exported User groups')
}
else {
    #region Apply section
    Write-Verbose 'Import User groups'
    $knownGroups = @(Get-LocalGroup)
    foreach ($group in $Data) {
        Write-Verbose "Group '$($group.Name)'"
        $properties = @(
            $group.PSObject.Properties | ForEach-Object { $_.Name }
        )
        $hasDescription = $properties -contains 'Description'

        #region Create the group or update its description
        $groupName = $group.Name
        try {
            # A built-in group, by SID or English name, is found by its SID,
            # so 'Administrators' also finds 'Administratoren'
            $wellKnownSid = Get-WellKnownAccountSidHC -Name $group.Name
            $existingGroup = $null
            if ($wellKnownSid) {
                $existingGroup = $knownGroups | Where-Object {
                    [string]$_.SID -eq $wellKnownSid
                } | Select-Object -First 1
            }
            if (-not $existingGroup) {
                $existingGroup = $knownGroups | Where-Object {
                    $_.Name -eq $group.Name
                } | Select-Object -First 1
            }
            if ($existingGroup) { $groupName = $existingGroup.Name }
            if (
                -not $existingGroup -and (
                    $group.Name -match '^S-1-\d+(-\d+)+$' -or
                    $wellKnownSid -like 'S-1-5-32-*'
                )
            ) {
                throw (
                    "there is no built-in group '$($group.Name)' " +
                    "($wellKnownSid) on '$env:COMPUTERNAME'"
                )
            }
            if (-not $existingGroup) {
                Write-Verbose "Group '$($group.Name)': create"
                $newGroupParams = @{ Name = $group.Name }
                if ($group.Description) {
                    $newGroupParams.Description = $group.Description
                }
                $newGroup = New-LocalGroup @newGroupParams
                # A later entry for the same group must update it, not
                # create it again
                $knownGroups += if ($newGroup) { $newGroup }
                else {
                    [pscustomobject]@{
                        Name        = $group.Name
                        Description = [string]$group.Description
                        SID         = ''
                    }
                }
                $messages.Add("Created group '$($group.Name)'")
            }
            elseif (
                $hasDescription -and
                [string]$group.Description -ne
                [string]$existingGroup.Description
            ) {
                Write-Verbose "Group '$groupName': update description"
                $descriptionParams = @{
                    Name        = $groupName
                    Description = $group.Description
                }
                Set-LocalGroupDescriptionHC @descriptionParams
                $messages.Add("Updated the description of group '$groupName'")
            }
            else {
                $messages.Add(
                    "Group '$groupName' already exists and is correct"
                )
            }
        }
        catch {
            $errors.Add(
                "Failed to create or update group '$groupName': " +
                "$($_.Exception.Message)"
            )
            # Without the group, adding members can only fail
            continue
        }
        #endregion

        #region Add members, one at a time
        $members = @(
            $group.Members |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        Write-Verbose "Group '$groupName': add $($members.Count) member(s)"
        foreach ($member in $members) {
            try {
                $accountName = Convert-AccountNameHC $member
                Add-LocalGroupMember -Group $groupName -Member $accountName
                if ($accountName -ne $member) {
                    $messages.Add(
                        "Added account '$member' as '$accountName' to " +
                        "group '$($groupName)'"
                    )
                }
                else {
                    $messages.Add(
                        "Added account '$member' to group '$($groupName)'"
                    )
                }
            }
            catch {
                if (Test-ErrorKindHC $_ 'MemberExists') {
                    $messages.Add(
                        "Account '$member' is already a member of group " +
                        "'$($groupName)'"
                    )
                }
                elseif (Test-ErrorKindHC $_ 'PrincipalNotFound') {
                    $errors.Add(
                        "Failed to add account '$member' to group " +
                        "'$($groupName)': account not found"
                    )
                }
                else {
                    $errors.Add(
                        "Failed to add account '$member' to group " +
                        "'$($groupName)': $($_.Exception.Message)"
                    )
                }
            }
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
