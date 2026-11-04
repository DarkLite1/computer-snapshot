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
. "$PSScriptRoot\Common\RestoreInput.ps1"

#region Command construction
function Show-WizardConsoleHC {
    param(
        $ConsoleUI = $Host.UI.RawUI,
        [string]$ComputerName = [Environment]::MachineName,
        [string]$UserName = (
            '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName
        ),
        [datetime]$StartedAt = (Get-Date)
    )

    if ($null -ne $ConsoleUI) {
        try {
            $ConsoleUI.BackgroundColor = [ConsoleColor]::Black
            $ConsoleUI.ForegroundColor = [ConsoleColor]::Gray
            $ConsoleUI.WindowTitle = "Computer Snapshot | $ComputerName"
            Clear-Host
        }
        catch {
            Write-Verbose (
                'Console appearance could not be changed in this host.'
            )
        }
    }

    $art = @'

    .----------------------.   COMPUTER SNAPSHOT
    |  >_                  |   -----------------
    |     [ SNAPSHOT ]     |   Export . Restore
    |                      |
    '----------+-----------'
              _|_
             |___|

'@
    Write-Host $art -ForegroundColor Cyan -BackgroundColor Black

    $access = if (Test-ElevatedHC) {
        'Administrator'
    }
    else {
        'Standard (not elevated)'
    }
    $details = @(
        "    Hostname   : $ComputerName"
        "    Started    : $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
        "    User       : $UserName"
        "    PowerShell : $($PSVersionTable.PSVersion)"
        "    Access     : $access"
    )
    $detailsParams = @{
        Object          = $details -join [Environment]::NewLine
        ForegroundColor = 'White'
        BackgroundColor = 'Black'
    }
    Write-Host @detailsParams

    $footerParams = @{
        Object          = "`n    The wizard is open in a separate window.`n"
        ForegroundColor = 'DarkGray'
        BackgroundColor = 'Black'
    }
    Write-Host @footerParams
}

function Restart-WizardElevatedHC {
    param([string]$RootFolder, [string]$WizardScript)

    $command = "& '{0}' -RootFolder '{1}'" -f
        $WizardScript.Replace("'", "''"), $RootFolder.Replace("'", "''")
    $parameters = @{
        FilePath         = (
            "$env:WINDIR\System32\WindowsPowerShell" + '\v1.0\powershell.exe'
        )
        Verb             = 'RunAs'
        WorkingDirectory = $env:WINDIR
        ArgumentList     = @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand',
            [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($command)
            )
        )
        ErrorAction      = 'Stop'
    }

    Write-Verbose 'Restart the wizard as administrator'
    try { Start-Process @parameters }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-Verbose 'Administrator restart cancelled in the UAC prompt'
            return $false
        }
        throw
    }
    return $true
}

function New-WizardElevationPanelHC {
    param([string]$RootFolder, [string]$WizardScript)

    if (Test-ElevatedHC) {
        return
    }

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
    if (-not [Windows.Forms.SystemInformation]::HighContrast) {
        $appearance = $button.FlatAppearance
        $button.UseVisualStyleBackColor = $false
        $button.BackColor = [Drawing.Color]::FromArgb(245, 199, 92)
        $button.ForeColor = [Drawing.Color]::FromArgb(40, 35, 20)
        $button.FlatStyle = 'Flat'
        $appearance.BorderColor = [Drawing.Color]::FromArgb(164, 119, 26)
        $appearance.MouseOverBackColor =
            [Drawing.Color]::FromArgb(255, 218, 133)
        $appearance.MouseDownBackColor =
            [Drawing.Color]::FromArgb(225, 173, 58)
    }

    $shield = New-Object Drawing.Icon ([Drawing.SystemIcons]::Shield), 16, 16
    try { $button.Image = $shield.ToBitmap() }
    finally { $shield.Dispose() }
    $button.TextImageRelation = 'ImageBeforeText'
    $button.Add_Disposed({ if ($this.Image) { $this.Image.Dispose() } })
    $button.Tag = @{ RootFolder = $RootFolder; WizardScript = $WizardScript }
    $button.Add_Click({
        $owner = $this.FindForm()
        $arguments = $this.Tag
        try {
            if (Restart-WizardElevatedHC @arguments) { $owner.Close() }
        }
        catch {
            $null = [Windows.Forms.MessageBox]::Show(
                $owner, [string]$_, 'Administrator restart', 'OK', 'Error'
            )
        }
    })

    $panel.Controls.Add($button)
    return ,$panel
}

function Set-WizardPrimaryButtonHC {
    param($Button)

    if ([Windows.Forms.SystemInformation]::HighContrast) { return }

    $Button.UseVisualStyleBackColor = $false
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(0, 85, 150)
    $Button.FlatAppearance.MouseOverBackColor =
        [Drawing.Color]::FromArgb(0, 86, 153)
    $Button.FlatAppearance.MouseDownBackColor =
        [Drawing.Color]::FromArgb(0, 65, 115)
    $Button.BackColor = if ($Button.Enabled) {
        [Drawing.Color]::FromArgb(0, 103, 184)
    }
    else {
        [Drawing.SystemColors]::Control
    }
    $Button.ForeColor = if ($Button.Enabled) {
        [Drawing.Color]::White
    }
    else {
        [Drawing.SystemColors]::GrayText
    }
    $Button.Add_EnabledChanged({
        $this.BackColor = if ($this.Enabled) {
            [Drawing.Color]::FromArgb(0, 103, 184)
        }
        else {
            [Drawing.SystemColors]::Control
        }
        $this.ForeColor = if ($this.Enabled) {
            [Drawing.Color]::White
        }
        else {
            [Drawing.SystemColors]::GrayText
        }
    })
}

function Get-DefaultConfigurationNameHC {
    return $env:COMPUTERNAME + ' ' + (Get-Date -Format 'yyyy-MM-dd HHmmss')
}

