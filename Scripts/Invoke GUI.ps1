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

function New-WizardHeaderHC {
    <#
    .SYNOPSIS
        The top of the wizard window: the configuration and answer file of
        the restore, in a large font, then the computer and the user the
        wizard runs as, and the administrator restart button when it is
        needed.
    #>
    param(
        $ElevationPanel,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$UserName = (
            [Security.Principal.WindowsIdentity]::GetCurrent().Name
        )
    )

    $sizeType = [Windows.Forms.SizeType]

    $header = New-Object Windows.Forms.TableLayoutPanel
    $header.Name = 'WizardHeader'
    $header.Dock = 'Fill'
    $header.AutoSize = $true
    $header.Padding = New-Object Windows.Forms.Padding 12, 6, 0, 0
    $header.ColumnCount = 3
    $null = $header.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    foreach ($column in 1..2) {
        $null = $header.ColumnStyles.Add(
            (New-Object Windows.Forms.ColumnStyle $sizeType::AutoSize)
        )
    }
    $header.RowCount = 1

    $selection = New-Object Windows.Forms.FlowLayoutPanel
    $selection.Dock = 'Fill'
    $selection.AutoSize = $true
    $selection.FlowDirection = 'TopDown'
    $selection.WrapContents = $false
    $selection.Margin = New-Object Windows.Forms.Padding 0

    $configuration = New-Object Windows.Forms.Label
    $configuration.Name = 'SelectedConfiguration'
    $configuration.AccessibleName = 'Selected configuration'
    $configuration.Font = New-Object Drawing.Font (
        'Segoe UI', 15, [Drawing.FontStyle]::Bold
    )
    $configuration.ForeColor = [Drawing.Color]::DarkSlateBlue
    $configuration.UseMnemonic = $false
    $configuration.AutoSize = $true
    $configuration.Margin = New-Object Windows.Forms.Padding 0

    $answerFile = New-Object Windows.Forms.Label
    $answerFile.Name = 'SelectedAnswerFile'
    $answerFile.AccessibleName = 'Selected answer file'
    $answerFile.Font = New-Object Drawing.Font 'Segoe UI', 11
    $answerFile.ForeColor = [Drawing.Color]::DimGray
    $answerFile.UseMnemonic = $false
    $answerFile.AutoSize = $true
    $answerFile.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 4

    $selection.Controls.AddRange(@($configuration, $answerFile))
    $header.Controls.Add($selection, 0, 0)

    # Where and as whom the wizard runs, so nobody restores the wrong PC
    $identity = New-Object Windows.Forms.TableLayoutPanel
    $identity.Name = 'WizardIdentity'
    $identity.AutoSize = $true
    $identity.Anchor = 'Right'
    $identity.ColumnCount = 2
    $identity.Margin = New-Object Windows.Forms.Padding 12, 0, 6, 0
    $smallFont = New-Object Drawing.Font 'Segoe UI', 9
    $row = 0
    foreach ($line in @(
            @('Computer', 'WizardComputerName', $ComputerName),
            @('User', 'WizardUserName', $UserName)
        )) {
        $caption = New-Object Windows.Forms.Label
        $caption.Text = $line[0]
        $caption.Font = $smallFont
        $caption.ForeColor = [Drawing.Color]::DimGray
        $caption.AutoSize = $true
        $caption.Margin = New-Object Windows.Forms.Padding 0, 1, 8, 1

        $value = New-Object Windows.Forms.Label
        $value.Name = $line[1]
        $value.AccessibleName = $line[0]
        $value.Text = $line[2]
        $value.Font = New-Object Drawing.Font $smallFont, (
            [Drawing.FontStyle]::Bold
        )
        $value.UseMnemonic = $false
        $value.AutoSize = $true
        $value.Margin = New-Object Windows.Forms.Padding 0, 1, 0, 1

        $identity.Controls.Add($caption, 0, $row)
        $identity.Controls.Add($value, 1, $row)
        $row++
    }
    $header.Controls.Add($identity, 1, 0)

    if ($ElevationPanel) {
        $header.Controls.Add($ElevationPanel, 2, 0)
    }

    return , $header
}

function Show-WizardHeaderHC {
    # Show a configuration and an answer file at the top of the window;
    # nothing hides the line
    param(
        [Parameter(Mandatory)]$Form,
        [string]$Configuration,
        [string]$AnswerFile
    )

    $labels = @{
        SelectedConfiguration = $Configuration
        SelectedAnswerFile    = $AnswerFile
    }

    foreach ($name in $labels.Keys) {
        $label = $Form.Controls.Find($name, $true) | Select-Object -First 1
        if ($null -eq $label) {
            continue
        }
        $label.Text = $labels[$name]
        $label.Visible = -not [string]::IsNullOrEmpty($labels[$name])
    }
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

    $labels = Get-SnapshotSectionLabelsHC

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
    param(
        [object[]]$Entries,
        # A check box in the header of the first column checks every
        # section or none
        [switch]$SelectAllHeader
    )

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

    if ($SelectAllHeader) {
        $list.OwnerDraw = $true
        $list.Add_DrawItem({
            param($sender, $eventArgs)
            $eventArgs.DrawDefault = $true
        })
        $list.Add_DrawSubItem({
            param($sender, $eventArgs)
            $eventArgs.DrawDefault = $true
        })
        $list.Add_DrawColumnHeader({
            param($sender, $eventArgs)
            if ($eventArgs.ColumnIndex -ne 0) {
                $eventArgs.DrawDefault = $true
                return
            }
            $glyph = [Windows.Forms.VisualStyles.CheckBoxState]
            $state = switch (Get-SnapshotItemsCheckStateHC $sender) {
                'Checked' {
                    $glyph::CheckedNormal
                }
                'Indeterminate' {
                    $glyph::MixedNormal
                }
                default {
                    $glyph::UncheckedNormal
                }
            }
            $graphics = $eventArgs.Graphics
            $bounds = $eventArgs.Bounds
            $size = [Windows.Forms.CheckBoxRenderer]::GetGlyphSize(
                $graphics, $state
            )
            $point = New-Object Drawing.Point (
                $bounds.Left + 4
            ), ($bounds.Top + [int](($bounds.Height - $size.Height) / 2))

            $eventArgs.DrawBackground()
            [Windows.Forms.CheckBoxRenderer]::DrawCheckBox(
                $graphics, $point, $state
            )
            $left = $point.X + $size.Width + 6
            $textBounds = New-Object Drawing.Rectangle $left, $bounds.Top, (
                $bounds.Right - $left
            ), $bounds.Height
            $flags = 'VerticalCenter, Left, EndEllipsis'
            [Windows.Forms.TextRenderer]::DrawText(
                $graphics, $eventArgs.Header.Text, $sender.Font, $textBounds,
                [Drawing.SystemColors]::ControlText,
                [Windows.Forms.TextFormatFlags]$flags
            )
        })
        $list.Add_ColumnClick({
            param($sender, $eventArgs)
            if ($eventArgs.Column -ne 0) {
                return
            }
            $checkParams = @{
                ItemList = $sender
                Checked  = (Get-SnapshotItemsCheckStateHC $sender) -ne
                    'Checked'
            }
            Set-SnapshotItemsCheckedHC @checkParams
        })
        # The header follows every check, also one by one
        $list.Add_ItemChecked({
            $this.Invalidate($true)
        })
    }
    return ,$list
}

function Get-SnapshotItemsCheckStateHC {
    # Checked when every section with data is checked, Unchecked when none
    param(
        [Parameter(Mandatory)][Windows.Forms.ListView]$ItemList
    )

    $available = @(
        $ItemList.Items | Where-Object { $_.Tag -notin $ItemList.Tag }
    )
    $checked = @($available | Where-Object { $_.Checked }).Count

    if ($available.Count -and $checked -eq $available.Count) {
        return [Windows.Forms.CheckState]::Checked
    }
    if ($checked) {
        return [Windows.Forms.CheckState]::Indeterminate
    }
    [Windows.Forms.CheckState]::Unchecked
}

