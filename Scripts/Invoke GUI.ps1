#Requires -Version 5.1
<#
.SYNOPSIS
    Native Windows wizard for single-file computer configurations.
.PARAMETER RootFolder
    USB root containing Configurations, Scripts, Software and Files.
.PARAMETER NoShow
    Load the command-building functions without displaying a form, for tests.
#>
[CmdletBinding()]
param(
    [string]$RootFolder = (Split-Path $PSScriptRoot -Parent),
    [switch]$NoShow
)

#region Command construction
function Get-DefaultConfigurationNameHC {
    return $env:COMPUTERNAME + ' ' + (Get-Date -Format 'yyyy-MM-dd HHmmss')
}

function Get-ConfigurationEntriesHC {
    param([string]$RootFolder)
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RootFolder 'Configurations') -Filter '*.json' -File -ErrorAction Stop | Where-Object { $_.Name -notlike '*.v1.json' }) {
        try { $document = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { $document = @{ Description = 'Invalid JSON' } }
        [pscustomobject]@{ Name = $file.BaseName; Description = $document.Description; Path = $file.FullName }
    }
}

function Start-ConfigurationJobHC {
    param(
        [ValidateSet('CreateSnapshot', 'RestoreSnapshot')][string]$Action,
        [string]$RootFolder,
        [string]$ConfigurationFile,
        [string]$Name,
        [string[]]$Items,
        [bool]$OpenReportInBrowser = $true,
        [switch]$RunElevated,
        [switch]$Force
    )
    if ($Action -eq 'CreateSnapshot') {
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Name -in @('.', '..')) {
            throw 'Enter a configuration file name without directory separators or invalid filename characters.'
        }
        if (-not $Items.Count) { throw 'Select at least one item.' }
        $fileName = if ($Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $Name } else { $Name + '.json' }
        $ConfigurationFile = Join-Path (Join-Path $RootFolder 'Configurations') $fileName
        if ((Test-Path -LiteralPath $ConfigurationFile) -and -not $Force) { throw "Configuration '$fileName' already exists." }
        $script = Join-Path $RootFolder 'Scripts\Invoke scripts.ps1'
        $itemArguments = ($Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
        $command = "& '{0}' -Action CreateSnapshot -ConfigurationFile '{1}' -Items @({2}) -OpenReportInBrowser `${3}" -f $script.Replace("'", "''"), $ConfigurationFile.Replace("'", "''"), $itemArguments, $OpenReportInBrowser.ToString().ToLowerInvariant()
        if ($Force) { $command += ' -Force' }
    }
    else {
        if (-not (Test-Path -LiteralPath $ConfigurationFile -PathType Leaf)) { throw 'Select an existing configuration file.' }
        $script = Join-Path $RootFolder 'Scripts\Invoke configuration.ps1'
        $command = "& '{0}' -ConfigurationFile '{1}' -Confirm" -f $script.Replace("'", "''"), $ConfigurationFile.Replace("'", "''")
    }
    $parameters = @{
        FilePath = 'powershell.exe'
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    }
    if ($RunElevated) { $parameters.Verb = 'RunAs' }
    Start-Process @parameters
}
#endregion
if ($NoShow) { return }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

#region Native Windows interface
$form = New-Object Windows.Forms.Form
$form.Text = 'Computer Snapshot'
$form.ClientSize = New-Object Drawing.Size 760, 540
$form.MinimumSize = New-Object Drawing.Size 650, 480
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font 'Segoe UI', 10
$form.Icon = [Drawing.SystemIcons]::Application
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$restoreTab = New-Object Windows.Forms.TabPage 'Restore'
$exportTab = New-Object Windows.Forms.TabPage 'Export'
$tabs.TabPages.AddRange(@($restoreTab, $exportTab))
$form.Controls.Add($tabs)