function Get-WizardTaskFolderHC {
    # Comma-separated wizard input as task folders, the export default when
    # empty
    param([string]$Text)

    $folders = @(
        Get-ExportTaskFolderHC -Options @{ TaskPath = @($Text -split ',') }
    )
    foreach ($folder in $folders) {
        foreach ($name in @($folder.Split('\') | Where-Object { $_ })) {
            if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw (
                    "Task folder '$folder' contains characters that are " +
                    'not allowed in a folder name.'
                )
            }
        }
    }
    Write-Verbose "Scheduled task folders: $($folders -join ', ')"
    return $folders
}

function Show-WizardQuestionHC {
    param($Owner, [string]$Text, [string]$Caption)

    [Windows.Forms.MessageBox]::Show(
        $Owner, $Text, $Caption, 'YesNo', 'Warning', 'Button2'
    )
}

function Show-WizardErrorHC {
    param($Owner, [string]$Text, [string]$Caption)

    $null = [Windows.Forms.MessageBox]::Show(
        $Owner, $Text, $Caption, 'OK', 'Error'
    )
}

function Get-WizardRestoreQuestionsHC {
    <#
    .SYNOPSIS
        The questions of the checked sections that the answer file does not
        answer.
    .DESCRIPTION
        Throws the problems of the configuration first, so they are fixed
        before anybody types an answer.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigurationFile,
        [Parameter(Mandatory)][string]$RootFolder,
        [Parameter(Mandatory)][string[]]$Items,
        [string]$AnswerFile
    )

    if (-not (Get-Command Read-ConfigurationHC -ErrorAction Ignore)) {
        Import-Module "$PSScriptRoot\Common\Configuration.psm1"
    }

    $readParams = @{
        Path       = $ConfigurationFile
        RootFolder = $RootFolder
        Items      = $Items
    }
    $configuration = Read-ConfigurationHC @readParams
    $problems = @($configuration.Problems)

    if (-not $problems.Count) {
        $problems = @(
            Test-ConfigurationBeforeInputHC $configuration $RootFolder
        )
    }

    if ($problems.Count) {
        throw (
            'Fix these problems in the configuration first:' +
            [Environment]::NewLine + ($problems -join [Environment]::NewLine)
        )
    }

    $answers = $null

    if (-not [string]::IsNullOrWhiteSpace($AnswerFile)) {
        $answerPath = Resolve-RootPathHC $AnswerFile $RootFolder
        $answers = Read-RestoreAnswerFileHC -Path $answerPath
    }

    $fileParams = @{
        Items      = $configuration.Items
        RootFolder = $RootFolder
    }
    $fields = @(Get-RestoreInputFieldsHC -Data $configuration.Items) +
        @(Get-FileInputFieldsHC @fileParams)

    Get-RestoreInputQuestionHC -Fields $fields -Answers $answers
}

function Show-RestoreSelectionPageHC {
    <#
    .SYNOPSIS
        Show the section checklist or the questions page of the restore
        window, with the buttons that belong to it.
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [switch]$Questions
    )

    $find = { param($name) $Form.Controls.Find($name, $true)[0] }

    (& $find 'SelectionPage').Visible = -not $Questions
    (& $find 'QuestionsPage').Visible = [bool]$Questions

    foreach ($name in @('RestoreSelected', 'ClearAll', 'SelectAll')) {
        (& $find $name).Visible = -not $Questions
    }
    foreach ($name in @('RestoreWithAnswers', 'BackToSelection')) {
        (& $find $name).Visible = [bool]$Questions
    }

    if ($Questions) {
        $Form.AcceptButton = & $find 'RestoreWithAnswers'
        $inputs = (& $find 'QuestionsPage').Tag.Panel.Tag.Inputs
        if ($inputs.Count) {
            $Form.ActiveControl = $inputs[0]
        }
    }
    else {
        $Form.AcceptButton = $null
        $Form.ActiveControl = & $find 'SnapshotItems'
    }
}

function Show-RestoreQuestionsHC {
    <#
    .SYNOPSIS
        Fill the questions page of the restore window and show it. Answers
        typed earlier are kept for the questions that are still asked.
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [Parameter(Mandatory)][object[]]$Questions
    )

    $page = $Form.Controls.Find('QuestionsPage', $true)[0]
    $state = $page.Tag
    $earlier = $null

    if ($null -ne $state.Panel) {
        $earlier = Get-RestoreInputPanelValuesHC -Panel $state.Panel
        Clear-RestoreInputPanelHC -Panel $state.Panel
        $page.Controls.Remove($state.Panel)
        $state.Panel.Dispose()
    }

    $panelParams = @{
        Questions    = $Questions
        Values       = $earlier
        Font         = $Form.Font
        Introduction = (
            'Answer the questions of the checked sections. Nothing is ' +
            'changed before you click Restore. Click Back to change the ' +
            'selection; your answers are kept.'
        )
    }
    $panel = New-RestoreInputPanelHC @panelParams
    $panel.Tag.Confirm = $Form.Controls.Find('RestoreWithAnswers', $true)[0]
    $page.Controls.Add($panel)
    $state.Panel = $panel
    Update-RestoreInputPanelHC -Panel $panel

    if ($null -ne $earlier) {
        $earlier.Clear()
    }

    Show-RestoreSelectionPageHC -Form $Form -Questions
}

function Get-RestoreSelectionAnswersHC {
    # The answers of the questions page, or nothing when none were asked
    param(
        [Parameter(Mandatory)]$Form
    )

    $Form.Controls.Find('QuestionsPage', $true)[0].Tag.Answers
}