function Set-SnapshotItemsCheckedHC {
    # Check or clear every section; one without data can not be checked
    param(
        [Parameter(Mandatory)][Windows.Forms.ListView]$ItemList,
        [Parameter(Mandatory)][bool]$Checked
    )

    $ItemList.BeginUpdate()
    try {
        foreach ($entry in $ItemList.Items) {
            $entry.Checked = $Checked -and $entry.Tag -notin $ItemList.Tag
        }
    }
    finally {
        $ItemList.EndUpdate()
    }
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

function Get-RestoreAnswerFileEntriesHC {
    <#
    .SYNOPSIS
        Every answer file in the Answers folder and its subfolders, with how
        many of the questions it answers.
    #>
    param(
        [Parameter(Mandatory)][string]$RootFolder,
        [object[]]$Questions
    )

    $folder = [IO.Path]::GetFullPath((Join-Path $RootFolder 'Answers'))

    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Write-Verbose "No answer files: folder '$folder' not found"
        return
    }

    $listParams = @{
        LiteralPath = $folder
        Filter      = '*.json'
        File        = $true
        Recurse     = $true
        ErrorAction = 'Stop'
    }

    foreach ($file in Get-ChildItem @listParams) {
        $answered = 0
        $problem = $null

        try {
            $answers = Read-RestoreAnswerFileHC -Path $file.FullName
            $answered = @(
                $Questions | Where-Object {
                    $null -ne $answers[$_.Placeholder]
                }
            ).Count
        }
        catch {
            # The messages name the file but never repeat an answer
            $problem = $_.Exception.Message
        }

        [pscustomobject]@{
            Path     = $file.FullName.Substring($folder.Length).TrimStart('\')
            FullName = $file.FullName
            Modified = $file.LastWriteTime
            Answered = $answered
            Total    = @($Questions).Count
            Problem  = $problem
        }
    }
}

function Get-RestoreWizardAnswerPathHC {
    # The path of an answer file inside the Answers folder
    param(
        [Parameter(Mandatory)]$Wizard,
        [Parameter(Mandatory)][string]$FullName
    )

    $folder = [IO.Path]::GetFullPath(
        (Join-Path $Wizard.Tag.RootFolder 'Answers')
    )

    $FullName.Substring($folder.Length).TrimStart('\')
}

function Update-RestoreWizardHeaderHC {
    <#
    .SYNOPSIS
        Show the configuration and answer file of the restore at the top
        of the window, so they stay in sight through the steps.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard
    )

    if ($null -eq $Wizard -or $null -eq $Wizard.FindForm()) {
        return
    }

    $state = $Wizard.Tag
    $find = { param($name) Find-RestoreWizardControlHC $Wizard $name }

    $configuration = if ($state.Step -eq 'Configuration') {
        (& $find 'Configurations').SelectedItems |
            Select-Object -First 1 -ExpandProperty Text
    }
    else {
        $state.ConfigurationName
    }

    $answerFile = $null

    if ($state.Step -eq 'AnswerFile') {
        $selected = (& $find 'AnswerFiles').SelectedItems |
            Select-Object -First 1
        if ($null -ne $selected) {
            $answerFile = $selected.Tag.FullName
            if (-not $answerFile) {
                $answerFile = 'None'
            }
        }
    }
    elseif (
        $state.Step -in @('Questions', 'Review') -and
        @($state.Questions).Count
    ) {
        $answerFile = if ($state.AnswerFile) {
            $state.AnswerFile
        }
        else {
            'None'
        }
    }

    if ($answerFile -and $answerFile -ne 'None') {
        $answerFile = Get-RestoreWizardAnswerPathHC $Wizard $answerFile
    }

    $headerParams = @{
        Form          = $Wizard.FindForm()
        Configuration = $configuration
        AnswerFile    = if ($answerFile) {
            "Answer file: $answerFile"
        }
    }
    Show-WizardHeaderHC @headerParams
}

function Get-RestoreWizardHC {
    # The restore wizard that contains a control
    param(
        [Parameter(Mandatory)]$Control
    )

    $parent = $Control

    while ($null -ne $parent -and $parent.Name -ne 'RestoreWizard') {
        $parent = $parent.Parent
    }

    $parent
}

function Find-RestoreWizardControlHC {
    # A control of the restore wizard, by name
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard,
        [Parameter(Mandatory)][string]$Name
    )

    # A control that was taken out of the wizard, while closing
    if ($null -eq $Wizard) {
        return
    }

    $Wizard.Controls.Find($Name, $true)[0]
}

function Update-RestoreWizardButtonsHC {
    # Enable Next only when the current step is complete
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard
    )

    # A control that was taken out of the wizard, while closing
    if ($null -eq $Wizard) {
        return
    }

    $state = $Wizard.Tag
    $next = Find-RestoreWizardControlHC $Wizard 'WizardNext'

    switch ($state.Step) {
        'Configuration' {
            $list = Find-RestoreWizardControlHC $Wizard 'Configurations'
            $next.Enabled = $list.SelectedItems.Count -gt 0
        }
        'Sections' {
            $list = Find-RestoreWizardControlHC $Wizard 'SnapshotItems'
            $next.Enabled = (
                $null -ne $list -and $list.CheckedItems.Count -gt 0
            )
        }
        'AnswerFile' {
            $list = Find-RestoreWizardControlHC $Wizard 'AnswerFiles'
            $next.Enabled = (
                $list.SelectedItems.Count -gt 0 -and
                $list.SelectedItems[0].Tag.Usable
            )
        }
        'Questions' {
            Update-RestoreAnswerGridHC -Grid $state.AnswerGrid
        }
        default {
            $next.Enabled = $true
        }
    }

    Update-RestoreWizardHeaderHC -Wizard $Wizard
}

function Show-RestoreWizardStepHC {
    <#
    .SYNOPSIS
        Show one step of the restore wizard and hide the others.
    .DESCRIPTION
        Without Back, the step is added to the steps taken, so Back returns
        along the same way, also when steps were skipped.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard,
        [ValidateSet(
            'Configuration', 'Sections', 'AnswerFile', 'Questions', 'Review'
        )]
        [string]$Step,
        [switch]$Back
    )

    # A control that was taken out of the wizard, while closing
    if ($null -eq $Wizard) {
        return
    }

    $state = $Wizard.Tag

    if ($Back) {
        $state.History.RemoveAt($state.History.Count - 1)
        $Step = $state.History[$state.History.Count - 1]
    }
    else {
        $state.History.Add($Step)
    }

    $titles = @{
        Configuration = 'Choose a configuration'
        Sections      = 'Choose the sections to restore'
        AnswerFile    = 'Choose an answer file'
        Questions     = 'Answer the questions'
        Review        = 'Review and restore'
    }

    foreach ($name in $titles.Keys) {
        (Find-RestoreWizardControlHC $Wizard "${name}Step").Visible =
            $name -eq $Step
    }

    $state.Step = $Step
    (Find-RestoreWizardControlHC $Wizard 'WizardStepTitle').Text = (
        "Step $($state.History.Count): $($titles[$Step])"
    )

    $next = Find-RestoreWizardControlHC $Wizard 'WizardNext'
    $next.Text = if ($Step -eq 'Review') {
        'Restore'
    }
    else {
        'Next >'
    }
    (Find-RestoreWizardControlHC $Wizard 'WizardBack').Enabled =
        $state.History.Count -gt 1
    (Find-RestoreWizardControlHC $Wizard 'RefreshConfigurations').Visible =
        $Step -eq 'Configuration'
    (Find-RestoreWizardControlHC $Wizard 'ReloadAnswerFile').Visible =
        $Step -eq 'Questions' -and [bool]$state.AnswerFile
    foreach ($name in @('SelectAll', 'ClearAll')) {
        (Find-RestoreWizardControlHC $Wizard $name).Visible =
            $Step -eq 'Sections'
    }

    # Only the questions step may enable Next for the answers
    if ($null -ne $state.AnswerGrid) {
        $state.AnswerGrid.Tag.Confirm = if ($Step -eq 'Questions') {
            $next
        }
    }

    Update-RestoreWizardButtonsHC -Wizard $Wizard

    $focus = switch ($Step) {
        'Configuration' {
            Find-RestoreWizardControlHC $Wizard 'Configurations'
        }
        'Sections' {
            Find-RestoreWizardControlHC $Wizard 'SnapshotItems'
        }
        'AnswerFile' {
            Find-RestoreWizardControlHC $Wizard 'AnswerFiles'
        }
        'Questions' {
            $state.AnswerGrid
        }
        default {
            $next
        }
    }

    if ($null -ne $focus -and $focus.CanFocus) {
        $null = $focus.Focus()
    }
}

function Update-RestoreConfigurationListHC {
    # List the configurations in the Configurations folder
    param(
        [Parameter(Mandatory)]$Wizard
    )

    $list = Find-RestoreWizardControlHC $Wizard 'Configurations'
    $list.BeginUpdate()

    try {
        $list.Items.Clear()

        foreach ($entry in Get-ConfigurationEntriesHC $Wizard.Tag.RootFolder) {
            $item = New-Object Windows.Forms.ListViewItem $entry.Name
            $null = $item.SubItems.Add([string]$entry.Description)
            $item.Tag = $entry.Path
            $null = $list.Items.Add($item)
        }
    }
    finally {
        $list.EndUpdate()
    }

    Update-RestoreWizardButtonsHC -Wizard $Wizard
}

