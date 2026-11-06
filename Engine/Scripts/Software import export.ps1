#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Software as a configuration section.
.DESCRIPTION
    Import first removes the applications in Remove, by their display name in
    Programs and Features, then runs the installers in Install, relative to
    the USB root unless they are full paths. Each removal and installation is
    handled independently: a failure is reported in Errors and the remaining
    ones still run.

    - DisplayName may contain * to match any text; every matching application
      is removed. More than 5 matches are refused unless AllowMultiple is set.
    - Applications are found in the machine-wide uninstall keys and in those
      of every signed-in user. A per-user uninstaller runs as the account
      that runs the restore, which some uninstallers do not support.
    - Removal uses the application's quiet uninstall command when it has one.
      Windows Installer (MsiExec) commands are made silent and always
      uninstall (/X); other uninstallers without a quiet command may show a
      window. UninstallArguments are added to the application's own
      UninstallString, UninstallCommand replaces it.
    - Exit codes 0, 3010 and 1641 mean success; 3010 and 1641 mean that a
      restart is needed to complete the change. A removal or installer that
      uses other success codes lists them in SuccessExitCodes, for example
      [0, 1].
    - Each uninstaller and installer gets TimeoutMinutes (default 15) to
      finish; then it is stopped, with the processes it started, and
      reported as failed. Once it has finished, the processes it started
      get 60 seconds more, for setup steps in a child process. Processes
      still running then, such as the installed application or an updater,
      are left running and named in the report. With WaitForAllProcesses,
      every process it started must also finish within TimeoutMinutes.
      For an uninstall command, the uninstaller is the first process that
      cmd.exe starts. Processes are matched by ID and creation time, so a
      process that reused the ID of one in the tree is never stopped. A
      process that starts another and exits within 50 ms is not seen, so
      the process it started is not waited for, reported or stopped.
      After a successful uninstall the application may take
      up to 60 seconds to disappear, for uninstallers that finish in the
      background.
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
. "$PSScriptRoot\..\Common\Section.ps1"

#region Windows helpers
function Get-UninstallKeyPathHC {
    # Machine-wide uninstall keys, then those of every signed-in user
    $uninstallKey = 'Microsoft\Windows\CurrentVersion\Uninstall\*'

    foreach ($path in @(
            "HKLM:\Software\Wow6432Node\$uninstallKey"
            "HKLM:\Software\$uninstallKey"
        )) {
        [pscustomobject]@{ Path = $path; User = $null }
    }

    $getHiveParams = @{
        LiteralPath = 'Registry::HKEY_USERS'
        ErrorAction = 'SilentlyContinue'
    }
    $hives = @(
        Get-ChildItem @getHiveParams |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }
    )

    foreach ($hive in $hives) {
        $sid = $hive.PSChildName
        $user = try {
            ([Security.Principal.SecurityIdentifier]$sid).Translate(
                [Security.Principal.NTAccount]
            ).Value
        }
        catch {
            $sid
        }

        [pscustomobject]@{
            Path = "Registry::HKEY_USERS\$sid\Software\$uninstallKey"
            User = $user
        }
    }
}

function Get-InstalledApplicationsHC {
    # Unreadable uninstall entries are skipped instead of failing the lookup
    $applications = foreach ($key in @(Get-UninstallKeyPathHC)) {
        Get-ItemProperty -Path $key.Path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object -Property @(
                'DisplayName'
                'DisplayVersion'
                'Publisher'
                'UninstallString'
                'QuietUninstallString'
                @{ Name = 'User'; Expression = { $key.User } }
            )
    }
    # The same name can be installed twice, for example 32 and 64 bit
    @($applications) | Sort-Object DisplayName, User, UninstallString -Unique
}

function Test-SameApplicationHC {
    # Name, user and command: the 32-bit install of the same name differs
    param($Application, [object[]]$Target)
    @(
        $Target | Where-Object {
            $_.DisplayName -eq $Application.DisplayName -and
            $_.User -eq $Application.User -and
            $_.UninstallString -eq $Application.UninstallString
        }
    ).Count -gt 0
}