function Confirm-WizardTaskFolderHC {
    param([string[]]$Folders, $Owner)

    if ($Folders -notcontains '\') { return $true }

    Write-Verbose "Task folder '\' selected: ask for confirmation"
    $text = 'The task folder \ exports every scheduled task on this ' +
        'computer, including the hundreds of tasks that Windows itself ' +
        'uses. ' +
        'Restoring those on another computer can break it.' +
        [Environment]::NewLine + [Environment]::NewLine +
        'Export all scheduled tasks anyway?'
    $questionParams = @{
        Owner   = $Owner
        Text    = $text
        Caption = 'Export all scheduled tasks'
    }
    return (Show-WizardQuestionHC @questionParams) -eq
        [Windows.Forms.DialogResult]::Yes
}

function Get-ConfigurationEntriesHC {
    param([string]$RootFolder)

    $folder = Join-Path $RootFolder 'Configurations'
    Write-Verbose "Get configurations in '$folder'"
    $listParams = @{
        LiteralPath = $folder
        Filter      = '*.json'
        File        = $true
        ErrorAction = 'Stop'
    }
    $files = Get-ChildItem @listParams |
        Where-Object { $_.Name -notlike '*.v1.json' }
    foreach ($file in $files) {
        try {
            $readParams = @{
                LiteralPath = $file.FullName
                Raw         = $true
                Encoding    = 'UTF8'
            }
            $document = Get-Content @readParams |
                ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Verbose "Configuration '$($file.Name)': invalid JSON"
            $document = @{ Description = 'Invalid JSON' }
        }
        [pscustomobject]@{
            Name        = $file.BaseName
            Description = $document.Description
            Path        = $file.FullName
        }
    }
}

function Get-SnapshotItemEntriesHC {
    param([string[]]$Items)

    $labels = @{
        StartCustomScriptsBefore = @(
            'Custom scripts (before restore)',
            'Run custom scripts before the other sections.'
        )
        RegionalSettings         = @(
            'Regional settings',
            'Language, culture, home location and time zone.'
        )
        UserAccounts             = @(
            'User accounts',
            'Local user accounts to create, update or remove.'
        )
        UserGroups               = @(
            'User groups',
            'Local groups and group membership.'
        )
        FirewallRules            = @(
            'Firewall rules',
            'Windows Firewall rules and their settings.'
        )
        CreateFolders            = @(
            'Create folders',
            'Folder paths to create on the computer.'
        )
        SmbShares                = @(
            'Shared folders (SMB)',
            'Network shares, share access and NTFS permissions.'
        )
        NetworkCards             = @(
            'Network adapters',
            'Network adapter, IP address and DNS settings.'
        )
        NtpTimeServers           = @(
            'Time synchronization',
            'Domain time synchronization or NTP time servers.'
        )
        HostsFileEntries         = @(
            'Hosts file',
            'Host names and the IP addresses they point to.'
        )
        RegistryKeys             = @(
            'Registry keys',
            'Registry keys and values to apply.'
        )
        ScheduledTasks           = @(
            'Scheduled tasks',
            'Task definitions and enabled states.'
        )
        CopyFilesFolders         = @(
            'Copy files and folders',
            'Source and destination paths for file copies.'
        )
        Software                 = @(
            'Software',
            'Applications to install or remove.'
        )
        StartCustomScriptsAfter  = @(
            'Custom scripts (after restore)',
            'Run custom scripts after the other sections.'
        )
    }

    foreach ($name in (Get-SnapshotScriptsHC).Keys) {
        if ($null -ne $Items -and $name -notin $Items) { continue }
        [pscustomobject]@{
            Key         = $name
            Name        = $labels[$name][0]
            Description = $labels[$name][1]
            Available   = $true
        }
    }
}

function Get-RestoreItemEntriesHC {
    param([string]$ConfigurationFile)

    Write-Verbose "Get restore items from '$ConfigurationFile'"
    $readParams = @{
        LiteralPath = $ConfigurationFile
        Raw         = $true
        Encoding    = 'UTF8'
        ErrorAction = 'Stop'
    }
    $document = Get-Content @readParams | ConvertFrom-Json -ErrorAction Stop

    if (
        $document.SchemaVersion -ne 3 -or
        $document.SchemaVersion -is [string]
    ) {
        throw (
            'Select a version-3 configuration; run the configuration ' +
            'converter (Scripts\Convert configuration.ps1) for older ' +
            'configurations first.'
        )
    }
    if ($document.Items -isnot [pscustomobject]) {
        throw 'The configuration must contain an Items object.'
    }

    $names = @(
        $document.Items.PSObject.Properties |
        Where-Object { $_.Name -cne 'Comment' } |
        ForEach-Object { $_.Name }
    )
    if (-not $names.Count) {
        throw 'The configuration contains no items to restore.'
    }
    foreach ($name in $names) {
        if ($name -cnotin (Get-SnapshotScriptsHC).Keys) {
            throw "Unknown configuration item '$name'."
        }
    }

    foreach ($entry in Get-SnapshotItemEntriesHC) {
        $data = $document.Items.($entry.Key)
        $entry.Available = $entry.Key -in $names -and
            -not (Test-EmptySectionHC $data)
        if ($data -is [string]) {
            $entry.Available = -not [string]::IsNullOrWhiteSpace($data)
        }
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
    # Keys of sections without data, these can not be checked
    $list.Tag = @(
        $Entries |
        Where-Object { $_.Available -eq $false } |
        ForEach-Object { $_.Key }
    )
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
        if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left) {
            return
        }
        $hit = $sender.HitTest($eventArgs.Location)
        $stateImage = [Windows.Forms.ListViewHitTestLocations]::StateImage
        if ($hit.Item -and $hit.Item.Tag -notin $sender.Tag -and
            -not ($hit.Location -band $stateImage)) {
            $hit.Item.Checked = -not $hit.Item.Checked
        }
    })
    return ,$list
}

function Get-RestoreSettingsHC {
    param([string]$ConfigurationFile)

    $settings = @{
        RebootComputer      = $false
        RestartDelaySeconds = 60
        OpenReportInBrowser = $true
    }
    if ($ConfigurationFile) {
        Write-Verbose "Get restore settings from '$ConfigurationFile'"
        $readParams = @{
            LiteralPath = $ConfigurationFile
            Raw         = $true
            Encoding    = 'UTF8'
            ErrorAction = 'Stop'
        }
        $document = Get-Content @readParams |
            ConvertFrom-Json -ErrorAction Stop
        $names = $document.Settings.PSObject.Properties.Name

        foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
            if ($names -contains $setting) {
                if ($document.Settings.$setting -isnot [bool]) {
                    throw "Settings.${setting} must be a Boolean."
                }
                $settings[$setting] = $document.Settings.$setting
            }
        }

        if ($names -contains 'RestartDelaySeconds') {
            $delay = $document.Settings.RestartDelaySeconds
            if (
                ($delay -isnot [int] -and $delay -isnot [long]) -or
                $delay -lt 0 -or $delay -gt 600
            ) {
                throw (
                    'Settings.RestartDelaySeconds must be a whole number ' +
                    'from 0 to 600.'
                )
            }
            $settings.RestartDelaySeconds = [int]$delay
        }
    }
    return $settings
}

