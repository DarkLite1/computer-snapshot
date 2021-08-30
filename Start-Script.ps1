<#
    .SYNOPSIS
        Create or restore a snapshot of the current computer.

    .DESCRIPTION
        This script is intended to be run from a USB stick and is portable.
        The intend is to create a snapshot on one computer and restore a
        snapshot on another computer.

        PROCEDURE:
        Step 1: Configure the current computer to the desired state.
        (ex. add smb shares, set up local users, grant them NTFS permissions,
        configure firewall rules, ..)

        Step 2: Plug in the USB stick and run this script on the current 
        computer, which is now configured correctly, to create a snapshot. 
        Simply set $Action to 'CreateSnapshot' and set the $Snapshot items to 
        $true for the data you want to collect in the $SnapshotsFolder.

        At this point a snapshot is created and saved on the USB stick in the
        $SnapshotsFolder.

        Step 3: To restore the snapshot on another computer plug in the USB 
        stick and run this script with $Action set to 'RestoreSnapshot' and set 
        the $Snapshot items to $true for the data you want to restore.

        At this point the snapshot will be used to create or update the current
        computer to the desired state.
        
        In case you want to restore another snapshot than the last one created
        use the '$RestoreSnapshotFolder'.

        TIPS:
        - It is encouraged to modify the exported files to contain only the
        data you really need. This will speed up the process and reduces the
        risks. Use something like Notepad++ or vscode to easily see the file
        structure and remove the unneeded pieces or update others.
        # less is more

        - After making a snapshot it is advised to rename the folder in the 
        snapshots folder to something more recognizable (ex. 'Image MyApp').
        Then move it to another folder on the USB drive so you can start the
        'RestoreBackup' process with the argument 'RestoreSnapshotFolder' set
        to the new folder (ex. 'X:\Backup restore\Production\Image MyApp').
        This way you are always certain the correct snapshot is restored.
        Otherwise, when not using 'RestoreSnapshotFolder', the last created
        snapshot is restored which might lead to unexpected results.
        # know what you're doing

    .PARAMETER Action
        A snapshot of the current computer is created when set to 
        'CreateSnapshot'. When set to 'RestoreSnapshot' the last created 
        snapshot will be restored on the current computer.

    .PARAMETER Snapshot
        Defines for which items to create a snapshot or which items to restore.
        Order is important if you want users to be created before other actions
        it must be the first item in the hash table.

    .PARAMETER RestoreSnapshotFolder
        By default the last created snapshot is used for restoring data. By
        using the argument '$RestoreSnapshotFolder' it is possible to restore
        data from a specific folder. This allows for the creation of named
        snapshot folders that can be restored on specific computers. 
        
        Simply copy/paste the data you want to restore to a specific folder
        and add the folder path to '$RestoreSnapshotFolder'.

    .PARAMETER SnapshotsFolder
        The parent folder where all the snapshots will be store by computer name
        and snapshot date. By default this data is stored on the USB stick.
#>

[CmdLetBinding()]
Param (
    [ValidateSet('CreateSnapshot' , 'RestoreSnapshot')]
    [String]$Action = 'CreateSnapshot',
    [System.Collections.Specialized.OrderedDictionary]$Snapshot = [Ordered]@{
        UserAccounts  = $true
        FirewallRules = $true
        SmbShares     = $true
    },
    [String]$RestoreSnapshotFolder,
    [HashTable]$Script = @{
        UserAccounts  = "$PSScriptRoot\Scripts\User accounts import export\User accounts import export.ps1"
        FirewallRules = "$PSScriptRoot\Scripts\Firewall rules import export\Firewall rules import export.ps1"
        SmbShares     = "$PSScriptRoot\Scripts\Smb shares import export\Smb shares import export.ps1"
    },
    [String]$SnapshotsFolder = "$PSScriptRoot\Snapshots"
)