function Set-RestoreWizardConfigurationHC {
    <#
    .SYNOPSIS
        Show the sections, description and saved options of a
        configuration on the sections step.
    #>
    param(
        [Parameter(Mandatory)]$Wizard,
        [Parameter(Mandatory)][string]$ConfigurationFile,
        [Parameter(Mandatory)][string]$Name
    )

    $state = $Wizard.Tag
    $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $ConfigurationFile)
    $settings = Get-RestoreSettingsHC -ConfigurationFile $ConfigurationFile

    $readParams = @{
        LiteralPath = $ConfigurationFile
        Raw         = $true
        Encoding    = 'UTF8'
        ErrorAction = 'Stop'
    }
    $document = Get-Content @readParams | ConvertFrom-Json -ErrorAction Stop
    $description = if (
        [string]::IsNullOrWhiteSpace($document.Description)
    ) {
        'No description provided.'
    }
    else {
        $document.Description
    }
    (Find-RestoreWizardControlHC $Wizard 'ConfigurationDescription').Text =
        $description

    $sectionsHost = Find-RestoreWizardControlHC $Wizard 'SectionsHost'
    foreach ($old in @($sectionsHost.Controls)) {
        $sectionsHost.Controls.Remove($old)
        $old.Dispose()
    }
    $list = New-SnapshotItemListHC -Entries $entries
    $list.Add_ItemChecked({
        Update-RestoreWizardButtonsHC -Wizard (Get-RestoreWizardHC $this)
    })
    $sectionsHost.Controls.Add($list)

    $unattended = Find-RestoreWizardControlHC $Wizard 'Unattended'
    $unattended.Checked = $false
    (Find-RestoreWizardControlHC $Wizard 'RebootComputer').Checked =
        $settings.RebootComputer
    (Find-RestoreWizardControlHC $Wizard 'RestartDelaySeconds').Value =
        $settings.RestartDelaySeconds
    (Find-RestoreWizardControlHC $Wizard 'OpenReportInBrowser').Checked =
        $settings.OpenReportInBrowser

    if ($null -ne $state.AnswerGrid) {
        Clear-RestoreAnswerGridHC -Grid $state.AnswerGrid
        $state.AnswerGrid.Parent.Controls.Remove($state.AnswerGrid)
        $state.AnswerGrid.Dispose()
    }

    $state.ConfigurationFile = $ConfigurationFile
    $state.ConfigurationName = $Name
    $state.Items = @()
    $state.Questions = @()
    $state.AnswerFile = $null
    $state.FileAnswers = $null
    $state.Answers = $null
    $state.AnswerGrid = $null
}

function Update-RestoreAnswerFileListHC {
    <#
    .SYNOPSIS
        List the answer files with how many questions each answers.
    .DESCRIPTION
        A file that answers none of the questions, or is invalid, is grayed
        out and can not be selected. Unattended needs a file that answers
        every question. Reload reads the files again; without it, the list
        is only sorted again.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard,
        [switch]$Reload
    )

    # A control that was taken out of the wizard, while closing
    if ($null -eq $Wizard) {
        return
    }

    $state = $Wizard.Tag
    $list = Find-RestoreWizardControlHC $Wizard 'AnswerFiles'
    $unattended = (Find-RestoreWizardControlHC $Wizard 'Unattended').Checked
    $sort = $list.Tag

    if ($Reload -or $null -eq $state.AnswerFileEntries) {
        $entryParams = @{
            RootFolder = $state.RootFolder
            Questions  = $state.Questions
        }
        $state.AnswerFileEntries = @(
            Get-RestoreAnswerFileEntriesHC @entryParams
        )
    }

    $selectedFile = if ($list.SelectedItems.Count) {
        $list.SelectedItems[0].Tag.FullName
    }
    else {
        $state.AnswerFile
    }

    $property = switch ($sort.Column) {
        1 {
            'Answered'
        }
        2 {
            'Modified'
        }
        default {
            'Path'
        }
    }
    $sortParams = @{
        Property   = $property, 'Path'
        Descending = $sort.Descending
    }
    $entries = @($state.AnswerFileEntries | Sort-Object @sortParams)

    $headers = @('Answer file', 'Answers', 'Date modified')
    for ($index = 0; $index -lt $headers.Count; $index++) {
        $arrow = if ($index -ne $sort.Column) {
            ''
        }
        elseif ($sort.Descending) {
            ' ' + [char]0x25BC
        }
        else {
            ' ' + [char]0x25B2
        }
        $list.Columns[$index].Text = $headers[$index] + $arrow
    }

    $total = @($state.Questions).Count
    $list.BeginUpdate()

    try {
        $list.Items.Clear()

        $none = New-Object Windows.Forms.ListViewItem (
            '(None) - answer the questions in the next step'
        )
        $null = $none.SubItems.Add("0 of $total")
        $null = $none.SubItems.Add('')
        $none.Tag = [pscustomobject]@{
            FullName = $null
            Usable   = -not $unattended
        }
        if ($unattended) {
            $none.ForeColor = [Drawing.SystemColors]::GrayText
            $none.ToolTipText = 'Unattended needs an answer for every question.'
        }
        $null = $list.Items.Add($none)

        foreach ($entry in $entries) {
            $usable = (
                -not $entry.Problem -and $entry.Answered -gt 0 -and
                (-not $unattended -or $entry.Answered -eq $entry.Total)
            )
            $item = New-Object Windows.Forms.ListViewItem $entry.Path
            $answeredText = if ($entry.Problem) {
                'Invalid'
            }
            else {
                "$($entry.Answered) of $($entry.Total)"
            }
            $null = $item.SubItems.Add($answeredText)
            $null = $item.SubItems.Add(
                $entry.Modified.ToString('yyyy-MM-dd HH:mm')
            )
            $item.Tag = [pscustomobject]@{
                FullName = $entry.FullName
                Usable   = $usable
            }
            $item.ToolTipText = $entry.FullName

            if (-not $usable) {
                $item.ForeColor = [Drawing.SystemColors]::GrayText
                $item.ToolTipText = if ($entry.Problem) {
                    $entry.Problem
                }
                elseif ($entry.Answered -eq 0) {
                    'Answers none of the questions of the checked sections.'
                }
                else {
                    'Unattended needs an answer for every question.'
                }
            }
            $null = $list.Items.Add($item)
        }

        $selected = $list.Items | Where-Object {
            $_.Tag.Usable -and $_.Tag.FullName -eq $selectedFile
        } | Select-Object -First 1
        if ($selected) {
            $selected.Selected = $true
            $selected.Focused = $true
        }
    }
    finally {
        $list.EndUpdate()
    }

    Update-RestoreWizardButtonsHC -Wizard $Wizard
}

function New-RestoreWizardAnswerFileHC {
    <#
    .SYNOPSIS
        Create an answer file for the checked sections in the Answers
        folder, with an empty answer for every question.
    #>
    param(
        [Parameter(Mandatory)]$Wizard
    )

    $state = $Wizard.Tag
    $name = (Find-RestoreWizardControlHC $Wizard 'NewAnswerFile').Text.Trim()
    $folder = [IO.Path]::GetFullPath(
        (Join-Path $state.RootFolder 'Answers')
    )

    if (
        [string]::IsNullOrWhiteSpace($name) -or
        [IO.Path]::IsPathRooted($name) -or
        $name.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
        @($name -split '[\\/]') -contains '..'
    ) {
        throw (
            'Enter a file name inside the Answers folder, such as ' +
            'Kiosk\Antwerp\Kiosk.json.'
        )
    }

    if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        $name += '.json'
    }

    $path = [IO.Path]::GetFullPath((Join-Path $folder $name))
    if (Test-Path -LiteralPath $path) {
        throw "Answer file 'Answers\$name' already exists."
    }

    $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force

    $templateParams = @{
        ConfigurationFile = $state.ConfigurationFile
        AnswerFile        = $path
        RootFolder        = $state.RootFolder
        Items             = $state.Items
    }
    $null = New-RestoreAnswerFileHC @templateParams

    (Find-RestoreWizardControlHC $Wizard 'AnswerFileStatus').Text = (
        "Created Answers\$name. Fill in its null values in a text editor, " +
        'then click Refresh.'
    )
    Update-RestoreAnswerFileListHC -Wizard $Wizard -Reload
}

function Get-RestoreAnswerGridValueHC {
    # The answer in a row of the answer list, also while it is typed
    param(
        [Parameter(Mandatory)]$Grid,
        [Parameter(Mandatory)]$Row
    )

    $current = $Grid.CurrentCell
    if (
        $Grid.IsCurrentCellInEditMode -and
        $null -ne $current -and
        $current.RowIndex -eq $Row.Index -and
        $current.ColumnIndex -eq 1 -and
        $Grid.EditingControl -is [Windows.Forms.TextBox]
    ) {
        return $Grid.EditingControl.Text
    }

    [string]$Row.Cells[1].Value
}

