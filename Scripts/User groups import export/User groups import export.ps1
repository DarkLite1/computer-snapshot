<#
    .SYNOPSIS
        Export or import local groups

    .DESCRIPTION
        This script should be run with action 'Export' on a computer that has 
        already the required local groups already created. Then on another 
        computer run this script with action 'Import' to recreate the exported 
        local groups.

        Only local group creation is supported. Azure AD groups or not supported
        for creation. 
        
        This script only adds or updates local groups and group members and 
        will never remove a group or remove a group member.
        
        TIP:
        It's encouraged to clean up the export file before running the script 
        with action 'Import'. Remove non relevant groups, update group details,
        , ...

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where the export or import file can be found

    .PARAMETER FileName
        Name of the file that contains all local groups

    .EXAMPLE
        $exportParams = @{
            Action     = 'Export'
            DataFolder = 'C:\Groups'
            FileName   = 'Groups.json'
        }
        & 'C:\Groups.ps1' @exportParams

        Export all groups on the current computer to the folder 
        'C:\Groups'

    .EXAMPLE
        $importParams = @{
            Action         = 'Import'
            DataFolder     = 'C:\Groups'
            FileName = 'Groups.json'
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
    [String]$FileName = 'Groups.json'
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
    
    Try {
        $GroupsFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            
            Write-Verbose "Export groups to file '$GroupsFile'"
            $groupsToExport | ConvertTo-Json -Depth 5 | 
            Out-File -FilePath $GroupsFile -Encoding UTF8

            Write-Output "Exported $($groups.count) groups"
        }
        else {
            Write-Verbose "Import groups from file '$GroupsFile'"
            $importedGroups = Get-Content -LiteralPath $GroupsFile -Raw | 
            ConvertFrom-Json -EA Stop

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
        }
    }
    Catch {
        throw "$Action groups failed: $_"
    }
}