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

. "$PSScriptRoot\Common\Section.ps1"

#region Command construction
function Test-WizardElevatedHC {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal $identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Restart-WizardElevatedHC {
    param([string]$RootFolder, [string]$WizardScript)
    $command = "& '{0}' -RootFolder '{1}'" -f $WizardScript.Replace("'", "''"), $RootFolder.Replace("'", "''")
    $parameters = @{
        FilePath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        Verb = 'RunAs'
        WorkingDirectory = $env:WINDIR
        ArgumentList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        ErrorAction = 'Stop'
    }
    try { Start-Process @parameters }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { return $false }
        throw
    }
    return $true
}

function New-WizardElevationPanelHC {
    param([string]$RootFolder, [string]$WizardScript)
    if (Test-WizardElevatedHC) { return }
    $panel = New-Object Windows.Forms.FlowLayoutPanel
    $panel.Name = 'WizardElevation'
    $panel.Dock = 'Fill'
    $panel.AutoSize = $true
    $panel.FlowDirection = 'RightToLeft'
    $panel.Padding = New-Object Windows.Forms.Padding 6
    $button = New-Object Windows.Forms.Button
    $button.Name = 'RestartAsAdministrator'
    $button.Text = 'Restart as administrator'
    $button.Size = New-Object Drawing.Size 230, 34
    $button.Tag = @{ RootFolder = $RootFolder; WizardScript = $WizardScript }
    $button.Add_Click({
        $owner = $this.FindForm()
        $arguments = $this.Tag
        try {
            if (Restart-WizardElevatedHC @arguments) { $owner.Close() }
        }
        catch { $null = [Windows.Forms.MessageBox]::Show($owner, [string]$_, 'Administrator restart', 'OK', 'Error') }
    })
    $panel.Controls.Add($button)
    return ,$panel
}

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

function Get-SnapshotItemEntriesHC {
    param([string[]]$Items)
    $labels = @{
        StartCustomScriptsBefore = @('Custom scripts (before restore)', 'Run custom scripts before the other sections.')
        RegionalSettings = @('Regional settings', 'Language, culture, home location and time zone.')
        UserAccounts = @('User accounts', 'Local user accounts and their settings.')
        UserGroups = @('User groups', 'Local groups and group membership.')
        FirewallRules = @('Firewall rules', 'Windows Firewall rules and their settings.')
        CreateFolders = @('Create folders', 'Folder paths to create on the computer.')
        SmbShares = @('Shared folders (SMB)', 'Network shares, share access and NTFS permissions.')
        NetworkCards = @('Network adapters', 'Network adapter, IP address and DNS settings.')
        NtpTimeServers = @('Time synchronization', 'Domain time synchronization or NTP time servers.')
        RegistryKeys = @('Registry keys', 'Registry keys and values to apply.')
        ScheduledTasks = @('Scheduled tasks', 'Task definitions and enabled states.')
        CopyFilesFolders = @('Copy files and folders', 'Source and destination paths for file copies.')
        Software = @('Software', 'Applications to install or remove.')
        StartCustomScriptsAfter = @('Custom scripts (after restore)', 'Run custom scripts after the other sections.')
    }
    foreach ($name in (Get-SnapshotScriptsHC).Keys) {
        if ($null -ne $Items -and $name -notin $Items) { continue }
        [pscustomobject]@{ Key = $name; Name = $labels[$name][0]; Description = $labels[$name][1]; Available = $true }
    }
}

function Get-RestoreItemEntriesHC {
    param([string]$ConfigurationFile)
    $document = Get-Content -LiteralPath $ConfigurationFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($document.SchemaVersion -ne 2 -or $document.SchemaVersion -is [string]) { throw 'Select a version-2 configuration; convert older configurations first.' }
    if ($document.Items -isnot [pscustomobject]) { throw 'The configuration must contain an Items object.' }
    $names = @($document.Items.PSObject.Properties | Where-Object { $_.Name -cne 'Comment' } | ForEach-Object { $_.Name })
    if (-not $names.Count) { throw 'The configuration contains no items to restore.' }
    foreach ($name in $names) {
        if ($name -cnotin (Get-SnapshotScriptsHC).Keys) { throw "Unknown configuration item '$name'." }
    }
    foreach ($entry in Get-SnapshotItemEntriesHC) {
        $data = $document.Items.($entry.Key)
        $entry.Available = $entry.Key -in $names -and -not (Test-EmptySectionHC $data)
        if ($data -is [string]) { $entry.Available = -not [string]::IsNullOrWhiteSpace($data) }
        $entry
    }
}