function Wait-ApplicationRemovedHC {
    # Some uninstallers finish in a process they start without waiting for it
    param(
        [Parameter(Mandatory)][object[]]$Target,
        [int]$TimeoutSeconds = 60
    )
    Write-Verbose (
        "Wait up to $TimeoutSeconds seconds until the application is removed"
    )
    $attempts = [Math]::Max(1, [Math]::Ceiling($TimeoutSeconds / 2))
    for ($attempt = 0; $attempt -le $attempts; $attempt++) {
        $remaining = @(
            Get-InstalledApplicationsHC |
            Where-Object {
                Test-SameApplicationHC -Application $_ -Target $Target
            }
        )
        if (-not $remaining.Count) { return $true }
        if ($attempt -lt $attempts) { Start-Sleep -Seconds 2 }
    }
    Write-Verbose 'The application is still installed'
    $false
}

function Get-GraceSecondsHC {
    # Seconds to wait for the processes an installer started, after the
    # installer itself has exited; a function so tests can shorten it
    60
}

function Test-SameCreationTimeHC {
    # Windows reports the creation time of a process to the microsecond
    param([datetime]$First, [datetime]$Second)
    [Math]::Abs(($First - $Second).Ticks) -lt 10
}

function Stop-TreeProcessHC {
    <#
    .SYNOPSIS
        Stop a process only when it is still the process seen in the tree.
    .DESCRIPTION
        Windows reuses process IDs, so the ID alone could point to an
        unrelated process by now. The process is stopped only when its
        creation time still matches. The open handle keeps the ID from
        being reused between that check and the stop.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][datetime]$CreationDate
    )
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        # It has exited already
        return
    }

    try {
        $null = $process.Handle
        if (Test-SameCreationTimeHC $process.StartTime $CreationDate) {
            Write-Verbose "Stop process ID $ProcessId"
            $process.Kill()
        }
    }
    catch {
        # Exited meanwhile or not accessible: leave it alone
    }
    finally {
        $process.Dispose()
    }
}

