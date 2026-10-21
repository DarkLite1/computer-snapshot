#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import User groups as a configuration section.
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
. "$PSScriptRoot\Common\Section.ps1"
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
Function Set-LocalGroupHC {
        # not supported by standard CmdLet
        # Set-LocalGroup -Description ''
        # Set-LocalGroup -Description $null
        # https://stackoverflow.com/questions/69041644/how-to-set-the-description-of-a-local-group-to-blank
        
        Param(
            [Parameter(Mandatory)]
            [string]$Name,
            [string]$Description
        )
        
        if ($Description) { 
            Set-LocalGroup @PSBoundParameters 
        }
        elseif ($Name) {
            $Group = [ADSI]"WinNT://./$Name,group"
            $Group.Put('Description', '')
            $Group.SetInfo()
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
$groups = Get-LocalGroup
$groupsToExport = foreach ($group in $groups) {
                Write-Verbose "Group '$($group.Name)'"
                try {
                    $groupMembers = Get-LocalGroupMember -Name $group.Name -EA Stop
                    Write-Verbose "Group '$($group.Name)' has $($groupMembers.Count) members"
                }
                catch {
                    Write-Error "Failed to retrieve group members for group '$($group.Name)'. This group will most likely contain an invalid or orphaned account: $_"
                    $Error.RemoveAt(1)
                }

                [Ordered]@{
                    Name        = $group.Name
                    Description = $group.Description
                    Members     = @($groupMembers.Name)
                }
            }
$exportData = @($groupsToExport)
    #endregion
    $messages = @('Exported User groups')
}
else {
    #region Apply section
    $messages = @(& {

$importedGroups = $Data
$knownComputerGroups = Get-LocalGroup
foreach ($group in $importedGroups) {
                try {                    
                    Write-Verbose "Group '$($group.Name)'"
                    
                    #region Create group
                    $groupParams = @{
                        Name        = $group.Name 
                        Description = $group.Description
                    }
                    if (-not $group.Description) {
                        $groupParams.Remove('Description')
                    }
                    
                    $existingGroup = $knownComputerGroups | Where-Object {
                        $_.Name -eq $group.Name
                    }
                    if (-not $existingGroup) {
                        New-LocalGroup @groupParams
                        Write-Output "Group '$($group.Name)' created"
                    }
                    elseif (
                        ($group.Description -eq $existingGroup.Description) -or
                        (
                            (-not $group.Description) -and 
                            (-not $existingGroup.Description)
                        )
                    ) {
                        Write-Output "Group '$($group.Name)' exists already and is correct"
                    } 
                    else {
                        Set-LocalGroupHC @groupParams
                        Write-Output "Updated description of group '$($group.Name)'"
                    }
                    #endregion

                    #region Add group members
                    foreach ($member in $group.Members) {
                        try {
                            $addMemberParams = @{
                                Group       = $group.Name
                                Member      = Convert-AccountNameHC $member
                                ErrorAction = 'Stop'
                            }
                            Add-LocalGroupMember @addMemberParams
                            Write-Output "Group '$($group.Name)' added account member '$member'"
                        }
                        catch [Microsoft.PowerShell.Commands.MemberExistsException] {
                            Write-Output "Group '$($group.Name)' account '$member' is already a member"
                            $Error.RemoveAt(0)
                        }
                        catch [Microsoft.PowerShell.Commands.PrincipalNotFoundException] {
                            Write-Error "Failed to add account '$member' to group '$($group.Name)': account not found"
                            $Error.RemoveAt(1)
                        }
                        catch {
                            Write-Error "Failed to add member account '$member' to group '$($group.Name)': $_"
                            $Error.RemoveAt(1)
                        }
                    }
                    #endregion
                }
                catch {
                    Write-Error "Failed to create group '$($group.Name)': $_"
                    $Error.RemoveAt(1)
                }
            }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