function New-RestoreAnswersPanelHC {
    param([string]$ConfigurationFile, [string]$RootFolder)

    $sizeType = [Windows.Forms.SizeType]
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Name = 'RestoreAnswers'
    $panel.Dock = 'Fill'
    $panel.AutoSize = $true
    $panel.ColumnCount = 3
    $panel.RowCount = 4
    $null = $panel.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    $null = $panel.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Absolute, 100)
    )
    $null = $panel.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Absolute, 150)
    )
    foreach ($row in 0..3) {
        $null = $panel.RowStyles.Add(
            (New-Object Windows.Forms.RowStyle $sizeType::AutoSize)
        )
    }

    $label = New-Object Windows.Forms.Label
    $label.Text = 'Answer file (optional JSON):'
    $label.AutoSize = $true
    $label.Dock = 'Fill'
    $panel.Controls.Add($label, 0, 0)
    $panel.SetColumnSpan($label, 3)

    $path = New-Object Windows.Forms.TextBox
    $path.Name = 'AnswerFile'
    $path.AccessibleName = 'Answer file path'
    $path.Dock = 'Fill'
    $panel.Controls.Add($path, 0, 1)

    #region Browse for an answer file
    $browse = New-Object Windows.Forms.Button
    $browse.Name = 'BrowseAnswerFile'
    $browse.Text = 'Browse...'
    $browse.Dock = 'Fill'
    $browse.Tag = $RootFolder
    $browse.Add_Click({
        $picker = New-Object Windows.Forms.OpenFileDialog
        try {
            $picker.Filter = 'JSON answer files (*.json)|*.json'
            $picker.InitialDirectory = $this.Tag
            $result = $picker.ShowDialog($this.FindForm())
            if ($result -eq [Windows.Forms.DialogResult]::OK) {
                $answerBox = $this.Parent.Controls.Find('AnswerFile', $true)[0]
                $answerBox.Text = $picker.FileName
            }
        }
        finally { $picker.Dispose() }
    })
    $panel.Controls.Add($browse, 1, 1)
    #endregion

    #region Create an answer file template
    $create = New-Object Windows.Forms.Button
    $create.Name = 'CreateAnswerTemplate'
    $create.Text = 'Create template...'
    $create.Dock = 'Fill'
    $create.Enabled = -not [string]::IsNullOrWhiteSpace($ConfigurationFile)
    $create.Tag = @{
        ConfigurationFile = $ConfigurationFile
        RootFolder        = $RootFolder
    }
    $create.Add_Click({
        $owner = $this.FindForm()
        $selected = @(
            $owner.Controls.Find('SnapshotItems', $true)[0].CheckedItems |
            ForEach-Object { [string]$_.Tag }
        )
        $picker = New-Object Windows.Forms.SaveFileDialog
        try {
            if (-not $selected.Count) {
                throw (
                    'Select at least one section before creating an ' +
                    'answer template.'
                )
            }
            $picker.Filter = 'JSON answer files (*.json)|*.json'
            $picker.InitialDirectory = $this.Tag.RootFolder
            $picker.FileName = [IO.Path]::GetFileNameWithoutExtension(
                $this.Tag.ConfigurationFile
            ) + '.answers.json'
            $picker.OverwritePrompt = $true
            if (
                $picker.ShowDialog($owner) -ne
                [Windows.Forms.DialogResult]::OK
            ) {
                return
            }

            Import-Module "$PSScriptRoot\Common\Configuration.psm1" -Force
            $arguments = $this.Tag
            Write-Verbose "Create answer template '$($picker.FileName)'"
            $templateParams = @{
                AnswerFile = $picker.FileName
                Items      = $selected
                Force      = $true
            }
            $answerPath = New-RestoreAnswerFileHC @arguments @templateParams
            $this.Parent.Controls.Find('AnswerFile', $true)[0].Text =
                $answerPath
            $message = 'Template created. Edit its null values in a text ' +
                'editor before restoring. Password answers are plain text; ' +
                'protect this file.'
            $null = [Windows.Forms.MessageBox]::Show(
                $owner, $message, 'Answer template', 'OK', 'Information'
            )
        }
        catch {
            $null = [Windows.Forms.MessageBox]::Show(
                $owner, [string]$_, 'Answer template error', 'OK', 'Error'
            )
        }
        finally { $picker.Dispose() }
    })
    $panel.Controls.Add($create, 2, 1)
    #endregion

    #region Unattended restore
    $unattended = New-Object Windows.Forms.CheckBox
    $unattended.Name = 'Unattended'
    $unattended.Text = 'Unattended: fail on missing answers (no prompts)'
    $unattended.AutoSize = $true
    $unattended.Add_CheckedChanged({
        # Unattended never opens the browser; restore the old choice after
        $report = $this.FindForm().Controls.Find(
            'OpenReportInBrowser', $true
        )[0]
        if ($this.Checked) {
            $report.Tag = $report.Checked
            $report.Checked = $false
        }
        else { $report.Checked = [bool]$report.Tag }
        $report.Enabled = -not $this.Checked
    })
    $panel.Controls.Add($unattended, 0, 2)
    $panel.SetColumnSpan($unattended, 3)
    #endregion

    $hint = New-Object Windows.Forms.Label
    $hint.Name = 'AnswerFileGuidance'
    $hint.Text = (
        'Missing answers prompt unless Unattended is checked. Invalid ' +
        'answers always fail. Unattended needs the wizard to run as ' +
        'administrator, disables browser opening and will not request ' +
        'UAC. Password answers are plain text.'
    )
    $hint.AutoSize = $true
    $hint.Dock = 'Fill'
    $hint.Font = New-Object Drawing.Font 'Segoe UI', 9
    $panel.Controls.Add($hint, 0, 3)
    $panel.SetColumnSpan($hint, 3)

    return ,$panel
}

