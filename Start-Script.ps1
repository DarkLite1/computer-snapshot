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

        Step 2: Plug in the USB stick and run the script to create a backup in the SnapshotFolder with:
        - $Action = 'CreateSnapshot'
        - $SnapshotFolder = 'backup\PC1'

        Step 3: To restore the snapshot on another computer plug in the USB 
        stick and run this script with:
        - $Action = 'RestoreSnapshot'
        - $SnapshotFolder = 'backup\PC1'

        TIPS:
        - It is encouraged to modify the exported files to contain only the
        data you really need. This will speed up the process and reduces the
        risks. Use something like Notepad++ or vscode to easily see the file
        structure and remove the unneeded pieces or update others.
        # less is more

    .PARAMETER Action
        A snapshot of the current computer is created when set to 
        'CreateSnapshot'. When set to 'RestoreSnapshot' the last created 
        snapshot will be restored on the current computer.

    .PARAMETER Snapshot
        Defines for which items to create a snapshot or which items to restore.
        Order is important if you want users to be created before other actions
        it must be the first item in the hash table.

        Can be a path relative to the Start-Script.ps1 directory like:
        'Snapshots\Snapshot1' or a full path like 'C:\Snapshots\Snapshot1'.

    .PARAMETER SnapshotFolder
        When 'Action = CreateSnapshot' this is the folder where the backup
        will be saved. The folder will be created if it doesn't exist. When
        it already exists and there is no content, that's ok too. When there
        is content in the folder an error will be thrown.
        
        When 'Action = RestoreSnapshot', this is the folder that
        contains the data and configuration files that will be used in the 
        restore process.

    .PARAMETER ReportsFolder
        The folder where the reports will be saved. These reports contain the
        results of the scripts ran.

        Can be a folder name or a folder path. In case it's a folder name the
        data will be stored in the script root.

    .PARAMETER OpenReportInBrowser
        Once the script is done an HTML report will be opened in the browser for
        further inspection.

    .PARAMETER RebootComputerAfterRestoreSnapshot
        Reboot the current machine once the action 'RestoreSnapshot' is finished

    .EXAMPLE
        # on PC1
        $params = @{
            Action         = 'CreateSnapshot'
            SnapshotFolder = 'Snapshots\PC1'
            Snapshot       = [Ordered]@{
                UserAccounts  = $true
                UserGroups    = $true
                FirewallRules = $false
                SmbShares     = $true
            }
        }
        & 'Start-Script.ps1' @params

        # On PC2
        $params = @{
            Action         = 'RestoreSnapshot'
            SnapshotFolder = 'Snapshots\PC1'
            Snapshot       = [Ordered]@{
                UserAccounts  = $true
                UserGroups    = $true
                FirewallRules = $false
                SmbShares     = $true
            }
        }
        & 'Start-Script.ps1' @params

        On PC1 an export is done of all user accounts and smb shares to the 
        snapshot folder 'Snapshots\PC1' on the USB stick.
        On PC2 this snapshot is restored and the user accounts and smb shares
        that were on PC1 are recreated/updated as needed.

    .EXAMPLE
        $params = @{
            Action                = 'RestoreSnapshot'
            SnapshotFolder        = 'Snapshots\MyCustomSnapshot'
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
    [String]$SnapshotFolder,
    [Boolean]$RebootComputerAfterRestoreSnapshot = $true,
    [System.Collections.Specialized.OrderedDictionary]$Snapshot = [Ordered]@{
        StartCustomScriptsBefore = $true
        RegionalSettings         = $true
        UserAccounts             = $true
        UserGroups               = $true
        FirewallRules            = $true
        CreateFolders            = $true
        SmbShares                = $true
        NetworkCards             = $true
        NtpTimeServers           = $true
        RegistryKeys             = $true
        ScheduledTasks           = $true
        CopyFilesFolders         = $true
        Software                 = $true
        StartCustomScriptsAfter  = $true
    },
    [HashTable]$Script = @{
        UserAccounts             = '.\Scripts\User accounts import export\User accounts import export.ps1'
        UserGroups               = '.\Scripts\User groups import export\User groups import export.ps1'
        FirewallRules            = '.\Scripts\Firewall rules import export\Firewall rules import export.ps1'
        CreateFolders            = '.\Scripts\Folders import export\Folders import export.ps1'
        SmbShares                = '.\Scripts\Smb shares import export\Smb shares import export.ps1'
        RegionalSettings         = '.\Scripts\Regional settings import export\Regional settings import export.ps1'
        NetworkCards             = '.\Scripts\Network cards import export\Network cards import export.ps1'
        NtpTimeServers           = '.\Scripts\NTP time servers import export\NTP time servers import export.ps1'
        RegistryKeys             = '.\Scripts\Registry keys import export\Registry keys import export.ps1'
        ScheduledTasks           = '.\Scripts\Scheduled tasks import export\Scheduled tasks import export.ps1'
        CopyFilesFolders         = '.\Scripts\Copy files folders import export\Copy files folders import export.ps1'
        Software                 = '.\Scripts\Software import export\Software import export.ps1'
        StartCustomScriptsBefore = '.\Scripts\Start custom scripts import export\Start custom scripts import export.ps1'
        StartCustomScriptsAfter  = '.\Scripts\Start custom scripts import export\Start custom scripts import export.ps1'
    },
    [String]$ReportsFolder = '.\Reports',
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
    Function Test-IsStartedElevatedHC {
        <#
        .SYNOPSIS
            Check if the script is started in elevated mode
        
        .DESCRIPTION
            Some PowerShell scripts required to be run as adminstrator 
            and in elavated mode to functino propertly.
        #>
        
        Try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
            $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        Catch {
            throw "Failed to determine if the script is started in elevated mode: $_"
        }
    }

    Try {
        # $VerbosePreference = 'Continue'
        $Error.Clear()

        Set-Location $PSScriptRoot
        $Now = Get-Date

        #region Start progress bar
        $progressBarCount = @{
            TotalSteps          = ($Snapshot.GetEnumerator() | Where-Object { $_.Value } | Measure-Object).Count + 1
            CurrentStep         = 0
            CompletedPercentage = 0
        }        
        
        $progressBarCount.CompletedPercentage = 
        [int]($progressBarCount.CurrentStep * 
        (100 / $progressBarCount.TotalSteps))
    
        $progressParams = @{
            Activity         = "Action '$Action'"
            CurrentOperation = 'Preflight check'
            Status           = "Complete: $($progressBarCount.CompletedPercentage) %"
            PercentComplete  = $progressBarCount.CompletedPercentage
        }
        Write-Progress @progressParams
        #endregion

        #region Test admin
        if (-not (Test-IsStartedElevatedHC)) {
            Write-Warning "Script not launched in elevated mode. Some changes might be prohibited. Use 'RunAs Administrator' if required."
        }
        #endregion

        Write-Verbose "Start action '$Action'"

        #region Get path ReportsFolder
        $params = @{
            Path        = $ReportsFolder
            ErrorAction = 'Ignore'
        }
        $ReportsFolderPath = Convert-Path @params
        #endregion

        #region Create ReportsFolder
        If (-not $ReportsFolderPath) {
            try {
                $params = @{
                    Path        = $ReportsFolder 
                    ItemType    = 'Directory'
                    ErrorAction = 'Stop'
                }
                $ReportsFolderPath = (New-Item @params).FullName
            }
            catch {
                throw "Failed to created reports folder '$ReportsFolder': $_"
            }
        }
        #endregion

        #region SnapshotFolder

        #region Test SnapshotFolder mandatory
        if (-not $SnapshotFolder) {
            throw "The argument 'SnapshotFolder' is mandatory"
        }
        #endregion

        #region Get SnapshotFolder path
        $params = @{
            Path        = $SnapshotFolder
            ErrorAction = 'Ignore'
        }
        $SnapshotFolderPath = Convert-Path @params
        #endregion

        If ($Action -eq 'CreateSnapshot') {
            If (-not $SnapshotFolderPath) {
                #region Create snapshot folder
                try {
                    $params = @{
                        Path        = $SnapshotFolder
                        ItemType    = 'Directory'
                        ErrorAction = 'Stop'
                    }
                    $SnapshotFolderPath = (New-Item @params).FullName
                }
                catch {
                    Throw "Failed to create snapshot folder '$SnapshotFolder': $_"
                }       
                #endregion
            }
            elseif (Test-Path -Path "$SnapshotFolderPath\*") {
                Throw "The snapshot folder '$SnapshotFolder' needs to be empty before a proper snapshot can be created"
            }
        }
        else {
            #region Test SnapshotFolder exists
            If (-not $SnapshotFolderPath) {
                throw "Snapshot folder '$SnapshotFolder' not found"
            }
            #endregion

            #region Test SnapshotFolder is empty
            If (-not (Test-Path -Path "$SnapshotFolderPath\*")) {
                throw "No data found in snapshot folder '$SnapshotFolder'"
            }
            #endregion
        }
    
        Write-Verbose "Snapshot folder '$SnapshotFolderPath'"
        #endregion

        #region Test scripts and data folders
        foreach ($item in $Snapshot.GetEnumerator() | 
            Where-Object { $_.Value }
        ) {
            Write-Verbose "Snapshot '$($item.Key)'"
    
            If ($Script.Keys -NotContains $item.Key) {
                throw "No script found for snapshot item '$($item.Key)'"
            }

            $invokeScriptParams = @{
                Path       = $Script.$($item.Key)
                DataFolder = Join-Path -Path $SnapshotFolderPath -ChildPath $item.Key
            }
    
            #region Test execution script
            If (-not (Test-Path -Path $invokeScriptParams.Path -PathType Leaf)) {
                throw "Script file '$($invokeScriptParams.Path)' not found for snapshot item '$($item.Key)'"
            }
            #endregion
    
            If ($Action -eq 'RestoreSnapshot') {
                #region Test script folder
                If (-not (
                        Test-Path -LiteralPath $invokeScriptParams.DataFolder -PathType 'Container')
                ) {
                    throw "Restore folder '$($invokeScriptParams.DataFolder)' for snapshot item '$($item.Key)' not found"
                }
    
                $folderContent = @(Get-ChildItem -LiteralPath $invokeScriptParams.DataFolder)
                
                If ($folderContent.Count -eq 0) {
                    throw "Restore folder '$($invokeScriptParams.DataFolder)' for snapshot item '$($item.Key)' is empty"
                }
                #endregion
                
                #region Test valid import files
                <# 
                # Test not required as we use .json files everywhere
                # only scheduled task creation is done with .xml files
                # but these cannot be imported with Import-CliXml
                # and will fail this test
                
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
                #>
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
        #region Continue progress bar
        $progressBarCount.CurrentStep++

        $progressBarCount.CompletedPercentage = 
        [int]($progressBarCount.CurrentStep * 
            (100 / $progressBarCount.TotalSteps))
    
        $progressParams = @{
            Activity         = "Action '$Action'"
            CurrentOperation = "Executing script '$($item.Key)'"
            Status           = "Complete: $($progressBarCount.CompletedPercentage) %"
            PercentComplete  = $progressBarCount.CompletedPercentage
        }
        Write-Progress @progressParams
        #endregion

        Try {
            $Error.Clear()

            $childScriptResult = @{
                Name                = $item.Key
                Output              = $null
                TerminatingError    = $null
                NonTerminatingError = $null
            }

            Set-Location $PSScriptRoot

            $invokeScriptParams = @{
                Path       = $Script.$($item.Key)
                DataFolder = Join-Path -Path $SnapshotFolderPath -ChildPath $item.Key
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
        #region Finish progress bar
        $progressParams.CurrentOperation = 'All scripts executed'
        $progressParams.Status = 'Complete: 100 %'
        $progressParams.PercentComplete = 100
        Write-Progress @progressParams
        #endregion

        Write-Verbose "End action '$Action'"
        
        $joinParams = @{
            Path      = $ReportsFolderPath
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
        h4 {
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
        .rebootHeader {
			font-size: xx-large;
			margin-top: 25px;
			background-color: Red;
			color: White;
			text-align: center;
			margin-bottom: 0px;
		}
		.rebootParagraph {
			font-size: large;
			background-color: Red;
			color: White;
			text-align: center;
		}
        </style>
        </head>
        <body>
        "

        if (
            ($Action -eq 'RestoreSnapshot') -and 
            ($RebootComputerAfterRestoreSnapshot)
        ) {
            $html += "
            <div class=`"rebootHeader`">
                REBOOT IMMINENT
            </div>
            <div class=`"rebootParagraph`">
                >> After closing this window the computer will restart <<
            </div>
            "
        }

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
        Write-Host "Snapshot folder`t: $SnapshotFolderPath" @writeParams
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
                    <td><a href=`"$SnapshotFolderPath`">$SnapshotFolderPath</a></td>
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
                    Wait         = $true
                }
                Start-Process @startParams
            }
            catch {
                Start-Process $reportFile
            }
        }

        if (
            ($Action -eq 'RestoreSnapshot') -and 
            ($RebootComputerAfterRestoreSnapshot)
        ) {
            Write-Host 'Restart computer' @writeParams
            Restart-Computer
        }
    }
    Catch {
        throw "Failed to perform action '$Action': $_"
    }
}