$restoreLayout = New-Object Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'
$restoreLayout.Padding = New-Object Windows.Forms.Padding 12
$restoreLayout.ColumnCount = 1
$restoreLayout.RowCount = 2
$null = $restoreLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
$null = $restoreLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), 48))
$restoreTab.Controls.Add($restoreLayout)
$configurations = New-Object Windows.Forms.ListView
$configurations.Dock = 'Fill'
$configurations.View = 'Details'
$configurations.FullRowSelect = $true
$configurations.MultiSelect = $false
$configurations.HideSelection = $false
$null = $configurations.Columns.Add('Configuration', 240)
$null = $configurations.Columns.Add('Description', 420)
$restoreLayout.Controls.Add($configurations, 0, 0)
$restoreButtons = New-Object Windows.Forms.FlowLayoutPanel
$restoreButtons.Dock = 'Fill'
$restoreButtons.FlowDirection = 'RightToLeft'
$restore = New-Object Windows.Forms.Button
$restore.Text = 'Restore'
$restore.Size = New-Object Drawing.Size 120, 34
$refresh = New-Object Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Size = New-Object Drawing.Size 120, 34
$restoreButtons.Controls.AddRange(@($restore, $refresh))
$restoreLayout.Controls.Add($restoreButtons, 0, 1)
$refresh.Add_Click({
    try {
        $configurations.Items.Clear()
        foreach ($entry in Get-ConfigurationEntriesHC $RootFolder) {
            $item = New-Object Windows.Forms.ListViewItem $entry.Name
            $null = $item.SubItems.Add([string]$entry.Description)
            $item.Tag = $entry.Path
            $null = $configurations.Items.Add($item)
        }
    }
    catch { $null = [Windows.Forms.MessageBox]::Show($form, [string]$_, 'Configuration error', 'OK', 'Error') }
})
$restore.Add_Click({
    if ($configurations.SelectedItems.Count -eq 0) { return }
    $selected = $configurations.SelectedItems[0]
    if ([Windows.Forms.MessageBox]::Show($form, "Restore '$($selected.Text)' on this computer?", 'Confirm restore', 'YesNo', 'Warning') -ne 'Yes') { return }
    try { Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $RootFolder -ConfigurationFile $selected.Tag }
    catch { $null = [Windows.Forms.MessageBox]::Show($form, [string]$_, 'Restore error', 'OK', 'Error') }
})
$configurations.Add_DoubleClick({ $restore.PerformClick() })

$exportLayout = New-Object Windows.Forms.TableLayoutPanel
$exportLayout.Dock = 'Fill'
$exportLayout.Padding = New-Object Windows.Forms.Padding 12
$exportLayout.ColumnCount = 1
$exportLayout.RowCount = 5
foreach ($height in @(30, 38)) { $null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), $height)) }
$null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
foreach ($height in @(40, 48)) { $null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), $height)) }
$exportTab.Controls.Add($exportLayout)
$nameLabel = New-Object Windows.Forms.Label
$nameLabel.Text = 'Configuration name'
$nameLabel.Dock = 'Fill'
$nameBox = New-Object Windows.Forms.TextBox
$nameBox.Dock = 'Fill'
$nameBox.Text = Get-DefaultConfigurationNameHC
$itemList = New-Object Windows.Forms.CheckedListBox
$itemList.Dock = 'Fill'
$itemList.CheckOnClick = $true
foreach ($name in @('StartCustomScriptsBefore','RegionalSettings','UserAccounts','UserGroups','FirewallRules','CreateFolders','SmbShares','NetworkCards','NtpTimeServers','RegistryKeys','ScheduledTasks','CopyFilesFolders','Software','StartCustomScriptsAfter')) { $null = $itemList.Items.Add($name, $true) }
$options = New-Object Windows.Forms.FlowLayoutPanel
$options.Dock = 'Fill'
$openReport = New-Object Windows.Forms.CheckBox
$openReport.Text = 'Open report'
$openReport.AutoSize = $true
$openReport.Checked = $true
$elevated = New-Object Windows.Forms.CheckBox
$elevated.Text = 'Run as administrator'
$elevated.AutoSize = $true
$options.Controls.AddRange(@($openReport, $elevated))
$exportButtons = New-Object Windows.Forms.FlowLayoutPanel
$exportButtons.FlowDirection = 'RightToLeft'
$exportButtons.Dock = 'Fill'
$export = New-Object Windows.Forms.Button
$export.Text = 'Export'
$export.Size = New-Object Drawing.Size 120, 34
$exportButtons.Controls.Add($export)
$exportLayout.Controls.Add($nameLabel, 0, 0)
$exportLayout.Controls.Add($nameBox, 0, 1)
$exportLayout.Controls.Add($itemList, 0, 2)
$exportLayout.Controls.Add($options, 0, 3)
$exportLayout.Controls.Add($exportButtons, 0, 4)
$export.Add_Click({
    try {
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $RootFolder -Name $nameBox.Text -Items @($itemList.CheckedItems | ForEach-Object { [string]$_ }) -OpenReportInBrowser $openReport.Checked -RunElevated:$elevated.Checked
    }
    catch { $null = [Windows.Forms.MessageBox]::Show($form, [string]$_, 'Export error', 'OK', 'Error') }
})
$form.Add_Shown({ $refresh.PerformClick() })
try { $null = $form.ShowDialog() }
finally { $form.Dispose() }
#endregion