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

        Can be a path relative to the Start-Script.ps1 directory like:
        'Snapshots\Snapshot1' or a full path like 'C:\Snapshots\Snapshot1'

    .PARAMETER RestoreSnapshotFolder
        By default the last created snapshot is used for restoring data. By
        using the argument '$RestoreSnapshotFolder' it is possible to restore
        data from a specific folder. This allows for the creation of named
        snapshot folders that can be restored on specific computers. 
        
        Simply copy/paste the data you want to restore to a specific folder
        and add the folder path to '$RestoreSnapshotFolder'.

        Ex: `$RestoreSnapshotFolder = 'Production\Image MyApp'`
        The folder 'Production' is in the same folder as 'Start-Script.ps1'.

    .PARAMETER SnapshotsFolder
        The parent folder where all the snapshots will be store by computer name
        and snapshot date. By default this data is stored on the USB stick.

        Can be a folder name or a folder path. In case it's a folder name the
        data will be stored in the script root.

    .PARAMETER ReportsFolder
        The folder where the reports will be saved. These reports contain the
        results of the scripts ran.

        Can be a folder name or a folder path. In case it's a folder name the
        data will be stored in the script root.

    .PARAMETER OpenReportInBrowser
        Once the script is done an HTML report will be opened in the browser for
        further inspection.

    .EXAMPLE
        # on PC1
        $params = @{
            Action = 'CreateSnapshot'
            Snapshot = [Ordered]@{
                UserAccounts  = $true
                UserGroups    = $true
                FirewallRules = $false
                SmbShares     = $true
            }
        }
        & 'Start-Script.ps1' @params

        # On PC2
        $params = @{
            Action = 'RestoreSnapshot'
            Snapshot = [Ordered]@{
                UserAccounts  = $true
                UserGroups    = $true
                FirewallRules = $false
                SmbShares     = $true
            }
        }
        & 'Start-Script.ps1' @params

        On PC1 an export is done of all user accounts and smb shares to the 
        snapshot folder 'Snapshots' on the USB stick.
        On PC2 this snapshot is restored and the user accounts and smb shares
        that were on PC1 are recreated/updated as needed.

    .EXAMPLE
        $params = @{
            Action                = 'RestoreSnapshot'
            RestoreSnapshotFolder = 'Snapshots\MyCustomSnapshot'
            Snapshot              = [Ordered]@{
                UserAccounts  = $true
                UserGroups    = $true
                FirewallRules = $false
                SmbShares     = $false
            }
        }
        & 'Start-Script.ps1' @params

        Restores the UserAccounts and UserGroups stored in the folder on the
        USB stick 'Snapshots\MyCustomSnapshot' on the current computer.
#>