function New-RestoreSelectionFormHC {
    param(
        [string]$ConfigurationName,
        [object[]]$Entries,
        [string]$ConfigurationFile,
        [string]$RootFolder = (Split-Path $PSScriptRoot -Parent)
    )

    $settings = Get-RestoreSettingsHC -ConfigurationFile $ConfigurationFile
    $configurationDescription = 'No description provided.'
    if ($ConfigurationFile) {
        $readParams = @{
            LiteralPath = $ConfigurationFile
            Raw         = $true
            Encoding    = 'UTF8'
            ErrorAction = 'Stop'
        }
        $document = Get-Content @readParams |
            ConvertFrom-Json -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($document.Description)) {
            $configurationDescription = $document.Description
        }
    }

    $sizeType = [Windows.Forms.SizeType]
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Restore - $ConfigurationName"
    $dialog.ClientSize = New-Object Drawing.Size 800, 650
    $dialog.MinimumSize = New-Object Drawing.Size 650, 550
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = New-Object Drawing.Font 'Segoe UI', 10
    $dialog.ShowInTaskbar = $false

    # Rows: the page, buttons. The pages are the section checklist and the
    # questions of the checked sections
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding 12
    $layout.ColumnCount = 1
    $null = $layout.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    $layout.RowCount = 2
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
    )
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Absolute, 48)
    )
    $dialog.Controls.Add($layout)

    $pages = New-Object Windows.Forms.Panel
    $pages.Dock = 'Fill'
    $pages.Margin = New-Object Windows.Forms.Padding 0
    $layout.Controls.Add($pages, 0, 0)

    $questionsPage = New-Object Windows.Forms.Panel
    $questionsPage.Name = 'QuestionsPage'
    $questionsPage.Dock = 'Fill'
    $questionsPage.Visible = $false
    $questionsPage.Tag = @{
        ConfigurationFile = $ConfigurationFile
        RootFolder        = $RootFolder
        Panel             = $null
        Answers           = $null
    }
    $pages.Controls.Add($questionsPage)

    # Rows: description, guidance, sections, answer file, options
    $selectionPage = New-Object Windows.Forms.TableLayoutPanel
    $selectionPage.Name = 'SelectionPage'
    $selectionPage.Dock = 'Fill'
    $selectionPage.ColumnCount = 1
    $null = $selectionPage.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    $selectionPage.RowCount = 5
    $rows = $selectionPage.RowStyles
    $null = $rows.Add((New-Object Windows.Forms.RowStyle $sizeType::AutoSize))
    $null = $rows.Add((New-Object Windows.Forms.RowStyle $sizeType::AutoSize))
    $null = $rows.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
    )
    $null = $rows.Add((New-Object Windows.Forms.RowStyle $sizeType::AutoSize))
    $null = $rows.Add((New-Object Windows.Forms.RowStyle $sizeType::AutoSize))
    $pages.Controls.Add($selectionPage)

    $descriptionValue = New-Object Windows.Forms.Label
    $descriptionValue.Name = 'ConfigurationDescription'
    $descriptionValue.AccessibleName = 'Configuration description'
    $descriptionValue.Text = $configurationDescription
    $descriptionValue.BorderStyle = 'FixedSingle'
    $descriptionValue.Padding = New-Object Windows.Forms.Padding 10
    $descriptionValue.BackColor = [Drawing.SystemColors]::Window
    $descriptionValue.ForeColor = [Drawing.SystemColors]::WindowText
    $descriptionValue.UseMnemonic = $false
    $descriptionValue.AutoSize = $true
    $descriptionValue.Dock = 'Fill'
    $descriptionValue.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $selectionPage.Controls.Add($descriptionValue, 0, 0)

    $description = New-Object Windows.Forms.Label
    $description.Name = 'RestoreGuidance'
    $description.Text = (
        'Choose the sections to apply to this computer. ' +
        'Uncheck anything you want to leave unchanged.'
    )
    $description.Font = New-Object Drawing.Font $dialog.Font.FontFamily, 9
    $description.AutoSize = $true
    $description.Dock = 'Fill'
    $description.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $selectionPage.Controls.Add($description, 0, 1)

    $list = New-SnapshotItemListHC -Entries $Entries
    $selectionPage.Controls.Add($list, 0, 2)

    $answerParams = @{
        ConfigurationFile = $ConfigurationFile
        RootFolder        = $RootFolder
    }
    $answerPanel = New-RestoreAnswersPanelHC @answerParams
    $selectionPage.Controls.Add($answerPanel, 0, 3)

    #region Restart and report options
    $options = New-Object Windows.Forms.FlowLayoutPanel
    $options.Dock = 'Fill'
    $options.AutoSize = $true

    $reboot = New-Object Windows.Forms.CheckBox
    $reboot.Name = 'RebootComputer'
    $reboot.Text = 'Restart computer after successful restore'
    $reboot.AutoSize = $true
    $reboot.Checked = $settings.RebootComputer

    $delayLabel = New-Object Windows.Forms.Label
    $delayLabel.Name = 'RestartDelayLabel'
    $delayLabel.Text = 'Countdown (seconds):'
    $delayLabel.AutoSize = $true
    $delayLabel.Margin = New-Object Windows.Forms.Padding 0, 6, 0, 0
    $delayLabel.Enabled = $reboot.Checked

    $delay = New-Object Windows.Forms.NumericUpDown
    $delay.Name = 'RestartDelaySeconds'
    $delay.AccessibleName = 'Restart countdown in seconds'
    $delay.Minimum = 0
    $delay.Maximum = 600
    $delay.Increment = 10
    $delay.Width = 70
    $delay.Value = $settings.RestartDelaySeconds
    $delay.Enabled = $reboot.Checked
    $delay.Margin = New-Object Windows.Forms.Padding 3, 3, 18, 3

    $reboot.Add_CheckedChanged({
        foreach ($name in @('RestartDelayLabel', 'RestartDelaySeconds')) {
            $this.Parent.Controls.Find($name, $false)[0].Enabled =
                $this.Checked
        }
    })

    $report = New-Object Windows.Forms.CheckBox
    $report.Name = 'OpenReportInBrowser'
    $report.Text = 'Open report in browser'
    $report.AutoSize = $true
    $report.Checked = $settings.OpenReportInBrowser

    $options.Controls.AddRange(@($reboot, $delayLabel, $delay, $report))
    $selectionPage.Controls.Add($options, 0, 4)
    #endregion

    #region Buttons
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'

    $confirm = New-Object Windows.Forms.Button
    $confirm.Name = 'RestoreSelected'
    $confirm.Text = 'Restore selected'
    $confirm.Size = New-Object Drawing.Size 150, 34
    Set-WizardPrimaryButtonHC $confirm
    $confirm.Enabled = $list.CheckedItems.Count -gt 0
    $confirm.Add_Click({
        $owner = $this.FindForm()
        $checked = @(
            $owner.Controls.Find('SnapshotItems', $true)[0].CheckedItems |
            ForEach-Object { [string]$_.Tag }
        )
        if (-not $checked.Count) {
            return
        }

        $state = $owner.Controls.Find('QuestionsPage', $true)[0].Tag
        $unattended = $owner.Controls.Find('Unattended', $true)[0].Checked
        $questions = @()

        # An unattended restore takes every answer from the answer file
        if ($state.ConfigurationFile -and -not $unattended) {
            try {
                $questionParams = @{
                    ConfigurationFile = $state.ConfigurationFile
                    RootFolder        = $state.RootFolder
                    Items             = $checked
                    AnswerFile        =
                        $owner.Controls.Find('AnswerFile', $true)[0].Text
                }
                $questions = @(Get-WizardRestoreQuestionsHC @questionParams)
            }
            catch {
                $errorParams = @{
                    Owner   = $owner
                    Text    = [string]$_
                    Caption = 'Restore error'
                }
                Show-WizardErrorHC @errorParams
                return
            }
        }

        $owner.Tag = $checked
        $state.Answers = $null

        if ($questions.Count) {
            Show-RestoreQuestionsHC -Form $owner -Questions $questions
            return
        }

        $owner.DialogResult = [Windows.Forms.DialogResult]::OK
    })

    $restoreAnswers = New-Object Windows.Forms.Button
    $restoreAnswers.Name = 'RestoreWithAnswers'
    $restoreAnswers.Text = 'Restore'
    $restoreAnswers.Size = New-Object Drawing.Size 150, 34
    $restoreAnswers.Visible = $false
    Set-WizardPrimaryButtonHC $restoreAnswers
    $restoreAnswers.Add_Click({
        $owner = $this.FindForm()
        $state = $owner.Controls.Find('QuestionsPage', $true)[0].Tag
        Update-RestoreInputPanelHC -Panel $state.Panel
        if (-not $this.Enabled) {
            return
        }

        $state.Answers = Get-RestoreInputPanelValuesHC -Panel $state.Panel
        $owner.DialogResult = [Windows.Forms.DialogResult]::OK
    })

    $back = New-Object Windows.Forms.Button
    $back.Name = 'BackToSelection'
    $back.Text = '< Back'
    $back.Size = New-Object Drawing.Size 100, 34
    $back.Visible = $false
    $back.Add_Click({
        Show-RestoreSelectionPageHC -Form $this.FindForm()
    })

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object Drawing.Size 100, 34
    $cancel.DialogResult = 'Cancel'
    $dialog.CancelButton = $cancel

    $clear = New-Object Windows.Forms.Button
    $clear.Name = 'ClearAll'
    $clear.Text = 'Clear all'
    $clear.Size = New-Object Drawing.Size 100, 34
    $clear.Add_Click({
        $itemList = $this.FindForm().Controls.Find('SnapshotItems', $true)[0]
        foreach ($entry in $itemList.Items) { $entry.Checked = $false }
    })

    $all = New-Object Windows.Forms.Button
    $all.Name = 'SelectAll'
    $all.Text = 'Select all'
    $all.Size = New-Object Drawing.Size 100, 34
    $all.Add_Click({
        $availableList = $this.FindForm().Controls.Find(
            'SnapshotItems', $true
        )[0]
        foreach ($entry in $availableList.Items) {
            if ($entry.Tag -notin $availableList.Tag) { $entry.Checked = $true }
        }
    })

    $buttons.Controls.AddRange(
        @($confirm, $restoreAnswers, $cancel, $back, $clear, $all)
    )
    $layout.Controls.Add($buttons, 0, 1)
    #endregion

    # Forget typed answers, passwords included, when the window closes
    $dialog.Add_FormClosed({
        $state = $this.Controls.Find('QuestionsPage', $true)[0].Tag
        if ($null -ne $state.Panel) {
            Clear-RestoreInputPanelHC -Panel $state.Panel
        }
    })

    $list.Add_ItemChecked({
        $owner = $this.FindForm()
        $owner.Controls.Find('RestoreSelected', $true)[0].Enabled =
            $this.CheckedItems.Count -gt 0
    })

    # Size the dialog to show all sections, at least 3, within the screen
    $dialog.Add_Shown({
        $this.PerformLayout()
        $itemList = $this.Controls.Find('SnapshotItems', $true)[0]
        if (-not $itemList.Items.Count) { return }
        $rowHeight = $itemList.Items[0].Bounds.Height
        $headerHeight = $itemList.Items[0].Bounds.Top
        $borderHeight = $itemList.Height - $itemList.ClientSize.Height
        $surroundingHeight = $this.Height - $itemList.Height
        $workingArea = [Windows.Forms.Screen]::FromControl($this).WorkingArea
        $minimumHeight = $surroundingHeight + $headerHeight + $borderHeight +
            $rowHeight * [Math]::Min(3, $itemList.Items.Count) + 2
        $this.MinimumSize = New-Object Drawing.Size $this.MinimumSize.Width, (
            [Math]::Min($minimumHeight, $workingArea.Height)
        )
        $contentHeight = $surroundingHeight + $headerHeight + $borderHeight +
            $rowHeight * $itemList.Items.Count + 2
        $this.Height = [Math]::Min($contentHeight, $workingArea.Height)
        $this.Top = [Math]::Max(
            $workingArea.Top,
            [Math]::Min($this.Top, $workingArea.Bottom - $this.Height)
        )
    })
    return ,$dialog
}