function Update-RestoreAnswerGridHC {
    <#
    .SYNOPSIS
        Check every answer in the answer list, say what is expected or wrong
        in the Check column, and enable the confirm button only when every
        answer is valid.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Grid
    )

    if ($null -eq $Grid) {
        return
    }

    $invalid = 0
    $total = 0

    foreach ($row in $Grid.Rows) {
        $state = $row.Tag
        if ($null -eq $state) {
            continue
        }

        $total++
        $question = $state.Question
        $value = Get-RestoreAnswerGridValueHC -Grid $Grid -Row $row
        $problemParams = @{
            Kind  = $question.Kind
            Value = $value
            Rule  = $question.Rule
        }
        $problem = Get-RestoreInputProblemHC @problemParams
        $check = $row.Cells[2]

        if (-not $problem) {
            $check.Value = [string][char]0x2713
            if ($state.FileValue -and $value -ceq $state.FileValue) {
                $check.Value += ' From the answer file'
            }
            elseif ($state.FileValue) {
                $check.Value += ' Changed for this restore'
            }
            $check.Style.ForeColor = [Drawing.Color]::SeaGreen
            continue
        }

        $invalid++

        if ($state.Touched) {
            $check.Value = $problem
            $check.Style.ForeColor = [Drawing.Color]::Firebrick
        }
        else {
            $hint = Get-RestoreInputHintHC -Kind $question.Kind -Rule (
                $question.Rule
            )
            $check.Value = if ($hint) {
                $hint
            }
            else {
                'A value is required.'
            }
            $check.Style.ForeColor = [Drawing.Color]::DimGray
        }
    }

    $Grid.Tag.Invalid = $invalid
    if ($null -ne $Grid.Tag.Confirm) {
        $Grid.Tag.Confirm.Enabled = $invalid -eq 0
    }
    if ($null -ne $Grid.Tag.Summary) {
        $Grid.Tag.Summary.Text = if ($invalid) {
            "$invalid of $total answer(s) still needed"
        }
        else {
            'All answers are valid'
        }
    }
}

function Get-RestoreAnswerGridValuesHC {
    # The answers in the answer list, by placeholder
    param(
        [Parameter(Mandatory)]$Grid
    )

    if ($Grid.IsCurrentCellInEditMode) {
        $null = $Grid.EndEdit()
    }

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,string]'
    $values = New-Object $dictionaryType ([StringComparer]::Ordinal)

    foreach ($row in $Grid.Rows) {
        if ($null -ne $row.Tag) {
            $values[$row.Tag.Question.Placeholder] = [string]$row.Cells[1].Value
        }
    }

    return , $values
}

function Get-RestoreAnswerGridChangesHC {
    <#
    .SYNOPSIS
        The answers in the answer list that are typed or changed: not empty
        and not the answer of the answer file. The answer file is never
        changed; these answers replace its answers for this restore only.
    #>
    param(
        [Parameter(Mandatory)]$Grid
    )

    $values = Get-RestoreAnswerGridValuesHC -Grid $Grid

    foreach ($row in $Grid.Rows) {
        $state = $row.Tag
        if ($null -eq $state) {
            continue
        }

        $placeholder = $state.Question.Placeholder
        if (
            [string]::IsNullOrEmpty($values[$placeholder]) -or
            $values[$placeholder] -ceq $state.FileValue
        ) {
            $null = $values.Remove($placeholder)
        }
    }

    return , $values
}

function Clear-RestoreAnswerGridHC {
    # Forget the answers in the answer list, passwords included
    param(
        [Parameter(Mandatory)][AllowNull()]$Grid
    )

    if ($null -eq $Grid) {
        return
    }

    if ($Grid.IsCurrentCellInEditMode) {
        $null = $Grid.CancelEdit()
        $null = $Grid.EndEdit()
    }

    foreach ($row in $Grid.Rows) {
        if ($null -ne $row.Tag) {
            $row.Cells[1].Value = $null
        }
    }
}

function New-RestoreAnswerGridHC {
    <#
    .SYNOPSIS
        The questions of the restore as an editable list, grouped by section
        like the review: a row per question with its answer and a check.
    .DESCRIPTION
        A setting with fixed values gets a list to choose from, and a
        password is never shown, also not while it is typed. Values fills
        the answers by placeholder. Set Tag.Confirm to the button that may
        only be used when every answer is valid, and Tag.Summary to a label
        that counts the answers still needed.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Questions,
        [System.Collections.IDictionary]$Values,
        # The answers of the answer file; they can be changed in the list
        [System.Collections.IDictionary]$FileValues,
        [Drawing.Font]$Font = (New-Object Drawing.Font 'Segoe UI', 10)
    )

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Name = 'AnswerGrid'
    $grid.Dock = 'Fill'
    $grid.Font = $Font
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'CellSelect'
    $grid.EditMode = 'EditOnEnter'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [Drawing.SystemColors]::Window
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.GridColor = [Drawing.SystemColors]::ControlLight
    $grid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $grid.DefaultCellStyle.SelectionBackColor = [Drawing.SystemColors]::Window
    $grid.DefaultCellStyle.SelectionForeColor =
        [Drawing.SystemColors]::WindowText
    $grid.ShowCellToolTips = $true
    $grid.Tag = @{
        Confirm = $null
        Summary = $null
        Invalid = 0
    }

    foreach ($column in @(
            @('Question', 'Question', 45, $true),
            @('Answer', 'Answer', 30, $false),
            @('Check', 'Check', 25, $true)
        )) {
        $gridColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $gridColumn.Name = $column[0]
        $gridColumn.HeaderText = $column[1]
        $gridColumn.FillWeight = $column[2]
        $gridColumn.ReadOnly = $column[3]
        $gridColumn.SortMode = 'NotSortable'
        $null = $grid.Columns.Add($gridColumn)
    }
    $grid.Columns['Check'].DefaultCellStyle.Font = New-Object Drawing.Font (
        $Font.FontFamily, 9
    )
    $grid.Columns['Check'].DefaultCellStyle.WrapMode = 'True'
    $grid.AutoSizeRowsMode = 'AllCells'

    $headerFont = New-Object Drawing.Font $Font, ([Drawing.FontStyle]::Bold)
    $section = $null

    foreach ($question in $Questions) {
        if ($question.Section -ne $section) {
            $section = $question.Section
            $index = $grid.Rows.Add($section, '', '')
            $header = $grid.Rows[$index]
            $header.ReadOnly = $true
            $header.DefaultCellStyle.Font = $headerFont
            $header.DefaultCellStyle.ForeColor = [Drawing.Color]::DarkSlateBlue
            $header.DefaultCellStyle.SelectionForeColor =
                [Drawing.Color]::DarkSlateBlue
        }

        $value = $null
        $fileValue = $null
        if ($null -ne $FileValues) {
            $fileValue = $FileValues[$question.Placeholder]
        }
        if ($null -ne $Values) {
            $value = $Values[$question.Placeholder]
        }
        if (-not $value) {
            $value = $fileValue
        }

        $index = $grid.Rows.Add($question.Description, $null, '')
        $row = $grid.Rows[$index]

        if ($question.Rule.Values) {
            $cell = New-Object Windows.Forms.DataGridViewComboBoxCell
            $cell.Items.AddRange([object[]]$question.Rule.Values)
            $cell.FlatStyle = 'Flat'
            $row.Cells[1] = $cell
            if ($value -and $cell.Items.Contains($value)) {
                $cell.Value = $value
            }
        }
        elseif ($value) {
            $row.Cells[1].Value = $value
        }

        $location = $question.Path
        if ($question.OtherSections.Count) {
            $location += (
                [Environment]::NewLine +
                "Also used by: $($question.OtherSections -join ', ')"
            )
        }
        $row.Cells[0].ToolTipText = $location
        $row.Tag = @{
            Question  = $question
            FileValue = $fileValue
            Touched   = [bool]$value
        }
    }

    # Never show a password, nor how long it is
    $grid.Add_CellFormatting({
        param($sender, $eventArgs)
        $state = $sender.Rows[$eventArgs.RowIndex].Tag
        if (
            $eventArgs.ColumnIndex -eq 1 -and
            $null -ne $state -and
            $state.Question.Kind -eq 'password' -and
            -not [string]::IsNullOrEmpty([string]$eventArgs.Value)
        ) {
            $eventArgs.Value = [string]([char]0x25CF) * 8
            $eventArgs.FormattingApplied = $true
        }
    })
    $grid.Add_EditingControlShowing({
        param($sender, $eventArgs)
        $box = $eventArgs.Control -as [Windows.Forms.TextBox]
        if ($null -eq $box) {
            return
        }
        $state = $sender.CurrentRow.Tag
        $box.UseSystemPasswordChar = (
            $null -ne $state -and $state.Question.Kind -eq 'password'
        )
        # A grid that sizes its rows can hand over an empty colour, which
        # the text box shows as black; the style is applied after this event
        $style = $eventArgs.CellStyle
        if ($style.BackColor.A -lt 255) {
            $style.BackColor = [Drawing.SystemColors]::Window
        }
        if ($style.ForeColor.IsEmpty) {
            $style.ForeColor = [Drawing.SystemColors]::WindowText
        }
        # The grid reuses its text box; check while typing, hooked once
        if (-not $box.Tag) {
            $box.Tag = 'Checked while typing'
            $box.Add_TextChanged({
                Update-RestoreAnswerGridHC -Grid (
                    $this.EditingControlDataGridView
                )
            })
        }
    })
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($this.CurrentCell -is [Windows.Forms.DataGridViewComboBoxCell]) {
            $null = $this.CommitEdit('CurrentCellChange')
        }
    })
    $grid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($eventArgs.ColumnIndex -ne 1 -or $eventArgs.RowIndex -lt 0) {
            return
        }
        $row = $sender.Rows[$eventArgs.RowIndex]
        if ($null -ne $row.Tag -and $row.Cells[1].Value) {
            $row.Tag.Touched = $true
        }
        Update-RestoreAnswerGridHC -Grid $sender
    })
    $grid.Add_CellEndEdit({
        param($sender, $eventArgs)
        $state = $sender.Rows[$eventArgs.RowIndex].Tag
        if ($null -ne $state) {
            $state.Touched = $true
        }
        Update-RestoreAnswerGridHC -Grid $sender
    })

    Update-RestoreAnswerGridHC -Grid $grid

    return , $grid
}