function Wait-ProcessTreeHC {
    <#
    .SYNOPSIS
        Wait for an installer or uninstaller and return its exit code and
        the names of the processes it started that were left running.
    .DESCRIPTION
        The process itself gets TimeoutSeconds; with FirstChildIsMain, as
        for an uninstaller started through cmd.exe, its first child too.
        When it does not exit in time, it and every process it started are
        stopped and it throws.

        After it exited, the processes it started get GraceSeconds to
        finish, so setup steps in a child process can complete. Processes
        still running then, such as the installed application, a tray tool
        or an updater, are left alone and returned in LeftRunning.

        With WaitForAllProcesses, every process started gets TimeoutSeconds
        as well, and they are all stopped when one is still running then.

        A process belongs to the tree by its ID and creation time, because
        Windows reuses process IDs. The processes are checked every 50 ms
        during the first 3 seconds, then every 500 ms. A process that starts
        a child and exits between two checks is never seen, so that child
        cannot be linked to the tree: it is not waited for, not reported
        and never stopped.
    #>
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$What,
        [switch]$FirstChildIsMain,
        [switch]$WaitForAllProcesses,
        [int]$GraceSeconds = (Get-GraceSecondsHC)
    )
    Write-Verbose (
        "Wait for $What, process ID $($Process.Id), " +
        "timeout $TimeoutSeconds seconds"
    )
    # Reading the handle keeps the exit code available after the exit
    $null = $Process.Handle
    $since = $Process.StartTime.AddSeconds(-1)
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $graceDeadline = $null
    $mainIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $null = $mainIds.Add($Process.Id)
    $firstChildFound = -not $FirstChildIsMain
    # The ID and creation time of every process seen in the tree. Kept
    # between checks, so the children of a process that has exited are
    # still found through it.
    $tree = New-Object 'System.Collections.Generic.Dictionary[int,datetime]'
    $tree[$Process.Id] = $Process.StartTime

    $cimParams = @{
        ClassName = 'Win32_Process'
        Property  = 'ProcessId', 'ParentProcessId', 'CreationDate', 'Name'
    }

    while ($true) {
        $all = @(
            Get-CimInstance @cimParams |
            Where-Object { $_.CreationDate -ge $since }
        )
        $live = @{}
        foreach ($item in $all) {
            $live[[int]$item.ProcessId] = $item.CreationDate
        }

        do {
            $added = $false
            foreach ($candidate in $all) {
                $id = [int]$candidate.ProcessId
                $parentId = [int]$candidate.ParentProcessId
                $created = $candidate.CreationDate

                if (
                    $tree.ContainsKey($id) -and
                    (Test-SameCreationTimeHC $tree[$id] $created)
                ) {
                    continue
                }

                # A child starts after its parent
                if (
                    $id -eq $parentId -or
                    -not $tree.ContainsKey($parentId) -or
                    $created -lt $tree[$parentId]
                ) {
                    continue
                }

                # The parent exited and its ID now belongs to another
                # process; only processes started before that are its own
                $parentStart = $tree[$parentId]
                $liveStart = $live[$parentId]
                if (
                    $live.ContainsKey($parentId) -and
                    -not (Test-SameCreationTimeHC $parentStart $liveStart) -and
                    $created -ge $liveStart
                ) {
                    continue
                }

                $tree[$id] = $created
                $added = $true
            }
        } while ($added)

        # A console window host ends with its console; it is not started by
        # the installer itself
        $running = @(
            $all | Where-Object {
                $itemId = [int]$_.ProcessId
                $tree.ContainsKey($itemId) -and
                (Test-SameCreationTimeHC $tree[$itemId] $_.CreationDate) -and
                $_.Name -ne 'conhost.exe'
            }
        )

        if (-not $firstChildFound) {
            $firstChild = @(
                $running |
                Where-Object { [int]$_.ParentProcessId -eq $Process.Id } |
                Sort-Object CreationDate
            ) | Select-Object -First 1
            if ($firstChild) {
                $null = $mainIds.Add([int]$firstChild.ProcessId)
                $firstChildFound = $true
            }
        }

        $mainRunning = @(
            $running | Where-Object { $mainIds.Contains([int]$_.ProcessId) }
        )
        $mainExited = $Process.HasExited -and -not $mainRunning.Count

        if ($mainExited -and -not $running.Count) {
            break
        }

        if ($mainExited -and -not $WaitForAllProcesses) {
            if (-not $graceDeadline) {
                Write-Verbose (
                    "$What exited, wait up to $GraceSeconds seconds for " +
                    "$($running.Count) process(es) it started"
                )
                $graceDeadline = (Get-Date).AddSeconds($GraceSeconds)
            }
            if ((Get-Date) -ge $graceDeadline) {
                $Process.WaitForExit()
                return [pscustomobject]@{
                    ExitCode    = [int]$Process.ExitCode
                    LeftRunning = [string[]]@(
                        $running | ForEach-Object { $_.Name } |
                        Select-Object -Unique
                    )
                }
            }
        }
        elseif ((Get-Date) -ge $deadline) {
            Write-Verbose (
                "$What timed out, stop $($running.Count) process(es)"
            )
            foreach ($item in $running) {
                $stopParams = @{
                    ProcessId    = $item.ProcessId
                    CreationDate = $item.CreationDate
                }
                Stop-TreeProcessHC @stopParams
            }
            throw (
                "$What did not finish within " +
                "$([Math]::Round($TimeoutSeconds / 60, 2)) " +
                'minute(s) and was stopped'
            )
        }

        # Check often at first, to see short-lived processes that start others
        if (((Get-Date) - $started).TotalSeconds -lt 3) {
            Start-Sleep -Milliseconds 50
        }
        else {
            Start-Sleep -Milliseconds 500
        }
    }

    $Process.WaitForExit()
    [pscustomobject]@{
        ExitCode    = [int]$Process.ExitCode
        LeftRunning = [string[]]@()
    }
}

