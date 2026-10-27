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
        All streams are captured so that every error the child writes reaches the
        caller, whatever the caller's ErrorAction is. Inside the child, errors stay
        nonterminating so one failed entry does not stop the remaining entries.
        Errors are rewritten as new error records with secrets redacted, so the
        caller receives each reported error exactly once. Errors the child
        handles itself (try/catch without Write-Error) are not reported.
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

    & $Path -Action $Action -Data $Data -RootFolder $RootFolder *>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $message = Protect-RestoreInputTextHC -Text ([string]$_) -SecretValues $SecretValues

            Write-Error -Message $message -ErrorAction $callerPreference
            return

        }
        if ($_ -is [System.Management.Automation.WarningRecord] -or
            $_ -is [System.Management.Automation.VerboseRecord] -or
            $_ -is [System.Management.Automation.DebugRecord] -or
            $_ -is [System.Management.Automation.InformationRecord]
        ) {
            $message = Protect-RestoreInputTextHC -Text ([string]$_) -SecretValues $SecretValues

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

function Test-ElevatedHC {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-SnapshotReportHC {
    param(
        [string]$ReportsFolder,
        [string]$Action,
        [string]$ConfigurationFile, 
        $Results
    )

    $null = New-Item `
        -Path $ReportsFolder `
        -ItemType Directory `
        -Force -ErrorAction Stop

    $operation = if ($Action -eq 'CreateSnapshot') {
        'Export'
    }
    else {
        'Restore' 
    }

    $configurationName = [IO.Path]::GetFileNameWithoutExtension($ConfigurationFile)

    $reportName = '{0}-{1}-{2}-{3}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'), $operation, $configurationName

    $path = Join-Path $ReportsFolder ($reportName + '.html')

    $suffix = 2

    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $ReportsFolder ('{0}-{1}.html' -f $reportName, $suffix)

        $suffix++
    }
    $rows = foreach ($result in $Results) {
        $item = [System.Net.WebUtility]::HtmlEncode($result.Name)
        $status = [System.Net.WebUtility]::HtmlEncode($result.Status)
        $messages = @($result.Messages | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode([string]$_) + '</li>' }) -join ''
        "<tr><th>$item</th><td>$status</td><td><ul>$messages</ul></td></tr>"
    }
    $title = [System.Net.WebUtility]::HtmlEncode("$Action - $ConfigurationFile")
    $html = '<!doctype html><html><head><meta charset="utf-8"><title>' + $title + '</title><style>body{font-family:Segoe UI,sans-serif;margin:2rem}table{border-collapse:collapse;width:100%}td,th{padding:0.6rem;border:1px solid #bbb;text-align:left;vertical-align:top}ul{margin:0}</style></head><body><h1>' + $title + '</h1><table><thead><tr><th>Item</th><th>Status</th><th>Messages</th></tr></thead><tbody>' + ($rows -join '') + '</tbody></table></body></html>'
    [IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding $false))
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

    $comment = 'Computer snapshot restore completed. ' +
    'The computer restarts to apply the changes.'

    $output = & shutdown.exe /r /t $DelaySeconds /d p:4:1 /c $comment 2>&1

    if ($LASTEXITCODE) {
        throw "shutdown.exe failed with exit code $($LASTEXITCODE): " +
        ($output -join ' ')
    }
}

function Invoke-ComputerSnapshotHC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('CreateSnapshot', 'RestoreSnapshot')][string]$Action,
        [Parameter(Mandatory)][string]$ConfigurationFile,
        [string[]]$Items,
        [Parameter(Mandatory)][string]$RootFolder,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Script,
        [string]$ReportsFolder,
        [bool]$RebootComputer = $false,
        [bool]$OpenReportInBrowser = $true,
        [ValidateRange(0, 600)]
        [int]$RestartDelaySeconds = 60,
        [switch]$Force
    )
    $configurationPath = Resolve-RootPathHC $ConfigurationFile $RootFolder

    if (
        $Action -eq 'CreateSnapshot' -and 
        (Test-Path -LiteralPath $configurationPath) -and 
        -not $Force
    ) {
        throw "Configuration '$configurationPath' already exists. Use -Force to replace it."
    }

    if (-not $ReportsFolder) { 
        $ReportsFolder = Join-Path $RootFolder 'Log' 
    }

    $ReportsFolder = Resolve-RootPathHC $ReportsFolder $RootFolder
    $results = New-Object 'System.Collections.Generic.List[object]'
    $problems = @()
    $configuration = $null
    $secretValues = @()

    #region Preflight
    if ($Action -eq 'RestoreSnapshot') {
        try {
            $configuration = Read-ConfigurationHC `
                -Path $configurationPath `
                -RootFolder $RootFolder `
                -Items $Items

            if ($configuration.Problems.Count) {
                throw ($configuration.Problems -join [Environment]::NewLine) 
            }
                
            $inputResult = Resolve-RestoreInputHC `
                -Items $configuration.Items `
                -ReadValue { param($field) Read-RestoreInputHC -Field $field }

            $secretValues = $inputResult.SecretValues

            $problems = @(
                Test-ConfigurationHC `
                    -Configuration $configuration `
                    -RootFolder $RootFolder
            )

            if (-not $PSBoundParameters.ContainsKey('RebootComputer')) {
                $RebootComputer = $configuration.Settings.RebootComputer 
            }
            
            if (-not $PSBoundParameters.ContainsKey('OpenReportInBrowser')) { 
                $OpenReportInBrowser = $configuration.Settings.OpenReportInBrowser 
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

        if (-not (
                Test-Path `
                    -LiteralPath (Split-Path $configurationPath -Parent) `
                    -PathType Container)
        ) {
            $problems += "Configuration directory does not exist: '$(Split-Path $configurationPath -Parent)'"
        }
    }
    
    #region Only the built-in items can run, always in their fixed order
    $knownItems = @((Get-SnapshotScriptsHC).Keys)
    $supportedText = $knownItems -join ', '
    
    foreach ($name in $Script.Keys) {
        if ($name -notin $knownItems) { 
            $problems += "Unknown item '$name' in the script map. Supported items: $supportedText" 
        }
    }
    foreach ($name in $Items) {
        if ($name -notin $knownItems) {
            # Unknown names that are in the script map were reported above
            if (-not $Script.Contains($name)) { 
                $problems += "Unknown item '$name'. Supported items: $supportedText" 
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
                Protect-RestoreInputTextHC `
                    -Text ([string]$_) `
                    -SecretValues $secretValues }
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

        $report = Write-SnapshotReportHC $ReportsFolder $Action $configurationPath $results

        throw "Configuration validation failed. No items executed. Report: '$report'"
    }
    if (-not (Test-ElevatedHC)) {
        Write-Warning 'Not running as administrator; some Windows operations may be unavailable.' 
    }
    #endregion
    
    # Validation above guarantees that every selected item is known and has a script
    $selected = @($knownItems | Where-Object { $_ -in $Items })
    $exportItems = [ordered]@{}
    $step = 0

    foreach ($name in $selected) {
        $step++
        Write-Progress `
            -Activity $Action `
            -Status $name `
            -PercentComplete ([int](100 * $step / $selected.Count))

        $data = $null
        
        if ($Action -eq 'RestoreSnapshot') {
            $data = $configuration.Items[$name] 
        }

        if ($Action -eq 'RestoreSnapshot' -and (Test-EmptySectionHC $data)) {
            $results.Add(
                [pscustomobject]@{ 
                    Name     = $name
                    Status   = 'Skipped' 
                    Messages = @('Nothing to do') 
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
            # Redirect instead of -ErrorVariable: -ErrorVariable also records every
            # frame a terminating error passes through, which duplicates messages.
            # Sorting while streaming keeps errors written before a terminating error.
            Invoke-ChildScriptHC `
                -Path $Script[$name] `
                -Action $childAction `
                -Data $data `
                -RootFolder $RootFolder `
                -SecretValues $secretValues `
                -ErrorAction Continue 2>&1 |
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
                $errorMessages.Add(
                    (Protect-RestoreInputTextHC `
                        -Text $childError `
                        -SecretValues $secretValues)
                )
            }
        }
        # Safety net: errors written to the error stream or thrown
        foreach ($childError in $errors) {
            $errorMessages.Add(
                (Protect-RestoreInputTextHC `
                    -Text ([string]$childError) `
                    -SecretValues $secretValues)
            )
        }

        if ($terminatingError) {
            $errorMessages.Add(
                (Protect-RestoreInputTextHC `
                    -Text ([string]$terminatingError) `
                    -SecretValues $secretValues)
            )
        }

        if (-not $isValidResult -and -not $terminatingError) {
            $errorMessages.Add(
                "'$name' did not return exactly one result with Data, " +
                'Messages (string array) and Errors (string array)'
            )
        }
        #endregion

        $messages = New-Object 'System.Collections.Generic.List[string]'

        if ($isValidResult) {
            foreach ($message in $output[0].Messages) { $messages.Add((Protect-RestoreInputTextHC -Text $message -SecretValues $secretValues)) }
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

            continue
        }

        if ($Action -eq 'CreateSnapshot') {
            $exportItems[$name] = $output[0].Data 
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
    if ($Action -eq 'CreateSnapshot' -and $exportItems.Count) {
        $document = [ordered]@{
            SchemaVersion = 2
            Description   = 'Exported from {0} on {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')
            Settings      = [ordered]@{ RebootComputer = $false; OpenReportInBrowser = $true; RunElevated = $false }
            Items         = $exportItems
        }

        $isWritten = $false

        try {
            Write-ConfigurationHC `
                -Configuration $document `
                -Path $configurationPath

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
                $exported = Read-ConfigurationHC `
                    -Path $configurationPath `
                    -RootFolder $RootFolder
                    
                $warnings = @(
                    Test-ConfigurationHC `
                        -Configuration $exported `
                        -RootFolder $RootFolder
                )
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

    $report = Write-SnapshotReportHC $ReportsFolder $Action $configurationPath $results

    if ($OpenReportInBrowser) {
        Start-Process -FilePath $report 
    }
        
    if (
        $Action -eq 'CreateSnapshot' -and
        $exportItems.Count -eq 0
    ) {
        throw "No items exported. No configuration written. Report: '$report'" 
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