function Set-RestoreWizardQuestionsHC {
    <#
    .SYNOPSIS
        Fill the questions step. Answers typed earlier are kept for the
        questions that are still asked.
    .PARAMETER FromAnswerFile
        Take every answer the answer file gives, also where it was changed;
        typed answers are only kept for questions the file leaves open.
    #>
    param(
        [Parameter(Mandatory)]$Wizard,
        [Parameter(Mandatory)][object[]]$Questions,
        [switch]$FromAnswerFile
    )

    $state = $Wizard.Tag
    $gridHost = Find-RestoreWizardControlHC $Wizard 'AnswerGridHost'
    $earlier = $null

    # Keep what was typed or changed; the rest comes from the answer file
    if ($null -ne $state.AnswerGrid) {
        $earlier = Get-RestoreAnswerGridChangesHC -Grid $state.AnswerGrid
        Clear-RestoreAnswerGridHC -Grid $state.AnswerGrid
        $gridHost.Controls.Remove($state.AnswerGrid)
        $state.AnswerGrid.Dispose()
    }

    if ($FromAnswerFile -and $null -ne $earlier -and $state.FileAnswers) {
        foreach ($placeholder in @($earlier.Keys)) {
            if ($state.FileAnswers[$placeholder]) {
                $earlier.Remove($placeholder)
            }
        }
    }

    $gridParams = @{
        Questions  = $Questions
        Values     = $earlier
        FileValues = $state.FileAnswers
        Font       = $Wizard.Font
    }
    $state.AnswerGrid = New-RestoreAnswerGridHC @gridParams
    $state.AnswerGrid.Tag.Summary = Find-RestoreWizardControlHC $Wizard (
        'AnswerGridSummary'
    )
    $gridHost.Controls.Add($state.AnswerGrid)
    Update-RestoreAnswerGridHC -Grid $state.AnswerGrid

    if ($null -ne $earlier) {
        $earlier.Clear()
    }
}

function Reset-RestoreWizardAnswersHC {
    <#
    .SYNOPSIS
        Read the answer file again and show its answers in the questions
        step, replacing the answers changed for this restore.
    .DESCRIPTION
        For a wrong answer file chosen first, or a file edited meanwhile.
        Answers typed for questions the file leaves open are kept.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Wizard
    )

    if ($null -eq $Wizard -or -not $Wizard.Tag.AnswerFile) {
        return
    }

    $state = $Wizard.Tag
    $state.FileAnswers = Read-RestoreAnswerFileHC -Path $state.AnswerFile

    $questionParams = @{
        Wizard         = $Wizard
        Questions      = $state.Questions
        FromAnswerFile = $true
    }
    Set-RestoreWizardQuestionsHC @questionParams

    # Next follows the answers of the new list
    $state.AnswerGrid.Tag.Confirm = Find-RestoreWizardControlHC $Wizard (
        'WizardNext'
    )
    Update-RestoreAnswerGridHC -Grid $state.AnswerGrid
}

function Update-RestoreWizardReviewHC {
    <#
    .SYNOPSIS
        Show what the restore will do: the choices on a card, and every
        checked section with its answers and where they are from.
    #>
    param(
        [Parameter(Mandatory)]$Wizard
    )

    $state = $Wizard.Tag
    $find = { param($name) Find-RestoreWizardControlHC $Wizard $name }
    $unattended = (& $find 'Unattended').Checked
    $answerFile = if ($state.AnswerFile) {
        'Answers\' + (Get-RestoreWizardAnswerPathHC $Wizard $state.AnswerFile)
    }
    else {
        'None'
    }

    $values = @{
        ReviewConfiguration = $state.ConfigurationName
        ReviewAnswerFile    = $answerFile
        ReviewRestart       = if ((& $find 'RebootComputer').Checked) {
            "After $((& $find 'RestartDelaySeconds').Value) seconds, when " +
            'nothing failed'
        }
        else {
            'No'
        }
        ReviewReport        = if ((& $find 'OpenReportInBrowser').Checked) {
            'Opens in the browser'
        }
        else {
            'Not opened'
        }
        ReviewUnattended    = (
            'Nothing is asked; the restore needs administrator rights'
        )
    }
    foreach ($name in $values.Keys) {
        (& $find $name).Text = $values[$name]
    }
    foreach ($name in @('ReviewUnattended', 'ReviewUnattendedCaption')) {
        (& $find $name).Visible = $unattended
    }

    $labels = Get-SnapshotSectionLabelsHC
    $list = & $find 'ReviewAnswers'
    $list.BeginUpdate()

    try {
        $list.Items.Clear()
        $list.Groups.Clear()

        # Every checked section, in the order the sections run
        foreach ($key in $state.Items) {
            $section = $labels[$key][0]
            $group = New-Object Windows.Forms.ListViewGroup $section
            $null = $list.Groups.Add($group)
            $questions = @(
                $state.Questions | Where-Object { $_.Section -eq $section }
            )

            if (-not $questions.Count) {
                $item = New-Object Windows.Forms.ListViewItem 'No questions'
                $item.ForeColor = [Drawing.SystemColors]::GrayText
                $item.Group = $group
                $null = $list.Items.Add($item)
                continue
            }

            foreach ($question in $questions) {
                $typed = $null
                if ($null -ne $state.Answers) {
                    $typed = $state.Answers[$question.Placeholder]
                }

                $value, $source = if (
                    $typed -and $null -ne $state.FileAnswers -and
                    $state.FileAnswers[$question.Placeholder]
                ) {
                    $typed, 'Changed'
                }
                elseif ($typed) {
                    $typed, 'Typed'
                }
                else {
                    $state.FileAnswers[$question.Placeholder], 'Answer file'
                }

                # Never show a password, nor how long it is
                $shown = if ($question.Kind -eq 'password') {
                    [string]([char]0x25CF) * 8
                }
                else {
                    $value
                }

                $item = New-Object Windows.Forms.ListViewItem (
                    $question.Description
                )
                $null = $item.SubItems.Add([string]$shown)
                $null = $item.SubItems.Add($source)
                $item.Group = $group
                $null = $list.Items.Add($item)
            }
        }
    }
    finally {
        $list.EndUpdate()
    }
}

function Start-RestoreWizardJobHC {
    <#
    .SYNOPSIS
        Start the restore with the choices of the wizard and return to the
        first step.
    .DESCRIPTION
        The answer file is passed by its path. Typed answers go to the
        restore process over a one-time named pipe; they are never written
        to disk or put in the command line.
    #>
    param(
        [Parameter(Mandatory)]$Wizard
    )

    $state = $Wizard.Tag
    $find = { param($name) Find-RestoreWizardControlHC $Wizard $name }

    $restoreOptions = @{
        RebootComputer      = (& $find 'RebootComputer').Checked
        RestartDelaySeconds = [int](& $find 'RestartDelaySeconds').Value
        OpenReportInBrowser = (& $find 'OpenReportInBrowser').Checked
        Unattended          = (& $find 'Unattended').Checked
    }
    if ($state.AnswerFile) {
        $restoreOptions.AnswerFile = $state.AnswerFile
    }

    $server = $null
    if ($null -ne $state.Answers -and $state.Answers.Count) {
        $server = Start-RestoreAnswerServerHC -Answers $state.Answers
        $state.AnswerServers.Add($server)
        $restoreOptions.AnswerPipe = $server.PipeName
    }

    $jobParams = @{
        Action            = 'RestoreSnapshot'
        RootFolder        = $state.RootFolder
        ConfigurationFile = $state.ConfigurationFile
        Items             = $state.Items
    }

    try {
        $null = Start-ConfigurationJobHC @jobParams @restoreOptions
    }
    catch {
        if ($null -ne $server) {
            $server.PowerShell.Stop()
        }
        throw
    }

    if ($null -ne $state.Answers) {
        $state.Answers.Clear()
        $state.Answers = $null
    }
    Clear-RestoreAnswerGridHC -Grid $state.AnswerGrid

    $state.History.Clear()
    Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Configuration'
}

function Invoke-RestoreWizardNextHC {
    # Go to the next step that has something to ask, or start the restore
    param(
        [Parameter(Mandatory)]$Wizard
    )

    $state = $Wizard.Tag
    $find = { param($name) Find-RestoreWizardControlHC $Wizard $name }

    switch ($state.Step) {
        'Configuration' {
            $selected = (& $find 'Configurations').SelectedItems |
                Select-Object -First 1
            if (-not $selected) {
                return
            }

            if ($selected.Tag -ne $state.ConfigurationFile) {
                $configurationParams = @{
                    Wizard            = $Wizard
                    ConfigurationFile = $selected.Tag
                    Name              = $selected.Text
                }
                Set-RestoreWizardConfigurationHC @configurationParams
            }

            Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Sections'
        }
        'Sections' {
            $checked = @(
                (& $find 'SnapshotItems').CheckedItems |
                ForEach-Object { [string]$_.Tag }
            )
            if (-not $checked.Count) {
                return
            }

            $questionParams = @{
                ConfigurationFile = $state.ConfigurationFile
                RootFolder        = $state.RootFolder
                Items             = $checked
            }
            $state.Questions = @(Get-WizardRestoreQuestionsHC @questionParams)
            $state.Items = $checked

            if ($state.Questions.Count) {
                # Fill the list once it is shown, so its selection holds
                Show-RestoreWizardStepHC -Wizard $Wizard -Step 'AnswerFile'
                Update-RestoreAnswerFileListHC -Wizard $Wizard -Reload
                return
            }

            $state.AnswerFile = $null
            $state.FileAnswers = $null
            $state.Answers = $null
            Update-RestoreWizardReviewHC -Wizard $Wizard
            Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Review'
        }
        'AnswerFile' {
            $selected = (& $find 'AnswerFiles').SelectedItems |
                Select-Object -First 1
            if (-not $selected -or -not $selected.Tag.Usable) {
                return
            }

            $state.AnswerFile = $selected.Tag.FullName
            $state.FileAnswers = if ($state.AnswerFile) {
                Read-RestoreAnswerFileHC -Path $state.AnswerFile
            }

            # Every question, also those the file answers, so a single
            # answer can be changed for this restore
            if (-not (& $find 'Unattended').Checked) {
                $questionParams = @{
                    Wizard    = $Wizard
                    Questions = $state.Questions
                }
                Set-RestoreWizardQuestionsHC @questionParams
                Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Questions'
                return
            }

            $state.Answers = $null
            Update-RestoreWizardReviewHC -Wizard $Wizard
            Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Review'
        }
        'Questions' {
            Update-RestoreAnswerGridHC -Grid $state.AnswerGrid
            if (-not (& $find 'WizardNext').Enabled) {
                return
            }

            # The answer file is passed by its path, only the other answers
            # are handed over
            $state.Answers = Get-RestoreAnswerGridChangesHC -Grid (
                $state.AnswerGrid
            )
            Update-RestoreWizardReviewHC -Wizard $Wizard
            Show-RestoreWizardStepHC -Wizard $Wizard -Step 'Review'
        }
        'Review' {
            Start-RestoreWizardJobHC -Wizard $Wizard
        }
    }
}

function New-RestoreWizardHC {
    <#
    .SYNOPSIS
        The restore steps of the Restore tab, in one window: configuration,
        sections, answer file, questions and review.
    .DESCRIPTION
        Back and Next show one step at a time. The answer file and
        questions steps are skipped when the checked sections need no
        answers, and the questions step when the answer file answers
        everything. Nothing is changed before Restore on the review step.
    #>
    param(
        [Parameter(Mandatory)][string]$RootFolder,
        [Drawing.Font]$Font = (New-Object Drawing.Font 'Segoe UI', 10)
    )

    $sizeType = [Windows.Forms.SizeType]
    $smallFont = New-Object Drawing.Font $Font.FontFamily, 9
    $titleFont = New-Object Drawing.Font (
        $Font.FontFamily, 11, [Drawing.FontStyle]::Bold
    )

    #region Wizard: step title, the step, buttons
    $wizard = New-Object Windows.Forms.TableLayoutPanel
    $wizard.Name = 'RestoreWizard'
    $wizard.Dock = 'Fill'
    $wizard.Padding = New-Object Windows.Forms.Padding 12
    $wizard.Font = $Font
    $wizard.ColumnCount = 1
    $null = $wizard.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    $wizard.RowCount = 3
    $null = $wizard.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::AutoSize)
    )
    $null = $wizard.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Percent, 100)
    )
    $null = $wizard.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $sizeType::Absolute, 48)
    )
    $wizard.Tag = @{
        RootFolder        = $RootFolder
        Step              = 'Configuration'
        History           = New-Object 'System.Collections.Generic.List[string]'
        ConfigurationFile = $null
        ConfigurationName = $null
        Items             = @()
        Questions         = @()
        AnswerFileEntries = $null
        AnswerFile        = $null
        FileAnswers       = $null
        Answers           = $null
        AnswerGrid        = $null
        AnswerServers     = New-Object 'System.Collections.Generic.List[object]'
    }

    $title = New-Object Windows.Forms.Label
    $title.Name = 'WizardStepTitle'
    $title.Font = $titleFont
    $title.ForeColor = [Drawing.Color]::DarkSlateBlue
    $title.AutoSize = $true
    $title.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 8
    $wizard.Controls.Add($title, 0, 0)

    $pages = New-Object Windows.Forms.Panel
    $pages.Dock = 'Fill'
    $pages.Margin = New-Object Windows.Forms.Padding 0
    $wizard.Controls.Add($pages, 0, 1)

    $newStep = {
        param([string]$Name, [int[]]$Rows)

        $step = New-Object Windows.Forms.TableLayoutPanel
        $step.Name = $Name
        $step.Dock = 'Fill'
        $step.Visible = $false
        $step.ColumnCount = 1
        $null = $step.ColumnStyles.Add(
            (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
        )
        $step.RowCount = $Rows.Count
        foreach ($row in $Rows) {
            $style = if ($row) {
                New-Object Windows.Forms.RowStyle $sizeType::Percent, 100
            }
            else {
                New-Object Windows.Forms.RowStyle $sizeType::AutoSize
            }
            $null = $step.RowStyles.Add($style)
        }
        $pages.Controls.Add($step)

        return , $step
    }

    $newGuidance = {
        param([string]$Name, [string]$Text)

        $label = New-Object Windows.Forms.Label
        $label.Name = $Name
        $label.Text = $Text
        $label.Font = $smallFont
        $label.AutoSize = $true
        $label.Dock = 'Fill'
        $label.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12

        return , $label
    }
    #endregion

    #region Configuration step: guidance, configurations
    $step = & $newStep 'ConfigurationStep' @(0, 1)
    $guidance = & $newGuidance 'ConfigurationGuidance' (
        'Apply a saved configuration to this computer. Select a ' +
        'configuration and click Next to choose which sections to apply.'
    )
    $step.Controls.Add($guidance, 0, 0)

    $configurations = New-Object Windows.Forms.ListView
    $configurations.Name = 'Configurations'
    $configurations.Dock = 'Fill'
    $configurations.View = 'Details'
    $configurations.FullRowSelect = $true
    $configurations.MultiSelect = $false
    $configurations.HideSelection = $false
    $null = $configurations.Columns.Add('Configuration', 240)
    $null = $configurations.Columns.Add('Description', 420)
    $configurations.Add_SelectedIndexChanged({
        Update-RestoreWizardButtonsHC -Wizard (Get-RestoreWizardHC $this)
    })
    $configurations.Add_DoubleClick({
        $next = Find-RestoreWizardControlHC (Get-RestoreWizardHC $this) (
            'WizardNext'
        )
        if ($next.Enabled) {
            $next.PerformClick()
        }
    })
    $step.Controls.Add($configurations, 0, 1)
    #endregion

    #region Sections step: description, guidance, sections, options
    $step = & $newStep 'SectionsStep' @(0, 0, 1, 0)

    $description = New-Object Windows.Forms.Label
    $description.Name = 'ConfigurationDescription'
    $description.AccessibleName = 'Configuration description'
    $description.BorderStyle = 'FixedSingle'
    $description.Padding = New-Object Windows.Forms.Padding 10
    $description.BackColor = [Drawing.SystemColors]::Window
    $description.ForeColor = [Drawing.SystemColors]::WindowText
    $description.UseMnemonic = $false
    $description.AutoSize = $true
    $description.Dock = 'Fill'
    $description.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $step.Controls.Add($description, 0, 0)

    $guidance = & $newGuidance 'RestoreGuidance' (
        'Choose the sections to apply to this computer. ' +
        'Uncheck anything you want to leave unchanged.'
    )
    $step.Controls.Add($guidance, 0, 1)

    $sectionsHost = New-Object Windows.Forms.Panel
    $sectionsHost.Name = 'SectionsHost'
    $sectionsHost.Dock = 'Fill'
    $sectionsHost.Margin = New-Object Windows.Forms.Padding 0
    $step.Controls.Add($sectionsHost, 0, 2)

    $options = New-Object Windows.Forms.FlowLayoutPanel
    $options.Name = 'RestoreOptions'
    $options.Dock = 'Fill'
    $options.AutoSize = $true

    $reboot = New-Object Windows.Forms.CheckBox
    $reboot.Name = 'RebootComputer'
    $reboot.Text = 'Restart computer after successful restore'
    $reboot.AutoSize = $true

    $delayLabel = New-Object Windows.Forms.Label
    $delayLabel.Name = 'RestartDelayLabel'
    $delayLabel.Text = 'Countdown (seconds):'
    $delayLabel.AutoSize = $true
    $delayLabel.Margin = New-Object Windows.Forms.Padding 0, 6, 0, 0
    $delayLabel.Enabled = $false

    $delay = New-Object Windows.Forms.NumericUpDown
    $delay.Name = 'RestartDelaySeconds'
    $delay.AccessibleName = 'Restart countdown in seconds'
    $delay.Minimum = 0
    $delay.Maximum = 600
    $delay.Increment = 10
    $delay.Width = 70
    $delay.Value = 60
    $delay.Enabled = $false
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

    $unattended = New-Object Windows.Forms.CheckBox
    $unattended.Name = 'Unattended'
    $unattended.Text = (
        'Unattended: take every answer from the answer file, ask nothing'
    )
    $unattended.AutoSize = $true
    $unattended.Add_CheckedChanged({
        # Unattended never opens the browser; restore the old choice after
        $report = $this.Parent.Controls.Find('OpenReportInBrowser', $false)[0]
        if ($this.Checked) {
            $report.Tag = $report.Checked
            $report.Checked = $false
        }
        else {
            $report.Checked = [bool]$report.Tag
        }
        $report.Enabled = -not $this.Checked
    })

    $options.Controls.AddRange(
        @($reboot, $delayLabel, $delay, $report, $unattended)
    )
    $options.SetFlowBreak($report, $true)
    $step.Controls.Add($options, 0, 3)
    #endregion

    #region Answer file step: guidance, answer files, new file, status
    $step = & $newStep 'AnswerFileStep' @(0, 1, 0, 0)
    $guidance = & $newGuidance 'AnswerFileGuidance' (
        'Answer files in the Answers folder and its subfolders. A file ' +
        'that answers none of the questions of the checked sections is ' +
        'grayed out. The next step shows its answers; you can change them ' +
        'for this restore and answer what it leaves open. Password ' +
        'answers in a file are plain text; protect it.'
    )
    $step.Controls.Add($guidance, 0, 0)

    $answerFiles = New-Object Windows.Forms.ListView
    $answerFiles.Name = 'AnswerFiles'
    $answerFiles.Dock = 'Fill'
    $answerFiles.View = 'Details'
    $answerFiles.FullRowSelect = $true
    $answerFiles.MultiSelect = $false
    $answerFiles.HideSelection = $false
    $answerFiles.ShowItemToolTips = $true
    $answerFiles.Tag = @{
        Column     = 0
        Descending = $false
        Last       = $null
    }
    $null = $answerFiles.Columns.Add('Answer file', 380)
    $null = $answerFiles.Columns.Add('Answers', 100)
    $null = $answerFiles.Columns.Add('Date modified', 150)
    $answerFiles.Add_ItemSelectionChanged({
        param($sender, $eventArgs)
        # A file that can not be used is not selected; the choice stays
        if ($eventArgs.IsSelected -and $eventArgs.Item.Tag.Usable) {
            $sender.Tag.Last = $eventArgs.Item
        }
        elseif ($eventArgs.IsSelected) {
            $eventArgs.Item.Selected = $false
            $last = $sender.Tag.Last
            if ($null -ne $last -and $null -ne $last.ListView) {
                $last.Selected = $true
            }
        }
        Update-RestoreWizardButtonsHC -Wizard (Get-RestoreWizardHC $sender)
    })
    $answerFiles.Add_ColumnClick({
        param($sender, $eventArgs)
        $sort = $sender.Tag
        if ($sort.Column -eq $eventArgs.Column) {
            $sort.Descending = -not $sort.Descending
        }
        else {
            $sort.Column = $eventArgs.Column
            $sort.Descending = $false
        }
        Update-RestoreAnswerFileListHC -Wizard (Get-RestoreWizardHC $sender)
    })
    $answerFiles.Add_DoubleClick({
        $next = Find-RestoreWizardControlHC (Get-RestoreWizardHC $this) (
            'WizardNext'
        )
        if ($next.Enabled) {
            $next.PerformClick()
        }
    })
    $step.Controls.Add($answerFiles, 0, 1)

    $newFile = New-Object Windows.Forms.FlowLayoutPanel
    $newFile.Dock = 'Fill'
    $newFile.AutoSize = $true
    $newFile.Margin = New-Object Windows.Forms.Padding 0, 8, 0, 0

    $newFileLabel = New-Object Windows.Forms.Label
    $newFileLabel.Text = 'New answer file: Answers\'
    $newFileLabel.AutoSize = $true
    $newFileLabel.Margin = New-Object Windows.Forms.Padding 0, 7, 0, 0

    $newFileName = New-Object Windows.Forms.TextBox
    $newFileName.Name = 'NewAnswerFile'
    $newFileName.AccessibleName = 'New answer file in the Answers folder'
    $newFileName.Width = 300

    $create = New-Object Windows.Forms.Button
    $create.Name = 'CreateAnswerFile'
    $create.Text = 'Create'
    $create.Size = New-Object Drawing.Size 90, 30
    $create.Add_Click({
        $owner = Get-RestoreWizardHC $this
        try {
            New-RestoreWizardAnswerFileHC -Wizard $owner
        }
        catch {
            $errorParams = @{
                Owner   = $this.FindForm()
                Text    = [string]$_
                Caption = 'Answer file error'
            }
            Show-WizardErrorHC @errorParams
        }
    })

    $refreshFiles = New-Object Windows.Forms.Button
    $refreshFiles.Name = 'RefreshAnswerFiles'
    $refreshFiles.Text = 'Refresh'
    $refreshFiles.Size = New-Object Drawing.Size 90, 30
    $refreshFiles.Add_Click({
        $owner = Get-RestoreWizardHC $this
        Update-RestoreAnswerFileListHC -Wizard $owner -Reload
    })

    $newFile.Controls.AddRange(
        @($newFileLabel, $newFileName, $create, $refreshFiles)
    )
    $step.Controls.Add($newFile, 0, 2)

    $status = & $newGuidance 'AnswerFileStatus' ''
    $status.Margin = New-Object Windows.Forms.Padding 0, 4, 0, 0
    $step.Controls.Add($status, 0, 3)
    #endregion

    #region Questions step: guidance, answers, summary
    $step = & $newStep 'QuestionsStep' @(0, 1, 0)
    $guidance = & $newGuidance 'QuestionsGuidance' (
        'Answer the questions of the checked sections. Click an answer to ' +
        'type it or choose it from the list. Answers from the answer file ' +
        'can be changed for this restore only; the file stays unchanged. ' +
        'Click Back to change the sections or the answer file; your ' +
        'changes are kept. Reload answer file reads the file again and ' +
        'puts its answers back.'
    )
    $step.Controls.Add($guidance, 0, 0)

    # Filled by Set-RestoreWizardQuestionsHC
    $gridHost = New-Object Windows.Forms.Panel
    $gridHost.Name = 'AnswerGridHost'
    $gridHost.Dock = 'Fill'
    $gridHost.Margin = New-Object Windows.Forms.Padding 0
    $step.Controls.Add($gridHost, 0, 1)

    $gridSummary = & $newGuidance 'AnswerGridSummary' ''
    $gridSummary.Margin = New-Object Windows.Forms.Padding 0, 8, 0, 0
    $step.Controls.Add($gridSummary, 0, 2)
    #endregion

    #region Review step: overview, sections and answers, guidance
    $step = & $newStep 'ReviewStep' @(0, 1, 0)

    # A card with a caption and a value for each choice
    $overview = New-Object Windows.Forms.TableLayoutPanel
    $overview.Name = 'ReviewSummary'
    $overview.Dock = 'Fill'
    $overview.AutoSize = $true
    $overview.BackColor = [Drawing.SystemColors]::Window
    $overview.Padding = New-Object Windows.Forms.Padding 12, 10, 12, 10
    $overview.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $overview.ColumnCount = 2
    $null = $overview.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::AutoSize)
    )
    $null = $overview.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $sizeType::Percent, 100)
    )
    $captionFont = New-Object Drawing.Font (
        $Font.FontFamily, 9, [Drawing.FontStyle]::Bold
    )
    $choices = [ordered]@{
        ReviewConfiguration = 'Configuration'
        ReviewAnswerFile    = 'Answer file'
        ReviewRestart       = 'Restart'
        ReviewReport        = 'Report'
        ReviewUnattended    = 'Unattended'
    }
    foreach ($name in $choices.Keys) {
        $caption = New-Object Windows.Forms.Label
        $caption.Name = "${name}Caption"
        $caption.Text = $choices[$name]
        $caption.Font = $captionFont
        $caption.ForeColor = [Drawing.Color]::DimGray
        $caption.AutoSize = $true
        $caption.Margin = New-Object Windows.Forms.Padding 0, 4, 16, 4

        $value = New-Object Windows.Forms.Label
        $value.Name = $name
        $value.UseMnemonic = $false
        $value.AutoSize = $true
        $value.Margin = New-Object Windows.Forms.Padding 0, 3, 0, 3

        $overview.Controls.AddRange(@($caption, $value))
    }
    $step.Controls.Add($overview, 0, 0)

    $reviewAnswers = New-Object Windows.Forms.ListView
    $reviewAnswers.Name = 'ReviewAnswers'
    $reviewAnswers.Dock = 'Fill'
    $reviewAnswers.View = 'Details'
    $reviewAnswers.FullRowSelect = $true
    $reviewAnswers.HeaderStyle = 'Nonclickable'
    $null = $reviewAnswers.Columns.Add('Question', 330)
    $null = $reviewAnswers.Columns.Add('Answer', 200)
    $null = $reviewAnswers.Columns.Add('From', 110)
    $step.Controls.Add($reviewAnswers, 0, 1)

    $guidance = & $newGuidance 'ReviewGuidance' (
        'Nothing is changed before you click Restore. Click Back to change ' +
        'anything.'
    )
    $guidance.Margin = New-Object Windows.Forms.Padding 0, 8, 0, 0
    $step.Controls.Add($guidance, 0, 2)
    #endregion

    #region Buttons
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'

    $next = New-Object Windows.Forms.Button
    $next.Name = 'WizardNext'
    $next.Text = 'Next >'
    $next.Size = New-Object Drawing.Size 130, 34
    Set-WizardPrimaryButtonHC $next
    $next.Add_Click({
        $owner = Get-RestoreWizardHC $this
        try {
            Invoke-RestoreWizardNextHC -Wizard $owner
        }
        catch {
            $errorParams = @{
                Owner   = $this.FindForm()
                Text    = [string]$_
                Caption = 'Restore error'
            }
            Show-WizardErrorHC @errorParams
        }
    })

    $back = New-Object Windows.Forms.Button
    $back.Name = 'WizardBack'
    $back.Text = '< Back'
    $back.Size = New-Object Drawing.Size 100, 34
    $back.Add_Click({
        Show-RestoreWizardStepHC -Wizard (Get-RestoreWizardHC $this) -Back
    })

    $reload = New-Object Windows.Forms.Button
    $reload.Name = 'ReloadAnswerFile'
    $reload.Text = 'Reload answer file'
    $reload.Size = New-Object Drawing.Size 160, 34
    $reload.Add_Click({
        try {
            Reset-RestoreWizardAnswersHC -Wizard (Get-RestoreWizardHC $this)
        }
        catch {
            $errorParams = @{
                Owner   = $this.FindForm()
                Text    = [string]$_
                Caption = 'Answer file error'
            }
            Show-WizardErrorHC @errorParams
        }
    })

    $refresh = New-Object Windows.Forms.Button
    $refresh.Name = 'RefreshConfigurations'
    $refresh.Text = 'Refresh'
    $refresh.Size = New-Object Drawing.Size 100, 34
    $refresh.Add_Click({
        $owner = Get-RestoreWizardHC $this
        try {
            Update-RestoreConfigurationListHC -Wizard $owner
        }
        catch {
            $errorParams = @{
                Owner   = $this.FindForm()
                Text    = [string]$_
                Caption = 'Configuration error'
            }
            Show-WizardErrorHC @errorParams
        }
    })

    $clear = New-Object Windows.Forms.Button
    $clear.Name = 'ClearAll'
    $clear.Text = 'Clear all'
    $clear.Size = New-Object Drawing.Size 100, 34
    $clear.Add_Click({
        $owner = Get-RestoreWizardHC $this
        $checkParams = @{
            ItemList = Find-RestoreWizardControlHC $owner 'SnapshotItems'
            Checked  = $false
        }
        Set-SnapshotItemsCheckedHC @checkParams
    })

    $all = New-Object Windows.Forms.Button
    $all.Name = 'SelectAll'
    $all.Text = 'Select all'
    $all.Size = New-Object Drawing.Size 100, 34
    $all.Add_Click({
        $owner = Get-RestoreWizardHC $this
        $checkParams = @{
            ItemList = Find-RestoreWizardControlHC $owner 'SnapshotItems'
            Checked  = $true
        }
        Set-SnapshotItemsCheckedHC @checkParams
    })

    $buttons.Controls.AddRange(
        @($next, $back, $reload, $refresh, $clear, $all)
    )
    $wizard.Controls.Add($buttons, 0, 2)
    #endregion

    Show-RestoreWizardStepHC -Wizard $wizard -Step 'Configuration'

    return , $wizard
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
        PassThru     = $true
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
    # The process, so the caller can wait for it without blocking
    Start-Process @parameters
}

function Wait-WizardProcessHC {
    <#
    .SYNOPSIS
        Keep a button disabled while the process it started runs, and
        enable it again once the process has ended.
    .DESCRIPTION
        Disable the button before starting the process. A timer checks the
        process on the window thread, so the window stays responsive.
        Without a running process the button is enabled at once.
    #>
    param(
        [Parameter(Mandatory)][Windows.Forms.Button]$Button,
        [AllowNull()]$Process,
        [string]$BusyText,
        [int]$Interval = 500
    )

    $isRunning = {
        param($process)
        try {
            # Unknown, such as an inaccessible process, counts as ended
            $null -ne $process -and $process.HasExited -eq $false
        }
        catch {
            $false
        }
    }

    if (-not (& $isRunning $Process)) {
        $Button.Enabled = $true
        return
    }

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = $Interval
    $timer.Tag = @{
        Button    = $Button
        Process   = $Process
        Text      = $Button.Text
        IsRunning = $isRunning
    }
    $Button.Enabled = $false
    if ($BusyText) {
        $Button.Text = $BusyText
    }
    $timer.Add_Tick({
        $wait = $this.Tag
        if (& $wait.IsRunning $wait.Process) {
            return
        }
        $this.Stop()
        if (-not $wait.Button.IsDisposed) {
            $wait.Button.Text = $wait.Text
            $wait.Button.Enabled = $true
        }
        $wait.Process.Dispose()
        $this.Dispose()
    })
    $timer.Start()
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
$header = New-WizardHeaderHC -ElevationPanel $elevationPanel
$wizardLayout.Controls.Add($header, 0, 0)
$wizardLayout.Controls.Add($tabs, 0, 1)

#region Restore tab
$restoreWizard = New-RestoreWizardHC -RootFolder $RootFolder -Font $form.Font
$restoreTab.Controls.Add($restoreWizard)

# The header shows what is restored; an export restores nothing
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $restoreTab) {
        Update-RestoreWizardHeaderHC -Wizard $restoreWizard
    }
    else {
        Show-WizardHeaderHC -Form $form
    }
})
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
    'Save selected sections to a JSON file in Configurations. A section ' +
    'with nothing to export, such as Software, is saved empty, ready to ' +
    'fill in (see Examples); an empty section is skipped on restore.'
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

$itemListParams = @{
    Entries         = @(Get-SnapshotItemEntriesHC)
    SelectAllHeader = $true
}
$itemList = New-SnapshotItemListHC @itemListParams
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
    # One export at a time: the button stays disabled until it is done
    $export.Enabled = $false
    $process = $null
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
        $process = Start-ConfigurationJobHC @jobParams @jobOptions
    }
    catch {
        $null = [Windows.Forms.MessageBox]::Show(
            $form, [string]$_, 'Export error', 'OK', 'Error'
        )
    }
    finally {
        $waitParams = @{
            Button   = $export
            Process  = $process
            BusyText = 'Exporting...'
        }
        Wait-WizardProcessHC @waitParams
    }
})
#endregion

$form.Add_Shown({
    try {
        Update-RestoreConfigurationListHC -Wizard $restoreWizard
    }
    catch {
        $errorParams = @{
            Owner   = $form
            Text    = [string]$_
            Caption = 'Configuration error'
        }
        Show-WizardErrorHC @errorParams
    }
})

Write-Verbose 'Show the wizard window'
try {
    $null = $form.ShowDialog()
}
finally {
    # A restore that has not read its answers yet asks for them itself
    foreach ($server in $restoreWizard.Tag.AnswerServers) {
        $server.PowerShell.Stop()
        $server.PowerShell.Dispose()
    }
    $form.Dispose()
}
#endregion
