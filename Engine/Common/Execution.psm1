#Requires -Version 5.1
<#
.SYNOPSIS
    Execute validated in-memory snapshot sections and report the results.
#>

Import-Module "$PSScriptRoot\Configuration.psm1" -Force
. "$PSScriptRoot\Section.ps1"
. "$PSScriptRoot\RestoreInput.ps1"

function Invoke-ChildScriptHC {
    <#
    .SYNOPSIS
        Run one child script and pass on everything it writes.
    .DESCRIPTION
        All streams are captured so that every error the child writes reaches
        the caller, whatever the caller's ErrorAction is. Inside the child,
        errors stay nonterminating so one failed entry does not stop the
        remaining entries. Errors are rewritten as new error records with
        secrets redacted, so the caller receives each reported error exactly
        once. Errors the child handles itself (try/catch without Write-Error)
        are not reported.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Action,
        $Data,
        [string]$RootFolder,
        [string[]]$SecretValues
    )

    $callerPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $childParams = @{
        Action     = $Action
        Data       = $Data
        RootFolder = $RootFolder
    }

    & $Path @childParams *>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $protectParams = @{
                Text         = [string]$_
                SecretValues = $SecretValues
            }
            $message = Protect-RestoreInputTextHC @protectParams

            Write-Error -Message $message -ErrorAction $callerPreference
            return
        }

        if (
            $_ -is [System.Management.Automation.WarningRecord] -or
            $_ -is [System.Management.Automation.VerboseRecord] -or
            $_ -is [System.Management.Automation.DebugRecord] -or
            $_ -is [System.Management.Automation.InformationRecord]
        ) {
            $protectParams = @{
                Text         = [string]$_
                SecretValues = $SecretValues
            }
            $message = Protect-RestoreInputTextHC @protectParams

            if ($_ -is [System.Management.Automation.WarningRecord]) {
                Write-Warning $message
            }
            elseif ($_ -is [System.Management.Automation.VerboseRecord]) {
                Write-Verbose $message
            }
            elseif ($_ -is [System.Management.Automation.DebugRecord]) {
                Write-Debug $message
            }
            else {
                Write-Information $message -InformationAction Continue
            }
            return
        }

        $_
    }
}

function Join-RestoreAnswersHC {
    <#
    .SYNOPSIS
        The answers of the answer file, with the answers that the wizard
        serves on a named pipe on top.
    .DESCRIPTION
        When the answers of the wizard cannot be received, for example
        because the wizard was closed, a warning says so and the restore
        asks for the missing answers in the input form instead.
    #>
    param(
        [System.Collections.IDictionary]$Answers,
        [Parameter(Mandatory)][string]$PipeName
    )

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,object]'
    $joined = New-Object $dictionaryType ([StringComparer]::Ordinal)

    if ($null -ne $Answers) {
        foreach ($key in $Answers.Keys) {
            $joined[$key] = $Answers[$key]
        }
    }

    try {
        $received = Receive-RestoreAnswersHC -PipeName $PipeName

        foreach ($key in $received.Keys) {
            $joined[$key] = $received[$key]
        }

        Write-Verbose "Received $($received.Count) answer(s) from the wizard"
    }
    catch {
        Write-Warning (
            'The answers of the wizard could not be received ' +
            "($($_.Exception.Message)); the restore asks for them instead."
        )
    }

    return , $joined
}

