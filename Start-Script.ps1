<#
    .SYNOPSIS
        Create or restore a snapshot of the current machine.

    .DESCRIPTION
        This script is intended to be run from a USB stick and is portable.

        Step 1: Configure the current machine correctly in Windows.

        Step 2: Plug in the USB stick and run this script on the correctly 
        configured machine to create a snapshot. Simply set $Action to 
        'CreateSnapshot' and set the $Snapshot items to '$true' for the 
        data you want to collect.

        At this point a snapshot is created and saved on the USB stick in the
        folder 'Snapshots'.

        Step 3: On another machine, where you want to restore the snapshot: 
        Plug in the USB stick and run this script with $Action set to 
        'RestoreSnapshot' and set the $Snapshot items to '$true' for the 
        data you want to restore.
        
        In case you want to restore another snapshot than the last one created
        use the '$RestoreSnapshotFolder'.

    .PARAMETER Action
        A snapshot of the current machine is created when set to 
        'CreateSnapshot'. When set to 'RestoreSnapshot' the last created 
        snapshot will be restored on the current machine.

    .PARAMETER Snapshot
        Defines for which items to create a snapshot or which items to restore.

    .PARAMETER RestoreSnapshotFolder
        By default the last created snapshot is used for restoring data. By
        using the argument '$RestoreSnapshotFolder' it is possible to restore
        data from a specific folder. This allows for the creation of named
        snapshot folders that can be restored on specific machines. 
        
        Simply copy/paste the data you want to restore to a specific folder
        and add the folder path to '$RestoreSnapshotFolder'.
#>

Param (
    [ValidateSet('CreateSnapshot' , 'RestoreSnapshot')]
    [String]$Action = 'CreateSnapshot',
    [HashTable]$Snapshot = @{
        FirewallRules = $false
        SmbShares     = $true
    },
    [String]$RestoreSnapshotFolder,
    [HashTable]$Script = @{
        FirewallRules = "$PSScriptRoot\Scripts\ImportExportFirewallRules.ps1"
        SmbShares     = "$PSScriptRoot\Scripts\ImportExportSmbShares.ps1"
    }
)

Begin {
    Try {
        $VerbosePreference = 'Continue'

        $Now = Get-Date

        Write-Verbose "Start action '$Action'"

        $snapshotFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Snapshots'

        If ($Action -eq 'CreateSnapshot') {
            #region Create snapshot folder
            $joinParams = @{
                Path      = $snapshotFolder
                ChildPath = '{0} - {1}' -f 
                $env:COMPUTERNAME, $Now.ToString('yyyyMMddHHmmssffff')
            }
            $snapshotFolder = Join-Path @joinParams
            $null = New-Item -Path $snapshotFolder -ItemType Directory
            #endregion
        }
        else {
            If ($RestoreSnapshotFolder) {
                #region Test RestoreSnapshotFolder
                If (-not (Test-Path -Path $RestoreSnapshotFolder -PathType Container)) {
                    throw "Restore snapshot folder '$RestoreSnapshotFolder' not found"
                }
                #endregion

                $snapshotFolder = $RestoreSnapshotFolder
            }
            else {
                #region Test snapshot folder
                If (-not (Test-Path -Path $snapshotFolder -PathType Container)) {
                    throw "No snapshots made yet. Please create your first snapshot with action 'CreateSnapshot'"
                }
                #endregion

                #region Get latest snapshot folder
                $getParams = @{
                    Path        = $snapshotFolder
                    Directory   = $true
                    ErrorAction = 'Stop'
                }
                $snapshotFolder = Get-ChildItem @getParams | Sort-Object LastWriteTime | 
                Select-Object -Last 1 -ExpandProperty FullName
                #endregion

                #region Test latest snapshot
                If (-not $snapshotFolder) {
                    throw "No snapshot found to restore. Please create a snapshot first with Action 'CreateSnapshot'"
                }
                #endregion
            }

            #region Test snapshot folder
            If ((Get-ChildItem -LiteralPath $snapshotFolder | Measure-Object).Count -eq 0) {
                throw "No data found in snapshot folder '$snapshotFolder'"
            }
            #endregion        
        }

        Write-Verbose "Snapshot folder '$scriptFolder'"
    }    
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}

Process {
    Try {
        foreach ($item in $Snapshot.GetEnumerator() | Where-Object { $_.Value }) {
            Write-Verbose "Snapshot '$($item.Key)'"

            $executionScript = $Script.$($item.Key)

            #region Test execution script
            If (-not $executionScript) {
                throw "No script found for '$($item.Key)'"
            }

            If (-not (Test-Path -Path $executionScript -PathType Leaf)) {
                throw "Script '$executionScript' not found for '$($item.Key)'"
            }
            #endregion

            $scriptFolder = Join-Path -Path $snapshotFolder -ChildPath $item.Key

            If ($Action -eq 'CreateSnapshot') {
                $null = New-Item -Path $scriptFolder -ItemType Directory

                & $executionScript -DataFolder $scriptFolder -Action 'Export'
            }
            else {
                #region Test script folder
                If (-not (Test-Path -Path $scriptFolder -PathType Container)) {
                    throw "Snapshot folder '$scriptFolder' not found"
                }

                If ((Get-ChildItem -Path $scriptFolder | Measure-Object).Count -eq 0) {
                    throw "No data found for snapshot item '$($item.Key)' in folder '$scriptFolder'"
                }
                #endregion

                #& $executionScript -DataFolder $scriptFolder -Action 'Import'
            }
        }
    }
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}

End {
    Try {
        If ($Action -eq 'CreateSnapshot') {
            Write-Verbose "Snapshot created in folder '$snapshotFolder'"
        }
        else {
            Write-Verbose "Snapshot restored from folder '$snapshotFolder'"
        }
        
        Write-Verbose "End action '$Action'"
    }
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}