function Get-LeftRunningTextHC {
    # '; 'a.exe' started by the installer is still running and was left alone'
    param(
        [string[]]$Names,
        [Parameter(Mandatory)][string]$StartedBy
    )
    if (-not $Names.Count) {
        return ''
    }
    $list = "'" + ($Names -join "', '") + "'"
    if ($Names.Count -eq 1) {
        return (
            "; $list started by the $StartedBy is still running " +
            'and was left alone'
        )
    }
    (
        "; $list started by the $StartedBy are still running " +
        'and were left alone'
    )
}

function Get-TimeoutSecondsHC {
    param($Entry)
    $minutes = if ($null -ne $Entry.TimeoutMinutes) {
        [int]$Entry.TimeoutMinutes
    }
    else {
        15
    }
    $minutes * 60
}

function Test-DisplayNameHC {
    # Only * is a wildcard; [ ] and ? in names are literal
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Pattern
    )
    $escaped = [WildcardPattern]::Escape($Pattern).Replace('`*', '*')
    $Name -like $escaped
}

function Get-UninstallCommandHC {
    param(
        [Parameter(Mandatory)]$Application,
        [string]$Arguments
    )
    if ($Arguments) {
        $command = [string]$Application.UninstallString
        if (-not $command) { return $null }
        return "$command $Arguments"
    }
    if ($Application.QuietUninstallString) {
        return $Application.QuietUninstallString
    }
    $command = [string]$Application.UninstallString
    if ($command -match '(?i)^\s*"?([^"]*\\)?msiexec(\.exe)?"?\s') {
        # MsiExec /I installs or repairs; /X uninstalls
        $command = $command -replace '(?i)\s/I\s*(\{)', ' /X$1'
        if ($command -notmatch '(?i)\s/q') { $command += ' /qn' }
        if ($command -notmatch '(?i)/norestart') { $command += ' /norestart' }
    }
    $command
}

