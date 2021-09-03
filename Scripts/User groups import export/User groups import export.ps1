<#
    .SYNOPSIS
        Export or import groups

    .DESCRIPTION
        This script should be run with action 'Export' on a computer that has 
        all the required groups already created. Then on another computer this
        script can be run with action 'Import' to recreate the exported group
        groups.
        
        TIP:
        It's encouraged to clean up the export file before running the script 
        with action 'Import'. Remove non relevant groups, update group details,, ...

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the groups

    .PARAMETER GroupsFileName
        Name of the file that contains all local groups

    .EXAMPLE
        $exportParams = @{
            Action               = 'Export'
            DataFolder           = 'C:\Groups'
            GroupsFileName = 'Groups.json'
        }
        & 'C:\Groups.ps1' @exportParams

        Export all groups on the current computer to the folder 
        'C:\Groups'

    .EXAMPLE
        $importParams = @{
            Action               = 'Import'
            DataFolder           = 'C:\Groups'
            GroupsFileName       = 'Groups.json'
        }
        & 'C:\Groups.ps1' @importParams

        Restore all groups in the folder 'C:\Groups' on the 
        current computer
#>

[CmdLetBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$GroupsFileName = 'Groups.json'
)

Begin {
    Try {
        $GroupsFile = Join-Path -Path $DataFolder -ChildPath $GroupsFileName

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
            If (-not (Test-Path -LiteralPath $GroupsFile -PathType Leaf)) {
                throw "groups file '$GroupsFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action groups failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            $groups = Get-LocalGroup

            $groupsToExport = foreach ($group in $groups) {
                Write-Verbose "Group '$($group.Name)'"
                try {
                    $groupMembers = Get-LocalGroupMember -Name $group.Name -EA Stop |
                    Select-Object -Property Name, ObjectClass, 
                    @{
                        Name       = 'PrincipalSource'; 
                        Expression = { [String]$_.PrincipalSource } 
                    }
                }
                catch {
                    Write-Error "Failed to retrieve group members for group '$($group.Name)'. This group will most likely contain an invalid or orphaned account: $_"
                    $Error.RemoveAt(1)
                }

                [Ordered]@{
                    Name            = $group.Name
                    Description     = $group.Description
                    ObjectClass     = $group.ObjectClass
                    PrincipalSource = [String]$group.PrincipalSource
                    Members         = @($groupMembers)
                }
            }
            
            Write-Verbose "Export groups to file '$GroupsFile'"
            $groupsToExport | ConvertTo-Json -Depth 5 | 
            Out-File -FilePath $GroupsFile -Encoding UTF8

            Write-Output "Exported $($groups.count) groups"
            
        }
        else {
            Write-Verbose "Import groups from file '$GroupsFile'"
            $importedGroups = (
                Get-Content -LiteralPath $GroupsFile -Raw
            ) | ConvertFrom-Json -EA Stop

            $knownComputerGroups = Get-LocalGroup

            foreach ($group in $importedGroups) {
                try {                    
                    Write-Verbose "Group '$($group.Name)'"
                    
                    #region Create group
                    $groupParams = @{
                        Name        = $group.Name 
                        Description = $group.Description
                    }
                    
                    $existingGroup = $knownComputerGroups | Where-Object {
                        $_.Name -eq $group.Name
                    }
                    if (-not $existingGroup) {
                        if (-not $group.Description) {
                            New-LocalGroup -Name $group.Name
                        }
                        else {
                            New-LocalGroup @groupParams
                        }
                        Write-Output "Group '$($group.Name)' created"
                    }
                    elseif (
                        (
                            (-not $group.Description) -and 
                            (
                                (-not $existingGroup.Description) -or
                                ($existingGroup.Description -eq ' ')
                            )
                        ) -or (
                            $group.Description -eq $existingGroup.Description
                        )
                    ) {
                        Write-Output "Group '$($group.Name)' exists already and is correct"
                    } 
                    else {
                        if (-not $group.Description) {
                            # not supported
                            # Set-LocalGroup -Description ''
                            # Set-LocalGroup -Description $null
                            $groupParams.Description = ' '
                        }
                        Set-LocalGroup @groupParams
                        Write-Output "Updated description of group '$($group.Name)'"
                    }
                    #endregion

                    #region Set group members
              
                    foreach ($member in $group.Members) {
                        try {
                            $addMemberParams = @{
                                Group       = $group.Name
                                Member      = $member.Name
                                ErrorAction = 'Stop'
                            }
                            Add-LocalGroupMember @addMemberParams
                            Write-Output "Group '$($group.Name)' added account member '$($member.Name)'"
                        }
                        catch [Microsoft.PowerShell.Commands.MemberExistsException] {
                            Write-Output "Group '$($group.Name)' account '$($member.Name)' is already a member"
                            $Error.RemoveAt(0)
                        }
                        catch {
                            if (
                                $_.Exception.Message -eq 
                                'Object reference not set to an instance of an object.'
                            ) {
                                $Error.RemoveAt(0)
                                Write-Error "Failed to add member account '$($member.Name)' to group '$($group.Name)': member account not found"
                            }
                            else {
                                Write-Error "Failed to add member account '$($member.Name)' to group '$($group.Name)': $_"
                                $Error.RemoveAt(1)
                            }
                        }
                    }
                    #endregion
                }
                catch {
                    Write-Error "Failed to create group '$($group.Name)': $_"
                    $Error.RemoveAt(1)
                }
            }
        }
    }
    Catch {
        throw "$Action groups failed: $_"
    }
}