[CmdLetBinding()]
Param (
    [ValidateSet('CreateSnapshot' , 'RestoreSnapshot')]
    [String]$Action = 'CreateSnapshot',
    [System.Collections.Specialized.OrderedDictionary]$Snapshot = [Ordered]@{
        UserAccounts   = $true
        UserGroups     = $true
        FirewallRules  = $true
        SmbShares      = $true
        CreateFolders  = $true
        NtpTimeServers = $true
        RegistryKeys   = $true
    },
    [String]$RestoreSnapshotFolder,
    [HashTable]$Script = @{
        UserAccounts   = 'Scripts\User accounts import export\User accounts import export.ps1'
        UserGroups     = 'Scripts\User groups import export\User groups import export.ps1'
        FirewallRules  = 'Scripts\Firewall rules import export\Firewall rules import export.ps1'
        SmbShares      = 'Scripts\Smb shares import export\Smb shares import export.ps1'
        CreateFolders  = 'Scripts\Folders import export\Folders import export.ps1'
        NtpTimeServers = 'Scripts\NTP time servers import export\NTP time servers import export.ps1'
        RegistryKeys   = 'Scripts\Registry keys import export\Registry keys import export.ps1'
    },
    [String]$SnapshotsFolder = 'Snapshots',
    [String]$ReportsFolder = 'Reports',
    [Boolean]$OpenReportInBrowser = $true
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
    Function Get-FullPathHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )

        if ($Path -like '*:*') {
            $Path
        }
        else {
            Join-Path -Path $PSScriptRoot -ChildPath $Path
        }
    }
    Function Test-IsAdminHC {
        <#
            .SYNOPSIS
                Check if a user is local administrator.
    
            .DESCRIPTION
                Check if a user is member of the local group 'Administrators' 
                and return true if he is and false if not.
    
            .EXAMPLE
                Test-IsAdminHC -SamAccountName bob
                Returns true in case bob is admin on this machine
    
            .EXAMPLE
                Test-IsAdminHC
                Returns true if the current user is admin on this machine
        #>
    
        Param (
            $SamAccountName = [Security.Principal.WindowsIdentity]::GetCurrent()
        )
    
        Try {
            $Identity = [Security.Principal.WindowsIdentity]$SamAccountName
            $Principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $Identity
            $Result = $Principal.IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
            Write-Verbose "Administrator permissions: $Result"
            $Result
        }
        Catch {
            throw "Failed to determine if the user is member of the local administrators group: $_"
        }
    }

    Try {
        $Error.Clear()
        $Now = Get-Date

        #region Test admin
        if (($Action -ne 'CreateSnapshot') -and (-not (Test-IsAdminHC))) {
            throw "User '$env:USERNAME' is not a member of the local administrators group. This is required to create or update the necessary details."
        }
        #endregion

        Write-Verbose "Start action '$Action'"

        $SnapshotsFolder = Get-FullPathHC -Path $SnapshotsFolder
        $ReportsFolder = Get-FullPathHC -Path $ReportsFolder

        #region Create reports folder
        if (-not (Test-Path -Path $ReportsFolder -PathType Container)) {
            try {
                $null = New-Item -Path $ReportsFolder -ItemType Directory -EA Stop
            }
            catch {
                throw "Failed to created reports folder '$ReportsFolder': $_"
            }
        }
        #endregion

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
                $RestoreSnapshotFolder = Get-FullPathHC -Path $RestoreSnapshotFolder

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
    
            If ($Script.Keys -NotContains $item.Key) {
                throw "No script found for snapshot item '$($item.Key)'"
            }

            $invokeScriptParams = @{
                Path       = Get-FullPathHC -Path $Script.$($item.Key)
                DataFolder = Join-Path -Path $SnapshotFolder -ChildPath $item.Key
            }
    
            #region Test execution script
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
                Foreach ($file in ($folderContent | 
                        Where-Object { $_.extension -eq '.json' })
                ) {
                    try {
                        $null = Get-Content -LiteralPath $file.FullName -Raw |
                        ConvertFrom-Json
                    }
                    catch {
                        throw "File '$($file.FullName)' is not a valid json file for snapshot item '$($item.Key)'"
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
    $childScriptResults = @()
    foreach ($item in $Snapshot.GetEnumerator() | Where-Object { $_.Value }) {
        Try {
            $Error.Clear()

            $childScriptResult = @{
                Name                = $item.Key
                Output              = $null
                TerminatingError    = $null
                NonTerminatingError = $null
            }

            $invokeScriptParams = @{
                Path       = Get-FullPathHC -Path $Script.$($item.Key)
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
            $childScriptResult.Output = Invoke-ScriptHC @invokeScriptParams
        }
        Catch {
            $childScriptResult.TerminatingError = $_
            $Error.RemoveAt(0)
        }
        Finally {
            if ($Error.Exception.Message) {
                $childScriptResult.NonTerminatingErrors = $Error.Exception.Message
            }
            $childScriptResults += $childScriptResult
        }
    }
}

End {
    Try {
        Write-Verbose "End action '$Action'"
        
        $joinParams = @{
            Path      = $ReportsFolder
            ChildPath = '{0} - {1} - {2}.html' -f 
            $env:COMPUTERNAME, $Now.ToString('yyyyMMddHHmmssffff'), $Action
        }
        $reportFile = Join-Path @joinParams
        $runtime = New-TimeSpan -Start $Now -End (Get-Date)
        $totalRunTime = "{0:00}:{1:00}:{2:00}" -f 
        $runTime.Hours, $runTime.Minutes, $runTime.Seconds
        
        $html = "
        <!DOCTYPE html>
        <html>
        <head>
        <style>
        table {
            
            border-collapse: collapse;
            width: 80%;
            margin-bottom: 25px;
        }

        h2 {
            text-align: center;
            color: White;
            background-color: MediumSeaGreen;
        }

        h4{
            font-style: italic;
            color: Gray;
        }

        td, th {
            border: 1px solid #dddddd;
            text-align: left;
            padding: 8px;
        }

        th {
            width: 1px;
            white-space: nowrap;
            color: Gray;
        }

        div {
            
            width: 80%;
            margin-bottom: 25px;
        }

        </style>
        </head>
        <body>
        "

        #region console summary for end user
        $writeParams = @{
            ForegroundColor = 'Yellow'
        }
        $writeSuccessParams = @{
            ForegroundColor = 'Green'
        }
        $writeBlockingErrorsParams = @{
            ForegroundColor = 'Red'
        }
        $writeSeparatorParams = @{
            ForegroundColor = 'Gray'
        }
        $writeScriptNameParams = @{
            ForegroundColor = 'Yellow'
        }

        Write-Host ('-' * 80) @writeSeparatorParams
        Write-Host "Action`t`t: $Action" @writeParams
        Write-Host "Total runtime`t: $totalRunTime" @writeParams
        Write-Host "Snapshot folder`t: $SnapshotFolder" @writeParams
        Write-Host ('-' * 80) @writeSeparatorParams

        $html += "
            <table>
                <tr>
                    <th>Action</th>
                    <td>$Action on $env:COMPUTERNAME</td>
                </tr>
                <tr>
                    <th>Total runtime</th>
                    <td>$totalRunTime</td>
                </tr>
                <tr>
                    <th>Snapshot folder</th>
                    <td><a href=`"$SnapshotFolder`">$SnapshotFolder</a></td>
                </tr>
            </table>
        "


        foreach ($script in $childScriptResults) {
            Write-Host '' + $Script.Name @writeScriptNameParams
            $html += '<div>'
            $html += '<h2>' + $Script.Name + '</h2>'
            
            $errorsFound = $false

            if (
                $output = $script.Output
            ) {
                # $html += '<h4>Output<h4>'
                # Write-Host 'Output:' 
                $html += '<ul>' 
                
                $output | ForEach-Object {
                    Write-Host "- $_"
                    # $html += '<p>' + $_ + '</p>'
                    $html += '<li>' + $_ + '</li>'
                }
                $html += '</ul>'
            }
            if (
                $TerminatingError = $script.TerminatingError
            ) {
                $errorsFound = $true
                Write-Host 'Blocking error:' @writeBlockingErrorsParams
                Write-Host $TerminatingError @writeBlockingErrorsParams

                $html += '<h4>Blocking error</h4>'
                $html += '<p style="color:red;">' + $TerminatingError + '</p>'
            }
            if (
                $nonTerminatingErrors = $script.NonTerminatingErrors
            ) {
                $errorsFound = $true

                $html += '<h4>Non blocking errors</h4>'
                
                Write-Warning 'Non blocking errors:'
                $nonTerminatingErrors | ForEach-Object { 
                    Write-Warning $_ 
                    $html += '<p style="color:orange;">' + $_ + '</p>'
                }
            }

            if (-not $errorsFound) {
                Write-Host 'Success, no errors detected' @writeSuccessParams
                $html += '<p style="color:green;"><b>Success, no errors detected</b></p>'
            }
            Write-Host ('-' * 80) @writeSeparatorParams

            $html += '</div>'
        }
        #endregion

        if (-not $childScriptResults) {
            $html += '<p>No snapshot items selected</p>'
        }

        $html += '</body>'
        $html | Out-File -FilePath $reportFile -Encoding utf8

        if ($OpenReportInBrowser) {
            try {
                # start IE with add-ons disabled
                $startParams = @{
                    FilePath     = 'iexplore.exe' 
                    ArgumentList = '-extoff', $reportFile
                    ErrorAction  = 'Stop'
                }
                Start-Process @startParams
            }
            catch {
                Start-Process $reportFile
            }
        }
    }
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}