function New-ExportTaskFolderPanelHC {
    param($ItemList)

    $panel = New-Object Windows.Forms.FlowLayoutPanel
    $panel.Name = 'ScheduledTaskFolderPanel'
    $panel.Dock = 'Fill'
    $panel.WrapContents = $false

    $label = New-Object Windows.Forms.Label
    $label.Name = 'ScheduledTaskFoldersLabel'
    $label.Text = 'Scheduled task folders:'
    $label.AutoSize = $true
    $label.Margin = New-Object Windows.Forms.Padding 0, 6, 3, 0

    $box = New-Object Windows.Forms.TextBox
    $box.Name = 'ScheduledTaskFolders'
    $box.AccessibleName = 'Scheduled task folders, separated by commas'
    $box.Width = 240
    $box.Text = (Get-ExportTaskFolderHC) -join ', '

    $hint = New-Object Windows.Forms.Label
    $hint.Name = 'ScheduledTaskFoldersHint'
    $hint.Text = 'with subfolders; separate with commas'
    $hint.Font = New-Object Drawing.Font $box.Font.FontFamily, 9
    $hint.ForeColor = [Drawing.SystemColors]::GrayText
    $hint.AutoSize = $true
    $hint.Margin = New-Object Windows.Forms.Padding 3, 7, 0, 0

    $panel.Controls.AddRange(@($label, $box, $hint))

    # Only enable the folder input while ScheduledTasks is checked
    $folderControls = @($label, $box, $hint)
    $isChecked = @(
        $ItemList.Items |
        Where-Object { $_.Tag -eq 'ScheduledTasks' -and $_.Checked }
    ).Count -gt 0
    foreach ($control in $folderControls) { $control.Enabled = $isChecked }
    $ItemList.Add_ItemChecked({
        param($sender, $eventArgs)
        if ($eventArgs.Item.Tag -ne 'ScheduledTasks') { return }
        foreach ($control in $folderControls) {
            $control.Enabled = $eventArgs.Item.Checked
        }
    }.GetNewClosure())
    return ,$panel
}

function Start-ConfigurationJobHC {
    param(
        [ValidateSet('CreateSnapshot', 'RestoreSnapshot')][string]$Action,
        [string]$RootFolder,
        [string]$ConfigurationFile,
        [string]$Name,
        [string[]]$Items,
        [string[]]$TaskFolders,
        [bool]$OpenReportInBrowser = $true,
        [bool]$RebootComputer = $false,
        [ValidateRange(0, 600)]
        [int]$RestartDelaySeconds = 60,
        [string]$AnswerFile,
        # The named pipe on which the wizard serves the answers of its
        # questions page
        [string]$AnswerPipe,
        [switch]$Unattended,
        [switch]$RunElevated,
        [switch]$Force
    )

    if ($Action -eq 'CreateSnapshot') {
        #region Build the export command
        if ($AnswerFile -or $AnswerPipe -or $Unattended) {
            throw (
                'AnswerFile, AnswerPipe and Unattended are restore-only ' +
                'options.'
            )
        }
        if (
            [string]::IsNullOrWhiteSpace($Name) -or
            $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $Name -in @('.', '..')
        ) {
            throw (
                'Enter a configuration file name without directory ' +
                'separators or invalid filename characters.'
            )
        }
        if (-not $Items.Count) { throw 'Select at least one item.' }

        $fileName = if (
            $Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)
        ) {
            $Name
        }
        else {
            $Name + '.json'
        }
        $ConfigurationFile = Join-Path (
            Join-Path $RootFolder 'Configurations'
        ) $fileName
        if ((Test-Path -LiteralPath $ConfigurationFile) -and -not $Force) {
            throw "Configuration '$fileName' already exists."
        }

        Write-Verbose "Export items '$($Items -join ', ')' to '$fileName'"
        $script = Join-Path $RootFolder 'Scripts\Invoke scripts.ps1'
        $itemArguments = (
            $Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
        ) -join ','
        $format = (
            "& '{0}' -Action CreateSnapshot -ConfigurationFile '{1}'" +
            " -Items @({2}) -OpenReportInBrowser `${3}"
        )
        $command = $format -f $script.Replace("'", "''"),
            $ConfigurationFile.Replace("'", "''"), $itemArguments,
            $OpenReportInBrowser.ToString().ToLowerInvariant()
        if ($TaskFolders.Count -and 'ScheduledTasks' -in $Items) {
            $folderArguments = (
                $TaskFolders |
                ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
            ) -join ','
            $command += ' -ExportOptions @{ ScheduledTasks = @{ TaskPath = @(' +
                $folderArguments + ') } }'
        }
        if ($Force) { $command += ' -Force' }
        #endregion
    }
    else {
        #region Build the restore command
        if (-not (Test-Path -LiteralPath $ConfigurationFile -PathType Leaf)) {
            throw 'Select an existing configuration file.'
        }

        Write-Verbose "Restore configuration '$ConfigurationFile'"
        $script = Join-Path $RootFolder 'Scripts\Invoke configuration.ps1'
        $command = "& '{0}' -ConfigurationFile '{1}' -SkipConfirmation" -f
            $script.Replace("'", "''"), $ConfigurationFile.Replace("'", "''")
        if ($PSBoundParameters.ContainsKey('Items')) {
            if (-not $Items.Count) { throw 'Select at least one item.' }
            $itemArguments = (
                $Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
            ) -join ','
            $command += " -Items @($itemArguments)"
        }
        foreach ($setting in @('RebootComputer', 'OpenReportInBrowser')) {
            if ($PSBoundParameters.ContainsKey($setting)) {
                $command += " -{0} `${1}" -f $setting,
                    $PSBoundParameters[$setting].ToString().ToLowerInvariant()
            }
        }
        if ($PSBoundParameters.ContainsKey('RestartDelaySeconds')) {
            $command += " -RestartDelaySeconds $RestartDelaySeconds"
        }
        if (-not [string]::IsNullOrWhiteSpace($AnswerFile)) {
            $answerPath = Resolve-RootPathHC $AnswerFile $RootFolder
            if (-not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
                throw "Answer file '$answerPath' not found."
            }
            $command += " -AnswerFile '" + $answerPath.Replace("'", "''") + "'"
        }
        if (-not [string]::IsNullOrWhiteSpace($AnswerPipe)) {
            $command += " -AnswerPipe '" + $AnswerPipe.Replace("'", "''") + "'"
        }
        if ($Unattended) {
            $command += ' -Unattended'
            if (-not (Test-ElevatedHC)) {
                throw (
                    'Unattended restore requires administrator rights. ' +
                    'Restart the wizard as administrator first.'
                )
            }
        }
        #endregion
    }

    $parameters = @{
        FilePath     = 'powershell.exe'
        ArgumentList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
            [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($command)
            )
        )
    }
    if ($Unattended) {
        $parameters.ArgumentList = @('-NonInteractive') +
            $parameters.ArgumentList
    }
    if ($RunElevated -and -not $Unattended) {
        Write-Verbose 'Run the job as administrator'
        $parameters.Verb = 'RunAs'
    }

    Write-Verbose "Start a new PowerShell process for '$Action'"
    Start-Process @parameters
}
#endregion

if ($NoShow) {
    Write-Verbose 'NoShow: functions loaded, the wizard is not displayed'
    return
}

Show-WizardConsoleHC
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

#region Native Windows interface
Write-Verbose 'Build the wizard window'
$sizeType = [Windows.Forms.SizeType]

$form = New-Object Windows.Forms.Form
$form.Text = 'Computer Snapshot'
# Answer servers of restores that were started from this window
$answerServers = New-Object 'System.Collections.Generic.List[object]'
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
$null = $wizardLayout.ColumnStyles.Add(
    (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
)
$wizardLayout.RowCount = 2
$null = $wizardLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::AutoSize)
)
$null = $wizardLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
)
$form.Controls.Add($wizardLayout)

$elevationParams = @{
    RootFolder   = $RootFolder
    WizardScript = $PSCommandPath
}
$elevationPanel = New-WizardElevationPanelHC @elevationParams
if ($elevationPanel) { $wizardLayout.Controls.Add($elevationPanel, 0, 0) }
$wizardLayout.Controls.Add($tabs, 0, 1)

#region Restore tab
$restoreLayout = New-Object Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'
$restoreLayout.Padding = New-Object Windows.Forms.Padding 12
$restoreLayout.ColumnCount = 1
$null = $restoreLayout.ColumnStyles.Add(
    (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
)
$restoreLayout.RowCount = 3
$null = $restoreLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::AutoSize)
)
$null = $restoreLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
)
$null = $restoreLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::Absolute, 48)
)
$restoreTab.Controls.Add($restoreLayout)

$restoreDescription = New-Object Windows.Forms.Label
$restoreDescription.Text = (
    'Apply a saved configuration to this computer. Select a configuration ' +
    'and click Restore to review and choose which sections to apply.'
)
$restoreDescription.Font = New-Object Drawing.Font $form.Font.FontFamily, 9
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
Set-WizardPrimaryButtonHC $restore
$refresh = New-Object Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Size = New-Object Drawing.Size 120, 34
$restoreButtons.Controls.AddRange(@($restore, $refresh))
$restoreLayout.Controls.Add($restoreButtons, 0, 2)

$refresh.Add_Click({
    try {
        Write-Verbose 'Refresh the configuration list'
        $configurations.Items.Clear()
        foreach ($entry in Get-ConfigurationEntriesHC $RootFolder) {
            $item = New-Object Windows.Forms.ListViewItem $entry.Name
            $null = $item.SubItems.Add([string]$entry.Description)
            $item.Tag = $entry.Path
            $null = $configurations.Items.Add($item)
        }
    }
    catch {
        $null = [Windows.Forms.MessageBox]::Show(
            $form, [string]$_, 'Configuration error', 'OK', 'Error'
        )
    }
})
$restore.Add_Click({
    if ($configurations.SelectedItems.Count -eq 0) { return }
    $selected = $configurations.SelectedItems[0]
    try {
        Write-Verbose "Configuration '$($selected.Text)': select items"
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $selected.Tag)
        $selectionParams = @{
            ConfigurationName = $selected.Text
            Entries           = $entries
            ConfigurationFile = $selected.Tag
            RootFolder        = $RootFolder
        }
        $selection = New-RestoreSelectionFormHC @selectionParams
        try {
            if (
                $selection.ShowDialog($form) -ne
                [Windows.Forms.DialogResult]::OK
            ) {
                return
            }
            $selectedItems = @($selection.Tag)
            $controls = $selection.Controls
            $restoreOptions = @{
                RebootComputer      =
                    $controls.Find('RebootComputer', $true)[0].Checked
                RestartDelaySeconds =
                    [int]$controls.Find('RestartDelaySeconds', $true)[0].Value
                OpenReportInBrowser =
                    $controls.Find('OpenReportInBrowser', $true)[0].Checked
                AnswerFile          =
                    $controls.Find('AnswerFile', $true)[0].Text
                Unattended          =
                    $controls.Find('Unattended', $true)[0].Checked
            }
            $answers = Get-RestoreSelectionAnswersHC -Form $selection
        }
        finally { $selection.Dispose() }

        # The restore process reads the answers once from a named pipe;
        # they are never written to disk or put in the command line
        $server = $null
        if ($null -ne $answers -and $answers.Count) {
            $server = Start-RestoreAnswerServerHC -Answers $answers
            $answers.Clear()
            $answerServers.Add($server)
            $restoreOptions.AnswerPipe = $server.PipeName
        }

        $jobParams = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $RootFolder
            ConfigurationFile = $selected.Tag
            Items             = $selectedItems
        }
        try {
            Start-ConfigurationJobHC @jobParams @restoreOptions
        }
        catch {
            if ($null -ne $server) {
                $server.PowerShell.Stop()
            }
            throw
        }
    }
    catch {
        $null = [Windows.Forms.MessageBox]::Show(
            $form, [string]$_, 'Restore error', 'OK', 'Error'
        )
    }
})
$configurations.Add_DoubleClick({ $restore.PerformClick() })
#endregion

#region Export tab
$exportLayout = New-Object Windows.Forms.TableLayoutPanel
$exportLayout.Dock = 'Fill'
$exportLayout.Padding = New-Object Windows.Forms.Padding 12
$exportLayout.ColumnCount = 1
$null = $exportLayout.ColumnStyles.Add(
    (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
)
$exportLayout.RowCount = 7
$null = $exportLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::AutoSize)
)
foreach ($height in @(30, 38)) {
    $null = $exportLayout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Absolute, $height)
    )
}
$null = $exportLayout.RowStyles.Add(
    (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
)
foreach ($height in @(38, 40, 48)) {
    $null = $exportLayout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Absolute, $height)
    )
}
$exportTab.Controls.Add($exportLayout)

$exportDescription = New-Object Windows.Forms.Label
$exportDescription.Text = (
    'Save selected sections to a JSON file in Configurations. Some ' +
    'sections export editable templates rather than current settings; ' +
    'review the file before restoring it.'
)
$exportDescription.Font = New-Object Drawing.Font $form.Font.FontFamily, 9
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
$taskFolderPanel = New-ExportTaskFolderPanelHC -ItemList $itemList

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
Set-WizardPrimaryButtonHC $export
$exportButtons.Controls.Add($export)

$exportLayout.Controls.Add($nameLabel, 0, 1)
$exportLayout.Controls.Add($nameBox, 0, 2)
$exportLayout.Controls.Add($itemList, 0, 3)
$exportLayout.Controls.Add($taskFolderPanel, 0, 4)
$exportLayout.Controls.Add($options, 0, 5)
$exportLayout.Controls.Add($exportButtons, 0, 6)

$export.Add_Click({
    try {
        $selectedItems = @(
            $itemList.CheckedItems | ForEach-Object { [string]$_.Tag }
        )
        $jobOptions = @{}
        if ('ScheduledTasks' -in $selectedItems) {
            $folderBox = $taskFolderPanel.Controls.Find(
                'ScheduledTaskFolders', $false
            )[0]
            $taskFolders = @(Get-WizardTaskFolderHC -Text $folderBox.Text)
            $confirmParams = @{ Folders = $taskFolders; Owner = $form }
            if (-not (Confirm-WizardTaskFolderHC @confirmParams)) {
                Write-Verbose 'Export cancelled: task folder not confirmed'
                return
            }
            $jobOptions.TaskFolders = $taskFolders
        }

        $jobParams = @{
            Action              = 'CreateSnapshot'
            RootFolder          = $RootFolder
            Name                = $nameBox.Text
            Items               = $selectedItems
            OpenReportInBrowser = $openReport.Checked
            RunElevated         = $elevated.Checked
        }
        Start-ConfigurationJobHC @jobParams @jobOptions
    }
    catch {
        $null = [Windows.Forms.MessageBox]::Show(
            $form, [string]$_, 'Export error', 'OK', 'Error'
        )
    }
})
#endregion

$form.Add_Shown({ $refresh.PerformClick() })

Write-Verbose 'Show the wizard window'
try {
    $null = $form.ShowDialog()
}
finally {
    # A restore that has not read its answers yet asks for them itself
    foreach ($server in $answerServers) {
        $server.PowerShell.Stop()
        $server.PowerShell.Dispose()
    }
    $form.Dispose()
}
#endregion