function Remove-ApplicationHC {
    # Returns the exit code of the uninstall command and the processes it
    # started that were left running
    param(
        [Parameter(Mandatory)][String]$ApplicationName,
        [Parameter(Mandatory)][String]$UninstallString,
        [int]$TimeoutSeconds = 900,
        [switch]$WaitForAllProcesses
    )
    Write-Verbose (
        "Remove application '$ApplicationName' with '$UninstallString'"
    )
    # /S: cmd only removes the outer quotes, the command keeps its own
    $startParams = @{
        FilePath     = "$env:SystemRoot\System32\cmd.exe"
        ArgumentList = "/D /S /C `"$UninstallString`""
        NoNewWindow  = $true
        PassThru     = $true
    }
    $process = Start-Process @startParams
    # The uninstaller is the first process cmd.exe starts
    $waitParams = @{
        Process             = $process
        TimeoutSeconds      = $TimeoutSeconds
        What                = 'the uninstall'
        FirstChildIsMain    = $true
        WaitForAllProcesses = $WaitForAllProcesses
    }
    Wait-ProcessTreeHC @waitParams
}

function Get-ExitCodeResultHC {
    <#
    .SYNOPSIS
        Interpret an exit code: $null for success, 'restart' for success
        that needs a restart; any other code throws.
    .DESCRIPTION
        3010 and 1641 are the Windows Installer codes for success with a
        restart, and always count as such. SuccessExitCodes lists the
        codes that mean success, by default only 0.
    #>
    param(
        [int]$ExitCode,
        [string]$What,
        [int[]]$SuccessExitCodes = @(0)
    )

    if ($ExitCode -in @(3010, 1641)) {
        return 'restart'
    }

    if ($SuccessExitCodes -contains $ExitCode) {
        return $null
    }

    throw (
        "$What failed with exit code $ExitCode, " +
        "success exit codes are $($SuccessExitCodes -join ', ')"
    )
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Software: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    # Installers and their arguments can not be read from Windows
    Write-Verbose 'Export Software: an empty section to fill in'
    $exportData = [ordered]@{}
    #endregion

    $messages.Insert(0, (
            'Nothing to export: add the software to install or remove, see ' +
            'Shared\Examples\Software.json'
        ))
}
else {
    #region Apply section
    Write-Verbose "Import Software from root folder '$RootFolder'"
    $workPath = Get-Location
    # Installer arguments may contain paths relative to the USB root
    Set-Location -LiteralPath $RootFolder
    try {
        #region Remove applications
        $removals = @($Data.Remove | Where-Object { $null -ne $_ })
        Write-Verbose "Remove $($removals.Count) application(s)"

        foreach ($removal in $removals) {
            $pattern = [string]$removal.DisplayName
            $successExitCodes = @(
                $removal.SuccessExitCodes |
                Where-Object { $null -ne $_ } |
                ForEach-Object { [int]$_ }
            )

            if (-not $successExitCodes.Count) {
                $successExitCodes = @(0)
            }

            try {
                $installed = @(
                    Get-InstalledApplicationsHC |
                    Where-Object {
                        $nameParams = @{
                            Name    = $_.DisplayName
                            Pattern = $pattern
                        }
                        Test-DisplayNameHC @nameParams
                    }
                )

                if (-not $installed.Count) {
                    Write-Verbose "Application '$pattern': not installed, skip"
                    $messages.Add(
                        "Application '$pattern' is not installed, " +
                        'nothing to remove'
                    )
                    continue
                }

                Write-Verbose (
                    "Application '$pattern': $($installed.Count) match(es)"
                )

                if ($installed.Count -gt 5 -and -not $removal.AllowMultiple) {
                    throw (
                        "'$pattern' matches $($installed.Count) " +
                        'applications; ' +
                        'nothing was removed. Use a narrower DisplayName, ' +
                        'or set AllowMultiple to remove them all'
                    )
                }
            }
            catch {
                $errors.Add(
                    "Failed to remove application '$pattern': " +
                    "$($_.Exception.Message)"
                )
                continue
            }

            # UninstallCommand runs once for all matches
            $targets = New-Object 'System.Collections.Generic.List[object]'

            if ($removal.UninstallCommand) {
                $targets.Add($installed)
            }
            else {
                foreach ($application in $installed) {
                    $targets.Add(@($application))
                }
            }

            foreach ($target in $targets) {
                $applicationName = (
                    @($target.DisplayName) | Select-Object -Unique
                ) -join "', '"
                $users = @(
                    $target.User | Where-Object { $_ } | Select-Object -Unique
                )

                if ($users.Count) {
                    $applicationName += "' for user '$($users -join "', '")"
                }

                try {
                    $command = if ($removal.UninstallCommand) {
                        [string]$removal.UninstallCommand
                    }
                    else {
                        $commandParams = @{
                            Application = $target[0]
                            Arguments   = $removal.UninstallArguments
                        }
                        Get-UninstallCommandHC @commandParams
                    }

                    if (-not $command) {
                        throw 'no uninstall command found in the registry'
                    }

                    $removeParams = @{
                        ApplicationName     = $applicationName
                        UninstallString     = $command
                        TimeoutSeconds      = (Get-TimeoutSecondsHC $removal)
                        WaitForAllProcesses = (
                            $removal.WaitForAllProcesses -eq $true
                        )
                    }
                    $uninstall = Remove-ApplicationHC @removeParams
                    $exitCode = $uninstall.ExitCode
                    $leftRunningParams = @{
                        Names     = $uninstall.LeftRunning
                        StartedBy = 'uninstaller'
                    }
                    $leftRunning = Get-LeftRunningTextHC @leftRunningParams

                    $resultParams = @{
                        ExitCode         = $exitCode
                        What             = 'the uninstall'
                        SuccessExitCodes = $successExitCodes
                    }
                    $result = Get-ExitCodeResultHC @resultParams

                    if (
                        $result -ne 'restart' -and
                        -not (Wait-ApplicationRemovedHC -Target $target)
                    ) {
                        throw (
                            'the application is still installed 60 seconds ' +
                            "after the uninstall (exit code $exitCode)"
                        )
                    }

                    if ($result -eq 'restart') {
                        $messages.Add(
                            "Removed application '$applicationName', " +
                            'a restart is needed to complete the removal' +
                            $leftRunning
                        )
                    }
                    else {
                        $messages.Add(
                            "Removed application '$applicationName'" +
                            $leftRunning
                        )
                    }
                }
                catch {
                    Write-Verbose "Application '$applicationName': failed"
                    $errors.Add(
                        "Failed to remove application '$applicationName': " +
                        "$($_.Exception.Message)"
                    )
                }
            }
        }
        #endregion

        #region Install applications
        $installs = @($Data.Install | Where-Object { $null -ne $_ })
        Write-Verbose "Install $($installs.Count) application(s)"

        foreach ($application in $installs) {
            $label = "'$($application.ExecutablePath)'"
            if ($application.Arguments) {
                $label += " with arguments '$($application.Arguments)'"
            }
            try {
                if (-not $application.ExecutablePath) {
                    throw "the property 'ExecutablePath' is required"
                }
                $resolveParams = @{
                    Path       = $application.ExecutablePath
                    RootFolder = $RootFolder
                }
                $executablePath = Resolve-RootPathHC @resolveParams
                $isFile = Test-Path -LiteralPath $executablePath -PathType Leaf
                if (-not $isFile) {
                    throw "the file '$executablePath' does not exist"
                }
                Write-Verbose "Install executable '$executablePath'"
                $startParams = @{
                    FilePath    = $executablePath
                    NoNewWindow = $true
                    PassThru    = $true
                }
                if ($application.Arguments) {
                    $startParams.ArgumentList = $application.Arguments
                }
                $process = Start-Process @startParams
                $waitParams = @{
                    Process             = $process
                    What                = 'the installation'
                    TimeoutSeconds      = (Get-TimeoutSecondsHC $application)
                    WaitForAllProcesses = (
                        $application.WaitForAllProcesses -eq $true
                    )
                }
                $installation = Wait-ProcessTreeHC @waitParams
                $exitCode = $installation.ExitCode
                $leftRunningParams = @{
                    Names     = $installation.LeftRunning
                    StartedBy = 'installer'
                }
                $leftRunning = Get-LeftRunningTextHC @leftRunningParams
                $successExitCodes = @(
                    $application.SuccessExitCodes |
                    Where-Object { $null -ne $_ } |
                    ForEach-Object { [int]$_ }
                )

                if (-not $successExitCodes.Count) {
                    $successExitCodes = @(0)
                }

                $resultParams = @{
                    ExitCode         = $exitCode
                    What             = 'the installation'
                    SuccessExitCodes = $successExitCodes
                }
                $result = Get-ExitCodeResultHC @resultParams

                if ($result -eq 'restart') {
                    $messages.Add(
                        "Installed $label, a restart is needed to complete " +
                        "the installation$leftRunning"
                    )
                }
                elseif ($exitCode) {
                    $messages.Add(
                        "Installed $label (exit code $exitCode)$leftRunning"
                    )
                }
                else {
                    $messages.Add("Installed $label$leftRunning")
                }
            }
            catch {
                Write-Verbose "Install ${label}: failed"
                $errors.Add(
                    "Failed to install ${label}: $($_.Exception.Message)"
                )
            }
        }
        #endregion
    }
    finally { Set-Location -LiteralPath $workPath.Path }
    #endregion
}

Write-Verbose (
    "Software: $(@($messages).Count) message(s), " +
    "$(@($errors).Count) error(s)"
)
$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams