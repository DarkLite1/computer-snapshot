#Requires -Version 5.1
<#
.SYNOPSIS
    Execute validated in-memory snapshot sections and report the results.
#>
Import-Module "$PSScriptRoot\Configuration.psm1" -Force
. "$PSScriptRoot\Section.ps1"

function Invoke-ChildScriptHC {
    [CmdletBinding()]
    param([string]$Path, [string]$Action, $Data, [string]$RootFolder)
    & $Path -Action $Action -Data $Data -RootFolder $RootFolder
}

function Test-ElevatedHC {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-SnapshotReportHC {
    param([string]$ReportsFolder, [string]$Action, [string]$ConfigurationFile, $Results)
    $null = New-Item -Path $ReportsFolder -ItemType Directory -Force -ErrorAction Stop
    $operation = if ($Action -eq 'CreateSnapshot') { 'Export' } else { 'Restore' }
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
        [switch]$Force
    )
    $configurationPath = Resolve-RootPathHC $ConfigurationFile $RootFolder
    if ($Action -eq 'CreateSnapshot' -and (Test-Path -LiteralPath $configurationPath) -and -not $Force) {
        throw "Configuration '$configurationPath' already exists. Use -Force to replace it."
    }
    if (-not $ReportsFolder) { $ReportsFolder = Join-Path $RootFolder 'Log' }
    $ReportsFolder = Resolve-RootPathHC $ReportsFolder $RootFolder
    $results = New-Object 'System.Collections.Generic.List[object]'
    $problems = @()
    $configuration = $null
    #region Preflight
    if ($Action -eq 'RestoreSnapshot') {
        try {
            $configuration = Read-ConfigurationHC -Path $configurationPath -RootFolder $RootFolder -Items $Items
            $problems = @(Test-ConfigurationHC -Configuration $configuration -RootFolder $RootFolder)
            if (-not $PSBoundParameters.ContainsKey('RebootComputer')) { $RebootComputer = $configuration.Settings.RebootComputer }
            if (-not $PSBoundParameters.ContainsKey('OpenReportInBrowser')) { $OpenReportInBrowser = $configuration.Settings.OpenReportInBrowser }
            $Items = @($configuration.Items.Keys)
        }
        catch { $problems = @([string]$_) }
    }
    else {
        if (-not $Items) { $Items = @($Script.Keys) }
        if (-not (Test-Path -LiteralPath (Split-Path $configurationPath -Parent) -PathType Container)) {
            $problems += "Configuration directory does not exist: '$(Split-Path $configurationPath -Parent)'"
        }
    }
    foreach ($name in $Items) {
        if (-not $Script.Contains($name)) { $problems += "Unknown item '$name'" }
        elseif (-not (Test-Path -LiteralPath $Script[$name] -PathType Leaf)) { $problems += "Script for '$name' not found: '$($Script[$name])'" }
    }
    if ($problems.Count) {
        foreach ($problem in $problems) { Write-Warning $problem }
        $results.Add([pscustomobject]@{ Name = 'Validation'; Status = 'Failed'; Messages = $problems })
        $report = Write-SnapshotReportHC $ReportsFolder $Action $configurationPath $results
        throw "Configuration validation failed. No items executed. Report: '$report'"
    }
    if (-not (Test-ElevatedHC)) { Write-Warning 'Not running as administrator; some Windows operations may be unavailable.' }
    #endregion
    $selected = @((Get-SnapshotScriptsHC).Keys | Where-Object { $_ -in $Items })
    $exportItems = [ordered]@{}
    $step = 0
    foreach ($name in $selected) {
        $step++
        Write-Progress -Activity $Action -Status $name -PercentComplete ([int](100 * $step / $selected.Count))
        $data = $null
        if ($Action -eq 'RestoreSnapshot') { $data = $configuration.Items[$name] }
        if ($Action -eq 'RestoreSnapshot' -and (Test-EmptySectionHC $data)) {
            $results.Add([pscustomobject]@{ Name = $name; Status = 'Skipped'; Messages = @('Nothing to do') })
            continue
        }
        try {
            $errors = @()
            $childAction = if ($Action -eq 'CreateSnapshot') { 'Export' } else { 'Import' }
            $result = @(Invoke-ChildScriptHC -Path $Script[$name] -Action $childAction -Data $data -RootFolder $RootFolder -ErrorVariable +errors)
            if ($result.Count -ne 1 -or $result[0].PSObject.Properties.Name -notcontains 'Data' -or $result[0].Messages -isnot [string[]]) {
                throw "'$name' did not return exactly one Data/Messages result"
            }
            if ($errors.Count) { throw ($errors -join [Environment]::NewLine) }
            if ($Action -eq 'CreateSnapshot') { $exportItems[$name] = $result[0].Data }
            $results.Add([pscustomobject]@{ Name = $name; Status = 'Success'; Messages = $result[0].Messages })
        }
        catch {
            $results.Add([pscustomobject]@{ Name = $name; Status = 'Failed'; Messages = @([string]$_) })
        }
    }
    Write-Progress -Activity $Action -Completed
    #region Single-file export
    if ($Action -eq 'CreateSnapshot' -and $exportItems.Count) {
        $document = [ordered]@{
            SchemaVersion = 2
            Description = 'Exported from {0} on {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')
            Settings = [ordered]@{ RebootComputer = $false; OpenReportInBrowser = $true; RunElevated = $false }
            Items = $exportItems
        }
        Write-ConfigurationHC -Configuration $document -Path $configurationPath
        try {
            $exported = Read-ConfigurationHC -Path $configurationPath -RootFolder $RootFolder
            $warnings = @(Test-ConfigurationHC -Configuration $exported -RootFolder $RootFolder)
        }
        catch { $warnings = @([string]$_) }
        if ($warnings.Count) {
            foreach ($warning in $warnings) { Write-Warning $warning }
            $results.Add([pscustomobject]@{ Name = 'Export validation'; Status = 'Warning'; Messages = $warnings })
        }
    }
    #endregion
    foreach ($result in $results) {
        Write-Host ("{0}: {1}" -f $result.Name, $result.Status)
        foreach ($message in $result.Messages) { Write-Host "  $message" }
    }
    $report = Write-SnapshotReportHC $ReportsFolder $Action $configurationPath $results
    if ($OpenReportInBrowser) { Start-Process -FilePath $report }
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($Action -eq 'CreateSnapshot' -and $exportItems.Count -eq 0) { throw "No items exported. No configuration written. Report: '$report'" }
    if ($RebootComputer -and $failed.Count -eq 0) { Restart-Computer }
    [pscustomobject]@{ ConfigurationFile = $configurationPath; ReportFile = $report; Results = $results.ToArray(); Success = ($failed.Count -eq 0) }
}
Export-ModuleMember -Function Invoke-ComputerSnapshotHC