Begin {
    Function Invoke-ScriptHC {
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [String]$DataFolder,
            [Parameter(Mandatory)]
            [ValidateSet('Export', 'Import')]
            [String]$Type
        )

        Write-Debug "Invoke script '$Path' on data folder '$DataFolder' for '$Type'"
        & $Path -DataFolder $DataFolder -Action $Type
    }

    Try {
        $VerbosePreference = 'Continue'
        $Error.Clear()
        $Now = Get-Date

        Write-Verbose "Start action '$Action'"

        If ($Action -eq 'CreateSnapshot') {
            #region Create snapshot folder
            try {
                $joinParams = @{
                    Path        = $SnapshotsFolder
                    ChildPath   = '{0} - {1}' -f 
                    $env:COMPUTERNAME, $Now.ToString('yyyyMMddHHmmssffff')
                    ErrorAction = 'Stop'
                }
                $SnapshotFolder = Join-Path @joinParams
                $null = New-Item -Path $SnapshotFolder -ItemType Directory
            }
            catch {
                Throw "Failed to create snapshots folder '$SnapshotsFolder': $_"
            }
            #endregion
        }
        else {
            If ($RestoreSnapshotFolder) {
                #region Test RestoreSnapshotFolder
                If (-not (Test-Path -Path $RestoreSnapshotFolder -PathType Container)) {
                    throw "Restore snapshot folder '$RestoreSnapshotFolder' not found"
                }
                #endregion

                $SnapshotFolder = $RestoreSnapshotFolder
            }
            else {
                #region Test snapshot folder
                If (-not (Test-Path -Path $SnapshotsFolder -PathType Container)) {
                    throw "Snapshot folder '$SnapshotsFolder' not found. Please create your first snapshot with action 'CreateSnapshot'"
                }
                #endregion

                #region Get latest snapshot folder
                $getParams = @{
                    Path        = $SnapshotsFolder
                    Directory   = $true
                    ErrorAction = 'Stop'
                }
                $SnapshotFolder = Get-ChildItem @getParams | Sort-Object LastWriteTime | 
                Select-Object -Last 1 -ExpandProperty FullName
                #endregion

                #region Test latest snapshot
                If (-not $SnapshotFolder) {
                    throw "No data found in snapshot folder '$($getParams.Path)' to restore. Please create a snapshot first with Action 'CreateSnapshot'"
                }
                #endregion
            }

            #region Test snapshot folder
            If ((Get-ChildItem -LiteralPath $SnapshotFolder | Measure-Object).Count -eq 0) {
                throw "No data found in snapshot folder '$SnapshotFolder'"
            }
            #endregion        
        }

        Write-Verbose "Snapshot folder '$SnapshotFolder'"

        #region Test scripts and data folders
        foreach ($item in $Snapshot.GetEnumerator() | 
            Where-Object { $_.Value }
        ) {
            Write-Verbose "Snapshot '$($item.Key)'"
    
            $invokeScriptParams = @{
                Path       = $Script.$($item.Key) 
                DataFolder = Join-Path -Path $SnapshotFolder -ChildPath $item.Key
            }
    
            #region Test execution script
            If (-not $invokeScriptParams.Path) {
                throw "No script found for snapshot item '$($item.Key)'"
            }
    
            If (-not (Test-Path -Path $invokeScriptParams.Path -PathType Leaf)) {
                throw "Script file '$($invokeScriptParams.Path)' not found for snapshot item '$($item.Key)'"
            }
            #endregion
    
            If ($Action -eq 'RestoreSnapshot') {
                #region Test script folder
                If (-not (Test-Path -LiteralPath $invokeScriptParams.DataFolder -PathType Container)) {
                    throw "Snapshot folder '$($invokeScriptParams.DataFolder)' not found"
                }
    
                $folderContent = @(Get-ChildItem -LiteralPath $invokeScriptParams.DataFolder)
                
                If ($folderContent.Count -eq 0) {
                    throw "No data found for snapshot item '$($item.Key)' in folder '$($invokeScriptParams.DataFolder)'"
                }
                #endregion
                
                #region Test valid import files
                Foreach ($file in ($folderContent | 
                        Where-Object { $_.extension -eq '.xml' })
                ) {
                    try {
                        $null = Import-Clixml -LiteralPath $file.FullName
                    }
                    catch {
                        throw "File '$($file.FullName)' is not a valid xml file for snapshot item '$($item.Key)'"
                    }
                }
                #endregion
            }
        }
        #endregion
    }    
    Catch {
        throw "Failed to perform action '$Action'. Nothing done, please fix this error first: $_"
    }
}

Process {
    $childScriptTerminatingErrors = @()

    foreach ($item in $Snapshot.GetEnumerator() | Where-Object { $_.Value }) {
        Try {
            $invokeScriptParams = @{
                Path       = $Script.$($item.Key) 
                DataFolder = Join-Path -Path $SnapshotFolder -ChildPath $item.Key
            }

            If ($Action -eq 'CreateSnapshot') {
                $null = New-Item -Path $invokeScriptParams.DataFolder -ItemType Directory

                $invokeScriptParams.Type = 'Export'
            }
            else {
                $invokeScriptParams.Type = 'Import'
            }

            Write-Verbose "Start snapshot '$($item.Key)'"
            Invoke-ScriptHC @invokeScriptParams
        }
        Catch {
            $childScriptTerminatingErrors += "Failed to execute script '$($invokeScriptParams.Path)' for snapshot item '$($item.Key)': $_"
            $Error.RemoveAt(0)
        }
    }
}

End {
    Try {
        Write-Verbose "End action '$Action'"
        
        #region console summary for end user
        $errorsFound = $false

        Write-Host "Snapshot folder '$SnapshotFolder' action '$Action'" -ForegroundColor Yellow

        if ($childScriptTerminatingErrors) {
            $errorsFound = $true
            Write-Host 'Blocking errors:' -ForegroundColor Red
            $childScriptTerminatingErrors | ForEach-Object {
                Write-Host $_ -ForegroundColor Red
            }
        }
        if ($Error.Exception.Message) {
            $errorsFound = $true
            Write-Warning 'Non blocking errors:'
            $Error.Exception.Message | ForEach-Object {
                Write-Warning $_
            }
        }

        if (-not $errorsFound) {
            Write-Host 'Success, no errors detected' -ForegroundColor Green
        }
        #endregion
    }
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}