function New-SnapshotItemListHC {
    param([object[]]$Entries)
    $list = New-Object Windows.Forms.ListView
    $list.Name = 'SnapshotItems'
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.ShowItemToolTips = $true
    $list.Tag = @($Entries | Where-Object { $_.Available -eq $false } | ForEach-Object { $_.Key })
    $null = $list.Columns.Add('Item', 250)
    $null = $list.Columns.Add('Description', 450)
    foreach ($entry in $Entries) {
        $item = New-Object Windows.Forms.ListViewItem $entry.Name
        $null = $item.SubItems.Add($entry.Description)
        $item.Tag = $entry.Key
        $item.ToolTipText = $entry.Description
        $item.Checked = $entry.Available -ne $false
        if ($entry.Available -eq $false) {
            $item.ForeColor = [Drawing.SystemColors]::GrayText
            $item.ToolTipText = 'No settings to restore in this configuration.'
        }
        $null = $list.Items.Add($item)
    }
    $list.Add_ItemCheck({
        param($sender, $eventArgs)
        if ($sender.Items[$eventArgs.Index].Tag -in $sender.Tag) {
            $eventArgs.NewValue = [Windows.Forms.CheckState]::Unchecked
        }
    })
    $list.Add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        $hit = $sender.HitTest($eventArgs.Location)
        if ($hit.Item -and $hit.Item.Tag -notin $sender.Tag -and
            -not ($hit.Location -band [Windows.Forms.ListViewHitTestLocations]::StateImage)) {
            $hit.Item.Checked = -not $hit.Item.Checked
        }
    })
    return ,$list
}

function Get-RestoreSettingsHC {
    param([string]$ConfigurationFile)
    $settings = @{ RebootComputer = $false; OpenReportInBrowser = $true }
    if ($ConfigurationFile) {
        $document = Get-Content -LiteralPath $ConfigurationFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
            if ($document.Settings.PSObject.Properties.Name -contains $setting) {
                if ($document.Settings.$setting -isnot [bool]) { throw "Settings.${setting} must be a Boolean." }
                $settings[$setting] = $document.Settings.$setting
            }
        }
    }
    return $settings
}

function New-RestoreSelectionFormHC {
    param([string]$ConfigurationName, [object[]]$Entries, [string]$ConfigurationFile)
    $settings = Get-RestoreSettingsHC -ConfigurationFile $ConfigurationFile
    $configurationDescription = 'No description provided.'
    if ($ConfigurationFile) {
        $document = Get-Content -LiteralPath $ConfigurationFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($document.Description)) { $configurationDescription = $document.Description }
    }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Restore - $ConfigurationName"
    $dialog.ClientSize = New-Object Drawing.Size 800, 500
    $dialog.MinimumSize = New-Object Drawing.Size 650, 400
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = New-Object Drawing.Font 'Segoe UI', 10
    $dialog.ShowInTaskbar = $false
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding 12
    $layout.ColumnCount = 1
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle ([Windows.Forms.SizeType]::Percent), 100))
    $layout.RowCount = 6
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), 48))
    $dialog.Controls.Add($layout)
    $descriptionHeading = New-Object Windows.Forms.Label
    $descriptionHeading.Name = 'ConfigurationDescriptionHeading'
    $descriptionHeading.Text = 'Configuration description'
    $descriptionHeading.Font = New-Object Drawing.Font $dialog.Font, ([Drawing.FontStyle]::Bold)
    $descriptionHeading.AutoSize = $true
    $descriptionHeading.Dock = 'Fill'
    $descriptionHeading.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 3
    $layout.Controls.Add($descriptionHeading, 0, 0)
    $descriptionValue = New-Object Windows.Forms.Label
    $descriptionValue.Name = 'ConfigurationDescription'
    $descriptionValue.Text = $configurationDescription
    $descriptionValue.UseMnemonic = $false
    $descriptionValue.AutoSize = $true
    $descriptionValue.Dock = 'Fill'
    $descriptionValue.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $layout.Controls.Add($descriptionValue, 0, 1)
    $description = New-Object Windows.Forms.Label
    $description.Name = 'RestoreGuidance'
    $description.Text = 'Choose the sections to apply to this computer. Uncheck anything you want to leave unchanged.'
    $description.AutoSize = $true
    $description.Dock = 'Fill'
    $description.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $layout.Controls.Add($description, 0, 2)
    $list = New-SnapshotItemListHC -Entries $Entries
    $layout.Controls.Add($list, 0, 3)
    $options = New-Object Windows.Forms.FlowLayoutPanel
    $options.Dock = 'Fill'
    $options.AutoSize = $true
    $reboot = New-Object Windows.Forms.CheckBox
    $reboot.Name = 'RebootComputer'
    $reboot.Text = 'Restart computer after successful restore'
    $reboot.AutoSize = $true
    $reboot.Checked = $settings.RebootComputer
    $report = New-Object Windows.Forms.CheckBox
    $report.Name = 'OpenReportInBrowser'
    $report.Text = 'Open report in browser'
    $report.AutoSize = $true
    $report.Checked = $settings.OpenReportInBrowser
    $options.Controls.AddRange(@($reboot, $report))
    $layout.Controls.Add($options, 0, 4)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'
    $confirm = New-Object Windows.Forms.Button
    $confirm.Name = 'RestoreSelected'
    $confirm.Text = 'Restore selected'
    $confirm.Size = New-Object Drawing.Size 150, 34
    $confirm.Enabled = $list.CheckedItems.Count -gt 0
    $confirm.Add_Click({
        $owner = $this.FindForm()
        $checked = @($owner.Controls.Find('SnapshotItems', $true)[0].CheckedItems | ForEach-Object { [string]$_.Tag })
        if (-not $checked.Count) { return }
        $owner.Tag = $checked
        $owner.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object Drawing.Size 100, 34
    $cancel.DialogResult = 'Cancel'
    $dialog.CancelButton = $cancel
    $clear = New-Object Windows.Forms.Button
    $clear.Text = 'Clear all'
    $clear.Size = New-Object Drawing.Size 100, 34
    $clear.Add_Click({ foreach ($entry in $this.FindForm().Controls.Find('SnapshotItems', $true)[0].Items) { $entry.Checked = $false } })
    $all = New-Object Windows.Forms.Button
    $all.Text = 'Select all'
    $all.Size = New-Object Drawing.Size 100, 34
    $all.Add_Click({
        $availableList = $this.FindForm().Controls.Find('SnapshotItems', $true)[0]
        foreach ($entry in $availableList.Items) {
            if ($entry.Tag -notin $availableList.Tag) { $entry.Checked = $true }
        }
    })
    $buttons.Controls.AddRange(@($confirm, $cancel, $clear, $all))
    $layout.Controls.Add($buttons, 0, 5)
    $list.Add_ItemChecked({
        $owner = $this.FindForm()
        $owner.Controls.Find('RestoreSelected', $true)[0].Enabled = $this.CheckedItems.Count -gt 0
    })
    $dialog.Add_Shown({
        $this.PerformLayout()
        $itemList = $this.Controls.Find('SnapshotItems', $true)[0]
        if (-not $itemList.Items.Count) { return }
        $rowHeight = $itemList.Items[0].Bounds.Height
        $headerHeight = $itemList.Items[0].Bounds.Top
        $borderHeight = $itemList.Height - $itemList.ClientSize.Height
        $surroundingHeight = $this.Height - $itemList.Height
        $workingArea = [Windows.Forms.Screen]::FromControl($this).WorkingArea
        $minimumHeight = $surroundingHeight + $headerHeight + $borderHeight + $rowHeight * [Math]::Min(3, $itemList.Items.Count) + 2
        $this.MinimumSize = New-Object Drawing.Size $this.MinimumSize.Width, ([Math]::Min($minimumHeight, $workingArea.Height))
        $contentHeight = $surroundingHeight + $headerHeight + $borderHeight + $rowHeight * $itemList.Items.Count + 2
        $this.Height = [Math]::Min($contentHeight, $workingArea.Height)
        $this.Top = [Math]::Max($workingArea.Top, [Math]::Min($this.Top, $workingArea.Bottom - $this.Height))
    })
    return ,$dialog
}

function Start-ConfigurationJobHC {
    param(
        [ValidateSet('CreateSnapshot', 'RestoreSnapshot')][string]$Action,
        [string]$RootFolder,
        [string]$ConfigurationFile,
        [string]$Name,
        [string[]]$Items,
        [bool]$OpenReportInBrowser = $true,
        [bool]$RebootComputer = $false,
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
        if ($PSBoundParameters.ContainsKey('Items')) {
            if (-not $Items.Count) { throw 'Select at least one item.' }
            $itemArguments = ($Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
            $command += " -Items @($itemArguments)"
        }
        foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
            if ($PSBoundParameters.ContainsKey($setting)) {
                $command += " -{0} `${1}" -f $setting, $PSBoundParameters[$setting].ToString().ToLowerInvariant()
            }
        }
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
$form.ClientSize = New-Object Drawing.Size 820, 580
$form.MinimumSize = New-Object Drawing.Size 650, 480
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font 'Segoe UI', 10
$form.Icon = [Drawing.SystemIcons]::Application
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$restoreTab = New-Object Windows.Forms.TabPage 'Restore'
$exportTab = New-Object Windows.Forms.TabPage 'Export'
$tabs.TabPages.AddRange(@($restoreTab, $exportTab))
$wizardLayout = New-Object Windows.Forms.TableLayoutPanel
$wizardLayout.Dock = 'Fill'
$wizardLayout.ColumnCount = 1
$null = $wizardLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle ([Windows.Forms.SizeType]::Percent), 100))
$wizardLayout.RowCount = 2
$null = $wizardLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
$null = $wizardLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
$form.Controls.Add($wizardLayout)
$elevationPanel = New-WizardElevationPanelHC -RootFolder $RootFolder -WizardScript $PSCommandPath
if ($elevationPanel) { $wizardLayout.Controls.Add($elevationPanel, 0, 0) }
$wizardLayout.Controls.Add($tabs, 0, 1)

$restoreLayout = New-Object Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'
$restoreLayout.Padding = New-Object Windows.Forms.Padding 12
$restoreLayout.ColumnCount = 1
$null = $restoreLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle ([Windows.Forms.SizeType]::Percent), 100))
$restoreLayout.RowCount = 3
$null = $restoreLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
$null = $restoreLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
$null = $restoreLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), 48))
$restoreTab.Controls.Add($restoreLayout)
$restoreDescription = New-Object Windows.Forms.Label
$restoreDescription.Text = 'Apply a saved configuration to this computer. Select a configuration and click Restore to review and choose which sections to apply.'
$restoreDescription.AutoSize = $true
$restoreDescription.Dock = 'Fill'
$restoreDescription.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
$restoreLayout.Controls.Add($restoreDescription, 0, 0)
$configurations = New-Object Windows.Forms.ListView
$configurations.Dock = 'Fill'
$configurations.View = 'Details'
$configurations.FullRowSelect = $true
$configurations.MultiSelect = $false
$configurations.HideSelection = $false
$null = $configurations.Columns.Add('Configuration', 240)
$null = $configurations.Columns.Add('Description', 420)
$restoreLayout.Controls.Add($configurations, 0, 1)
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
$restoreLayout.Controls.Add($restoreButtons, 0, 2)
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
    try {
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $selected.Tag)
        $selection = New-RestoreSelectionFormHC -ConfigurationName $selected.Text -Entries $entries -ConfigurationFile $selected.Tag
        try {
            if ($selection.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
            $selectedItems = @($selection.Tag)
            $restoreOptions = @{
                RebootComputer = $selection.Controls.Find('RebootComputer', $true)[0].Checked
                OpenReportInBrowser = $selection.Controls.Find('OpenReportInBrowser', $true)[0].Checked
            }
        }
        finally { $selection.Dispose() }
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $RootFolder -ConfigurationFile $selected.Tag -Items $selectedItems @restoreOptions
    }
    catch { $null = [Windows.Forms.MessageBox]::Show($form, [string]$_, 'Restore error', 'OK', 'Error') }
})
$configurations.Add_DoubleClick({ $restore.PerformClick() })