function Write-SnapshotReportHC {
    <#
    .SYNOPSIS
        Write the HTML report, one row per section, and return its path.
    #>
    param(
        [string]$ReportsFolder,
        [string]$Action,
        [string]$ConfigurationFile,
        $Results
    )

    $folderParams = @{
        Path        = $ReportsFolder
        ItemType    = 'Directory'
        Force       = $true
        ErrorAction = 'Stop'
    }
    $null = New-Item @folderParams

    $operation = if ($Action -eq 'CreateSnapshot') {
        'Export'
    }
    else {
        'Restore'
    }

    $configurationName = [IO.Path]::GetFileNameWithoutExtension(
        $ConfigurationFile
    )
    $reportName = '{0}-{1}-{2}-{3}' -f (
        $env:COMPUTERNAME,
        (Get-Date -Format 'yyyyMMdd-HHmmss'),
        $operation,
        $configurationName
    )

    $path = Join-Path $ReportsFolder ($reportName + '.html')
    $suffix = 2

    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $ReportsFolder (
            '{0}-{1}.html' -f $reportName, $suffix
        )
        $suffix++
    }

    $rows = foreach ($result in $Results) {
        $item = [System.Net.WebUtility]::HtmlEncode($result.Name)
        $status = [System.Net.WebUtility]::HtmlEncode($result.Status)
        $messages = @(
            $result.Messages | ForEach-Object {
                '<li>' +
                [System.Net.WebUtility]::HtmlEncode([string]$_) +
                '</li>'
            }
        ) -join ''

        "<tr><th>$item</th><td>$status</td><td><ul>$messages</ul></td></tr>"
    }

    $title = [System.Net.WebUtility]::HtmlEncode("$Action - $ConfigurationFile")
    $style = (
        'body{font-family:Segoe UI,sans-serif;margin:2rem}' +
        'table{border-collapse:collapse;width:100%}' +
        'td,th{padding:0.6rem;border:1px solid #bbb;text-align:left;' +
        'vertical-align:top}' +
        'ul{margin:0}'
    )
    $html = (
        '<!doctype html><html><head><meta charset="utf-8"><title>' +
        $title + '</title><style>' + $style + '</style></head><body><h1>' +
        $title + '</h1><table><thead><tr><th>Item</th><th>Status</th>' +
        '<th>Messages</th></tr></thead><tbody>' + ($rows -join '') +
        '</tbody></table></body></html>'
    )

    $encoding = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($path, $html, $encoding)

    return $path
}

function Start-ComputerRestartHC {
    <#
    .SYNOPSIS
        Schedule a restart with a countdown that can still be cancelled.
    .DESCRIPTION
        Windows shows the countdown to signed-in users; 'shutdown /a' cancels
        it. Unlike Restart-Computer this also works with other users signed
        in, and it returns immediately, so the report can still be read.
    #>
    param(
        [Parameter(Mandatory)][int]$DelaySeconds
    )

    # Windows PowerShell 5.1 turns output on the error stream of a program
    # into a stopping error when the preference is Stop; the exit code decides
    $ErrorActionPreference = 'Continue'

    $comment = (
        'Computer snapshot restore completed. ' +
        'The computer restarts to apply the changes.'
    )

    $output = & shutdown.exe /r /t $DelaySeconds /d p:4:1 /c $comment 2>&1

    if ($LASTEXITCODE) {
        throw (
            "shutdown.exe failed with exit code $($LASTEXITCODE): " +
            ($output -join ' ')
        )
    }
}

function Invoke-ComputerSnapshotHC {
    <#
    .SYNOPSIS
        Export or restore the selected sections of one configuration.
    .DESCRIPTION
        Validates first, runs each section's child script in the fixed
        order, writes the configuration on export, restarts after a
        successful restore when asked, writes the report and returns the
        result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CreateSnapshot', 'RestoreSnapshot')]
        [string]$Action,
        [Parameter(Mandatory)][string]$ConfigurationFile,
        [string[]]$Items,
        [Parameter(Mandatory)][string]$RootFolder,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Script,
        [string]$ReportsFolder,
        [bool]$RebootComputer = $false,
        [bool]$OpenReportInBrowser = $true,
        [ValidateRange(0, 600)]
        [int]$RestartDelaySeconds = 60,
        # Per section, options that a child script receives as Data on export
        [System.Collections.IDictionary]$ExportOptions,
        [string]$AnswerFile,
        # The named pipe on which the wizard serves the answers of its
        # questions page
        [string]$AnswerPipe,
        # Restore only: the Software.Install entries not to run, by their
        # position from 0, as unchecked in the wizard
        [int[]]$SkipSoftwareInstall,
        [switch]$Unattended,
        [switch]$Force
    )

    $restoreOnly = (
        $PSBoundParameters.ContainsKey('AnswerFile') -or
        $PSBoundParameters.ContainsKey('AnswerPipe') -or
        $PSBoundParameters.ContainsKey('SkipSoftwareInstall') -or
        $Unattended
    )

    if ($Action -ne 'RestoreSnapshot' -and $restoreOnly) {
        throw (
            'AnswerFile, AnswerPipe, SkipSoftwareInstall and Unattended are ' +
            'restore-only options.'
        )
    }

    $configurationPath = Resolve-RootPathHC $ConfigurationFile $RootFolder

    if (
        $Action -eq 'CreateSnapshot' -and
        (Test-Path -LiteralPath $configurationPath) -and
        -not $Force
    ) {
        throw (
            "Configuration '$configurationPath' already exists. " +
            'Use -Force to replace it.'
        )
    }

    if (-not $ReportsFolder) {
        $ReportsFolder = Join-Path $RootFolder 'Log'
    }

    $ReportsFolder = Resolve-RootPathHC $ReportsFolder $RootFolder
    $results = New-Object 'System.Collections.Generic.List[object]'
    $problems = @()
    $configuration = $null
    $secretValues = @()
    # Software.Install entries unchecked in the wizard, for the report
    $skippedSoftware = @()

    #region Preflight
    if ($Action -eq 'RestoreSnapshot') {
        try {
            # Most sections need administrator rights, and an unattended
            # restore cannot ask for them
            if ($Unattended -and -not (Test-ElevatedHC)) {
                throw (
                    'Unattended restore requires administrator rights. ' +
                    'Start PowerShell as administrator first; UAC will ' +
                    'not be requested.'
                )
            }

            $readParams = @{
                Path       = $configurationPath
                RootFolder = $RootFolder
                Items      = $Items
            }
            $configuration = Read-ConfigurationHC @readParams

            if ($configuration.Problems.Count) {
                throw ($configuration.Problems -join [Environment]::NewLine)
            }

            # Before the answers, so an entry that does not run asks nothing
            if ($SkipSoftwareInstall.Count) {
                $skipParams = @{
                    Items = $configuration.Items
                    Skip  = $SkipSoftwareInstall
                }
                $skippedSoftware = @(Skip-SoftwareInstallHC @skipParams)
            }

            $testParams = @{
                Configuration = $configuration
                RootFolder    = $RootFolder
            }

            # Report what is wrong before anybody types an answer
            $problems = @(Test-ConfigurationBeforeInputHC @testParams)

            if ($problems.Count) {
                Write-Verbose 'Configuration problems found, ask for no input'
            }
            else {
                $answers = $null

                if ($PSBoundParameters.ContainsKey('AnswerFile')) {
                    if ([string]::IsNullOrWhiteSpace($AnswerFile)) {
                        throw 'AnswerFile must not be empty.'
                    }

                    $answerPath = Resolve-RootPathHC $AnswerFile $RootFolder
                    $answers = Read-RestoreAnswerFileHC -Path $answerPath
                }

                if (-not [string]::IsNullOrWhiteSpace($AnswerPipe)) {
                    $joinParams = @{
                        Answers  = $answers
                        PipeName = $AnswerPipe
                    }
                    $answers = Join-RestoreAnswersHC @joinParams
                }

                $inputParams = @{
                    Items      = $configuration.Items
                    RootFolder = $RootFolder
                    Answers    = $answers
                    Unattended = $Unattended
                    ReadValues = {
                        param($questions)
                        Read-RestoreInputHC -Questions $questions
                    }
                }
                $inputResult = Resolve-RestoreInputHC @inputParams

                $secretValues = $inputResult.SecretValues

                # The answers can still be invalid where they are used
                $problems = @(Test-ConfigurationHC @testParams)

                # Each copy gets only the answers of its own file, never a
                # password, so no other answer reaches the copy section
                $copies = @(
                    $configuration.Items.CopyFilesFolders |
                    Where-Object { $null -ne $_ }
                )

                foreach ($copy in $copies) {
                    if ($copy.FillPlaceholders -ne $true) {
                        continue
                    }

                    $dictionaryType = (
                        'System.Collections.Generic.Dictionary[string,string]'
                    )
                    $fileValues = New-Object $dictionaryType (
                        [StringComparer]::Ordinal
                    )

                    $fileParams = @{
                        Items      = @{ CopyFilesFolders = @($copy) }
                        RootFolder = $RootFolder
                    }

                    foreach ($field in @(Get-FileInputFieldsHC @fileParams)) {
                        if (
                            $field.Kind -ne 'password' -and
                            $inputResult.Values.ContainsKey($field.Placeholder)
                        ) {
                            $fileValues[$field.Placeholder] = (
                                $inputResult.Values[$field.Placeholder]
                            )
                        }
                    }

                    Write-Verbose (
                        "Copy '$($copy.From)': " +
                        "$($fileValues.Count) placeholder answer(s)"
                    )

                    if ($copy -is [System.Collections.IDictionary]) {
                        $copy.PlaceholderValues = $fileValues
                    }
                    else {
                        $memberParams = @{
                            NotePropertyName  = 'PlaceholderValues'
                            NotePropertyValue = $fileValues
                            Force             = $true
                        }
                        $copy | Add-Member @memberParams
                    }
                }
            }

            if (-not $PSBoundParameters.ContainsKey('RebootComputer')) {
                $RebootComputer = $configuration.Settings.RebootComputer
            }

            if (-not $PSBoundParameters.ContainsKey('RestartDelaySeconds')) {
                $RestartDelaySeconds = (
                    $configuration.Settings.RestartDelaySeconds
                )
            }

            if (-not $PSBoundParameters.ContainsKey('OpenReportInBrowser')) {
                $OpenReportInBrowser = (
                    $configuration.Settings.OpenReportInBrowser
                )
            }

            if ($Unattended) {
                $OpenReportInBrowser = $false
            }

            $Items = @($configuration.Items.Keys)
        }
        catch [OperationCanceledException] {
            Write-Host 'Restore cancelled. No items executed.'

            return [pscustomobject]@{
                ConfigurationFile = $configurationPath
                ReportFile        = $null
                Results           = @()
                Success           = $false
                Cancelled         = $true
            }
        }
        catch {
            $problems = @([string]$_)
        }
    }
    else {
        if (-not $Items) {
            $Items = @($Script.Keys)
        }

        $configurationFolder = Split-Path $configurationPath -Parent
        $testPathParams = @{
            LiteralPath = $configurationFolder
            PathType    = 'Container'
        }

        if (-not (Test-Path @testPathParams)) {
            $problems += (
                'Configuration directory does not exist: ' +
                "'$configurationFolder'"
            )
        }
    }

    #region Only the built-in items can run, always in their fixed order
    $knownItems = @((Get-SnapshotScriptsHC).Keys)
    $supportedText = $knownItems -join ', '

    foreach ($name in $Script.Keys) {
        if ($name -notin $knownItems) {
            $problems += (
                "Unknown item '$name' in the script map. " +
                "Supported items: $supportedText"
            )
        }
    }

    foreach ($name in $Items) {
        if ($name -notin $knownItems) {
            # Unknown names that are in the script map were reported above
            if (-not $Script.Contains($name)) {
                $problems += (
                    "Unknown item '$name'. Supported items: $supportedText"
                )
            }
        }
        elseif (-not $Script.Contains($name)) {
            $problems += "No script configured for item '$name'"
        }
        elseif (-not (Test-Path -LiteralPath $Script[$name] -PathType Leaf)) {
            $problems += "Script for '$name' not found: '$($Script[$name])'"
        }
    }
    #endregion

    if ($problems.Count) {
        $problems = @(
            $problems | ForEach-Object {
                $protectParams = @{
                    Text         = [string]$_
                    SecretValues = $secretValues
                }
                Protect-RestoreInputTextHC @protectParams
            }
        )

        foreach ($problem in $problems) {
            Write-Warning $problem
        }

        $results.Add(
            [pscustomobject]@{
                Name     = 'Validation'
                Status   = 'Failed'
                Messages = $problems
            }
        )

        $reportParams = @{
            ReportsFolder     = $ReportsFolder
            Action            = $Action
            ConfigurationFile = $configurationPath
            Results           = $results
        }
        $report = Write-SnapshotReportHC @reportParams

        throw (
            'Configuration validation failed. No items executed. ' +
            "Report: '$report'"
        )
    }

    if (-not (Test-ElevatedHC)) {
        Write-Warning (
            'Not running as administrator; some Windows operations may be ' +
            'unavailable.'
        )
    }
    #endregion

    # Validation above guarantees that every selected item is known and has
    # a script
    $selected = @($knownItems | Where-Object { $_ -in $Items })
    $exportItems = [ordered]@{}
    # A file is written once at least one section was exported
    $exported = $false
    $step = 0

    foreach ($name in $selected) {
        $step++

        $progressParams = @{
            Activity        = $Action
            Status          = $name
            PercentComplete = [int](100 * $step / $selected.Count)
        }
        Write-Progress @progressParams

        $data = $null

        if ($Action -eq 'RestoreSnapshot') {
            $data = $configuration.Items[$name]
        }
        elseif ($ExportOptions -and $ExportOptions.Contains($name)) {
            $data = $ExportOptions[$name]
        }

        if ($Action -eq 'RestoreSnapshot' -and (Test-EmptySectionHC $data)) {
            $skippedMessages = @('Nothing to do')
            if ($name -eq 'Software' -and $skippedSoftware.Count) {
                $skippedMessages = @(
                    $skippedSoftware | ForEach-Object {
                        "Not installed, unchecked in the wizard: $_"
                    }
                ) + $skippedMessages
            }
            $results.Add(
                [pscustomobject]@{
                    Name     = $name
                    Status   = 'Skipped'
                    Messages = $skippedMessages
                }
            )

            continue
        }

        $childAction = if ($Action -eq 'CreateSnapshot') {
            'Export'
        }
        else {
            'Import'
        }

        $errors = New-Object 'System.Collections.Generic.List[object]'
        $output = New-Object 'System.Collections.Generic.List[object]'
        $terminatingError = $null

        try {
            # Redirect instead of -ErrorVariable: -ErrorVariable also records
            # every frame a terminating error passes through, which
            # duplicates messages. Sorting while streaming keeps errors
            # written before a terminating error.
            $childParams = @{
                Path         = $Script[$name]
                Action       = $childAction
                Data         = $data
                RootFolder   = $RootFolder
                SecretValues = $secretValues
                ErrorAction  = 'Continue'
            }
            Invoke-ChildScriptHC @childParams 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $errors.Add($_)
                }
                else {
                    $output.Add($_)
                }
            }
        }
        catch {
            $terminatingError = $_
        }

        #region Collect every reported problem, not only the first
        $isValidResult = (
            $output.Count -eq 1 -and
            $output[0].PSObject.Properties.Name -contains 'Data' -and
            $output[0].Messages -is [string[]] -and
            $output[0].Errors -is [string[]]
        )

        $errorMessages = New-Object 'System.Collections.Generic.List[string]'

        # Errors the child reports itself, one per failed entry
        if ($isValidResult) {
            foreach ($childError in $output[0].Errors) {
                $protectParams = @{
                    Text         = $childError
                    SecretValues = $secretValues
                }
                $errorMessages.Add((Protect-RestoreInputTextHC @protectParams))
            }
        }

        # Safety net: errors written to the error stream or thrown
        foreach ($childError in $errors) {
            $protectParams = @{
                Text         = [string]$childError
                SecretValues = $secretValues
            }
            $errorMessages.Add((Protect-RestoreInputTextHC @protectParams))
        }

        if ($terminatingError) {
            $protectParams = @{
                Text         = [string]$terminatingError
                SecretValues = $secretValues
            }
            $errorMessages.Add((Protect-RestoreInputTextHC @protectParams))
        }

        if (-not $isValidResult -and -not $terminatingError) {
            $errorMessages.Add(
                "'$name' did not return exactly one result with Data, " +
                'Messages (string array) and Errors (string array)'
            )
        }
        #endregion

        $messages = New-Object 'System.Collections.Generic.List[string]'

        if ($name -eq 'Software') {
            foreach ($label in $skippedSoftware) {
                $messages.Add("Not installed, unchecked in the wizard: $label")
            }
        }

        if ($isValidResult) {
            foreach ($message in $output[0].Messages) {
                $protectParams = @{
                    Text         = $message
                    SecretValues = $secretValues
                }
                $messages.Add((Protect-RestoreInputTextHC @protectParams))
            }
        }

        foreach ($message in $errorMessages) {
            $messages.Add("ERROR: $message")
        }

        if ($errorMessages.Count) {
            $results.Add(
                [pscustomobject]@{
                    Name     = $name
                    Status   = 'Failed'
                    Messages = $messages.ToArray()
                }
            )

            # Still in the export, empty, so it can be filled in
            if ($Action -eq 'CreateSnapshot') {
                $exportItems[$name] = Get-EmptySectionValueHC -Name $name
            }

            continue
        }

        if ($Action -eq 'CreateSnapshot') {
            # Every selected section is in the export: its data, or its
            # empty value when there is nothing to export
            $exportItems[$name] = if (Test-EmptySectionHC $output[0].Data) {
                Get-EmptySectionValueHC -Name $name
            }
            else {
                $output[0].Data
            }
            $exported = $true
        }

        $results.Add(
            [pscustomobject]@{
                Name     = $name
                Status   = 'Success'
                Messages = $messages.ToArray()
            }
        )
    }

    Write-Progress -Activity $Action -Completed

    #region Single-file export
    if ($Action -eq 'CreateSnapshot' -and $exported) {
        $document = [ordered]@{
            SchemaVersion = 3
            Description   = 'Exported from {0} on {1}' -f (
                $env:COMPUTERNAME,
                (Get-Date -Format 'yyyy-MM-dd HH:mm')
            )
            Settings      = [ordered]@{
                RebootComputer      = $false
                RestartDelaySeconds = 60
                OpenReportInBrowser = $true
                RunElevated         = $false
            }
            Items         = $exportItems
        }

        $isWritten = $false

        try {
            $writeParams = @{
                Configuration = $document
                Path          = $configurationPath
            }
            Write-ConfigurationHC @writeParams

            $isWritten = $true
        }
        catch {
            # The previous configuration, if any, is left untouched
            $results.Add(
                [pscustomobject]@{
                    Name     = 'Configuration file'
                    Status   = 'Failed'
                    Messages = @("ERROR: $_")
                }
            )
        }

        if ($isWritten) {
            try {
                $readParams = @{
                    Path       = $configurationPath
                    RootFolder = $RootFolder
                }
                $exported = Read-ConfigurationHC @readParams

                $testParams = @{
                    Configuration = $exported
                    RootFolder    = $RootFolder
                }
                $warnings = @(Test-ConfigurationHC @testParams)
            }
            catch {
                $warnings = @([string]$_)
            }

            if ($warnings.Count) {
                foreach ($warning in $warnings) {
                    Write-Warning $warning
                }

                $results.Add(
                    [pscustomobject]@{
                        Name     = 'Export validation'
                        Status   = 'Warning'
                        Messages = $warnings
                    }
                )
            }
        }
    }
    #endregion

    $failed = @(
        $results | Where-Object { $_.Status -eq 'Failed' }
    )

    #region Restart, only after a restore in which nothing failed
    $restartScheduled = $false

    if ($RebootComputer) {
        $restart = [pscustomobject]@{
            Name     = 'Restart computer'
            Status   = 'Skipped'
            Messages = @()
        }

        if ($Action -ne 'RestoreSnapshot') {
            $restart.Messages = @('The computer only restarts after a restore')
        }
        elseif ($failed.Count) {
            $restart.Messages = @(
                'Not restarted, because a section failed; ' +
                'restart manually after fixing the problem'
            )
        }
        else {
            try {
                Start-ComputerRestartHC -DelaySeconds $RestartDelaySeconds
                $restartScheduled = $true

                $restart.Status = 'Success'
                $restart.Messages = @(
                    "The computer restarts in $RestartDelaySeconds seconds; " +
                    "run 'shutdown /a' to cancel"
                )
            }
            catch {
                # The restore itself succeeded
                $restart.Status = 'Warning'
                $restart.Messages = @(
                    "ERROR: The restart could not be scheduled: $_"
                )
            }
        }

        $results.Add($restart)
    }
    #endregion

    foreach ($result in $results) {
        Write-Host ('{0}: {1}' -f $result.Name, $result.Status)

        foreach ($message in $result.Messages) {
            Write-Host "  $message"
        }
    }

    $reportParams = @{
        ReportsFolder     = $ReportsFolder
        Action            = $Action
        ConfigurationFile = $configurationPath
        Results           = $results
    }
    $report = Write-SnapshotReportHC @reportParams

    if ($OpenReportInBrowser) {
        try {
            Start-Process -FilePath $report
        }
        catch {
            # A computer without a program for .html files, such as Server
            # Core, cannot open the report; the run itself is not affected
            Write-Warning (
                "The report could not be opened: $($_.Exception.Message). " +
                "It is saved as '$report'"
            )
        }
    }

    if (
        $Action -eq 'CreateSnapshot' -and
        -not $exported
    ) {
        throw (
            'No items exported. No configuration written. ' +
            "Report: '$report'"
        )
    }

    [pscustomobject]@{
        ConfigurationFile = $configurationPath
        ReportFile        = $report
        Results           = $results.ToArray()
        Success           = ($failed.Count -eq 0)
        RestartScheduled  = $restartScheduled
    }
}

Export-ModuleMember -Function Invoke-ComputerSnapshotHC