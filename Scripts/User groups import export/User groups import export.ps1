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
            $groups | ForEach-Object {
                Write-Verbose "group group '$($_.Name)' description '$($_.Description)'"
            }

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
                    Write-Error "Failed to retrieve group members for group '$($group.Name)'. This group will most likely contain invalid accounts: $_"
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
                    Write-Verbose "group '$($group.Name)'"
                    $passwordParams = @{
                        groupName     = $group.Name 
                        groupPassword = $group.Password 
                        NewGroup      = $false
                    }

                    #region Create incomplete group
                    if ($knownComputerGroups.Name -notContains $group.Name) {
                        $passwordParams.NewGroup = $true
                        Set-NewPasswordHC @passwordParams
                    }
                    #endregion

                    #region Set group group details
                    $setGroupParams = @{
                        Name                   = $group.Name
                        Description            = $group.Description
                        FullName               = $group.FullName
                        PasswordNeverExpires   = ![Boolean]$group.PasswordExpires
                        groupMayChangePassword = $group.groupMayChangePassword
                        ErrorAction            = 'Stop'
                    }
                    
                    Set-LocalGroup @setgroupParams
                    #endregion

                    if (-not $passwordParams.NewGroup) {
                        if ($group.Password) {
                            Set-NewPasswordHC @passwordParams
                        }
                        else {
                            do { 
                                $answer = (
                                    Read-Host "Would you like to set a new password for group group '$($group.Name)'? [Y]es or [N]o"
                                ).ToLower()
                            } 
                            until ('y', 'n' -contains $answer)
                            if ($answer -eq 'y') {
                                Set-NewPasswordHC @passwordParams
                            }
                        }
                    }

                    if ($passwordParams.NewGroup) {
                        Write-Output "Created group '$($group.Name)'"
                    }
                    else {
                        Write-Output "updated group '$($group.Name)'"
                    }
                }
                catch {
                    Write-Error "Failed to create group group '$($group.Name)': $_"
                    $Error.RemoveAt(1)
                }
            }
        }
    }
    Catch {
        throw "$Action groups failed: $_"
    }
}