$exportLayout = New-Object Windows.Forms.TableLayoutPanel
$exportLayout.Dock = 'Fill'
$exportLayout.Padding = New-Object Windows.Forms.Padding 12
$exportLayout.ColumnCount = 1
$null = $exportLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle ([Windows.Forms.SizeType]::Percent), 100))
$exportLayout.RowCount = 6
$null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize)))
foreach ($height in @(30, 38)) { $null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), $height)) }
$null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
foreach ($height in @(40, 48)) { $null = $exportLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), $height)) }
$exportTab.Controls.Add($exportLayout)
$exportDescription = New-Object Windows.Forms.Label
$exportDescription.Text = 'Save selected sections to a JSON file in Configurations. Some sections export editable templates rather than current settings; review the file before restoring it.'
$exportDescription.AutoSize = $true
$exportDescription.Dock = 'Fill'
$exportDescription.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
$exportLayout.Controls.Add($exportDescription, 0, 0)
$nameLabel = New-Object Windows.Forms.Label
$nameLabel.Text = 'Configuration name'
$nameLabel.Dock = 'Fill'
$nameBox = New-Object Windows.Forms.TextBox
$nameBox.Dock = 'Fill'
$nameBox.Text = Get-DefaultConfigurationNameHC
$itemList = New-SnapshotItemListHC -Entries @(Get-SnapshotItemEntriesHC)
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
$exportLayout.Controls.Add($nameLabel, 0, 1)
$exportLayout.Controls.Add($nameBox, 0, 2)
$exportLayout.Controls.Add($itemList, 0, 3)
$exportLayout.Controls.Add($options, 0, 4)
$exportLayout.Controls.Add($exportButtons, 0, 5)
$export.Add_Click({
    try {
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $RootFolder -Name $nameBox.Text -Items @($itemList.CheckedItems | ForEach-Object { [string]$_.Tag }) -OpenReportInBrowser $openReport.Checked -RunElevated:$elevated.Checked
    }
    catch { $null = [Windows.Forms.MessageBox]::Show($form, [string]$_, 'Export error', 'OK', 'Error') }
})
$form.Add_Shown({ $refresh.PerformClick() })
try { $null = $form.ShowDialog() }
finally { $form.Dispose() }
#endregion