#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    . "$PSScriptRoot\..\Scripts\Invoke GUI.ps1" -NoShow
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
}
Describe 'Restore input popup' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    It 'displays the field description and masks password input without modifying the supplied value' {
        $field = [pscustomobject]@{ Kind = 'password'; Description = 'Password for the local kiosk account'; Path = 'Items.UserAccounts[0].Password' }
        $dialog = New-RestoreInputFormHC -Field $field
        try {
            $dialog.Show()
            $dialog.Controls.Find('InputDescription', $true)[0].Text | Should -Be $field.Description
            $inputBox = $dialog.Controls.Find('InputValue', $true)[0]
            $confirm = $dialog.Controls.Find('ConfirmInput', $true)[0]
            $inputBox.UseSystemPasswordChar | Should -BeTrue
            $confirm.Enabled | Should -BeFalse
            $inputBox.Text = 'Test-only password!"\$'
            $confirm.Enabled | Should -BeTrue
            $confirm.PerformClick()
            $dialog.Tag.Value | Should -BeExactly 'Test-only password!"\$'
            $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::OK)
        }
        finally { $dialog.Dispose() }
    }
    It 'rejects invalid IPv4 input and supports cancellation without an answer' {
        $field = [pscustomobject]@{ Kind = 'ipv4'; Description = 'IPv4 address for Ethernet'; Path = 'Items.NetworkCards[0].IPSettings.IPAddress' }
        $dialog = New-RestoreInputFormHC -Field $field
        try {
            $dialog.Show()
            $inputBox = $dialog.Controls.Find('InputValue', $true)[0]
            $confirm = $dialog.Controls.Find('ConfirmInput', $true)[0]
            $inputBox.UseSystemPasswordChar | Should -BeFalse
            $inputBox.Text = '999.1.1.1'
            $confirm.Enabled | Should -BeFalse
            $inputBox.Text = '192.0.2.10'
            $confirm.Enabled | Should -BeTrue
            $dialog.CancelButton.PerformClick()
            $dialog.Tag.Value | Should -BeNullOrEmpty
            $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::Cancel)
        }
        finally { $dialog.Dispose() }
    }
}

Describe 'Wizard console welcome' {
    BeforeEach {
        Mock Clear-Host
        Mock Write-Host
        Mock Test-WizardElevatedHC { $false }
        $console = [pscustomobject]@{ BackgroundColor = [ConsoleColor]::DarkBlue; ForegroundColor = [ConsoleColor]::Yellow; WindowTitle = 'PowerShell' }
    }
    It 'sets a black console and shows ASCII art with launch details' {
        Show-WizardConsoleHC -ConsoleUI $console -ComputerName 'TEST-PC' -UserName 'DOMAIN\Example' -StartedAt ([datetime]'2026-10-22T08:42:04')
        $console.BackgroundColor | Should -Be ([ConsoleColor]::Black)
        $console.ForegroundColor | Should -Be ([ConsoleColor]::Gray)
        $console.WindowTitle | Should -Be 'Computer Snapshot | TEST-PC'
        Should -Invoke Clear-Host -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*COMPUTER SNAPSHOT*' -and $Object -like '*[[] SNAPSHOT ]*' -and
            $Object -notmatch '[^\x00-\x7F]' -and $BackgroundColor -eq 'Black'
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Hostname   : TEST-PC*' -and $Object -like '*2026-10-22 08:42:04*' -and
            $Object -like '*User       : DOMAIN\Example*' -and $Object -like '*PowerShell :*' -and
            $Object -like '*Standard (not elevated)*' -and $BackgroundColor -eq 'Black'
        }
    }
    It 'identifies an elevated session' {
        Mock Test-WizardElevatedHC { $true }
        Show-WizardConsoleHC -ConsoleUI $console
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Access     : Administrator*' }
    }
    It 'continues when console customization is unavailable' {
        Mock Clear-Host { throw 'Unsupported console operation' }
        { Show-WizardConsoleHC -ConsoleUI $console } | Should -Not -Throw
        Should -Invoke Write-Host -Times 3 -Exactly
    }
    It 'supports hosts without a raw console' {
        { Show-WizardConsoleHC -ConsoleUI $null } | Should -Not -Throw
        Should -Invoke Clear-Host -Times 0 -Exactly
        Should -Invoke Write-Host -Times 3 -Exactly
    }
    It 'does not clear or print a welcome when loading with NoShow' {
        . "$PSScriptRoot\..\Scripts\Invoke GUI.ps1" -NoShow
        Should -Invoke Clear-Host -Times 0 -Exactly
        Should -Invoke Write-Host -Times 0 -Exactly
    }
}

Describe 'Single-file wizard commands' {
    BeforeEach {
        Mock Start-Process
    }
    It 'launches an export without creating a configuration or temporary files' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Kiosk example' -Items UserAccounts, Software -OpenReportInBrowser $false
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count | Should -Be $before
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command -like '*-Action CreateSnapshot*' -and $command -like '*Configurations\Kiosk example.json*' -and $command -like '*-Items*UserAccounts*Software*'
        }
    }
    It 'includes HHmmss in the suggested export filename' {
        Mock Get-Date { '2026-10-21 142536' } -ParameterFilter { $Format -eq 'yyyy-MM-dd HHmmss' }
        $name = Get-DefaultConfigurationNameHC
        $name | Should -BeExactly "$env:COMPUTERNAME 2026-10-21 142536"
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name $name -Items UserAccounts
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command -like '* 2026-10-21 142536.json*'
        }
    }
    It 'rejects directory traversal in a configuration name' {
        { Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name '..\outside' -Items UserAccounts } | Should -Throw '*file name*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'requires at least one selected export item' {
        { Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Example' -Items @() } | Should -Throw '*Select at least one*'
    }
    It 'launches restore through the configuration launcher' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1])) -like '*Invoke configuration.ps1*-ConfigurationFile*Example.json*'
        }
    }
        It 'passes a quoted answer-file path and unattended mode without putting answers in the command' {
            $file = Join-Path $TestDrive 'answer-configuration.json'
            '{"SchemaVersion":3,"Items":{"UserAccounts":[]}}' | Set-Content -LiteralPath $file
            $answerFile = Join-Path $TestDrive "kiosk's answers.json"
            '{"Answers":{"{{password:Password}}":"PRIVATE-ANSWER"}}' | Set-Content -LiteralPath $answerFile
            Mock Test-WizardElevatedHC { $true }
            Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $file -AnswerFile $answerFile -Unattended
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
                $command.Contains("kiosk''s answers.json'") -and $command.Contains(' -AnswerFile ') -and
                $command.Contains(' -Unattended') -and $command -notmatch 'PRIVATE-ANSWER' -and
                $ArgumentList -contains '-NonInteractive' -and -not $Verb
            }
        }
        It 'refuses a missing answer file or an unattended UAC requirement before launching' {
            $file = Join-Path $TestDrive 'elevated-answer-configuration.json'
            '{"SchemaVersion":3,"Settings":{"RunElevated":true},"Items":{"UserAccounts":[]}}' | Set-Content -LiteralPath $file
            Mock Test-WizardElevatedHC { $false }
            { Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $file -AnswerFile 'missing.answers.json' } |
                Should -Throw '*not found*'
            { Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $file -Unattended } |
                Should -Throw '*administrator rights*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
        It 'refuses unattended without administrator rights, RunElevated <RunElevated>' -ForEach @(
            @{ RunElevated = 'true' }
            @{ RunElevated = 'false' }
        ) {
            $file = Join-Path $TestDrive 'unattended-configuration.json'
            '{"SchemaVersion":3,"Settings":{"RunElevated":' + $RunElevated +
            '},"Items":{"UserAccounts":[]}}' |
            Set-Content -LiteralPath $file
            Mock Test-WizardElevatedHC { $false }

            {
                Start-ConfigurationJobHC -Action RestoreSnapshot `
                    -RootFolder $TestDrive -ConfigurationFile $file -Unattended
            } | Should -Throw 'Unattended restore requires administrator rights.*'

            Should -Invoke Start-Process -Times 0 -Exactly
        }
    It 'passes checked restore keys to the configuration launcher' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile -Items UserAccounts, Software
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command.Contains("-Items @('UserAccounts','Software')")
        }
    }
    It 'rejects an empty restore selection before launching' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        { Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile -Items @() } | Should -Throw '*Select at least one*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'passes explicit restore setting choices without adding defaults when omitted' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile -Items UserAccounts -RebootComputer $true -RestartDelaySeconds 300 -OpenReportInBrowser $false
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command.Contains('-RebootComputer $true') -and $command.Contains('-RestartDelaySeconds 300') -and $command.Contains('-OpenReportInBrowser $false')
        }
        Start-ConfigurationJobHC -Action RestoreSnapshot -RootFolder $TestDrive -ConfigurationFile $testFile -Items UserAccounts
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $command -notmatch 'RebootComputer|RestartDelaySeconds|OpenReportInBrowser'
        }
    }
    It 'uses configuration defaults when restore settings are missing and rejects non-Boolean values' {
        $testFile = Join-Path $TestDrive 'Settings.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[]}}' | Set-Content -LiteralPath $testFile
        $settings = Get-RestoreSettingsHC -ConfigurationFile $testFile
        $settings.RebootComputer | Should -BeFalse
        $settings.OpenReportInBrowser | Should -BeTrue
        $settings.RestartDelaySeconds | Should -Be 60
        '{"Settings":{"RebootComputer":"false"}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreSettingsHC -ConfigurationFile $testFile } | Should -Throw '*must be a Boolean*'
        '{"Settings":{"RestartDelaySeconds":601}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreSettingsHC -ConfigurationFile $testFile } | Should -Throw '*0 to 600*'
    }
    It 'provides readable labels and descriptions for every supported item' {
        $entries = @(Get-SnapshotItemEntriesHC)
        @($entries.Key) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        foreach ($entry in $entries) {
            $entry.Name | Should -Not -BeNullOrEmpty
            $entry.Description | Should -Not -BeNullOrEmpty
            $entry.Available | Should -BeTrue
        }
        ($entries | Where-Object Key -eq 'CopyFilesFolders').Name | Should -Be 'Copy files and folders'
    }
    It 'lists all sections but only marks configured sections available without resolving references' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{"SchemaVersion":3,"Items":{"Software":{"Install":[{"ExecutablePath":"example.exe"}]},"UserAccounts":"missing.json","Comment":"Example"}}' | Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries.Key) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        @($entries | Where-Object Available | ForEach-Object Key) | Should -Be @('UserAccounts', 'Software')
        @($entries | Where-Object { -not $_.Available }).Count | Should -Be ($entries.Count - 2)
    }
    It 'disables empty arrays, objects, nulls, blank references and comment-only sections' {
        $testFile = Join-Path $TestDrive 'Empty sections.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[],"Software":{},"RegionalSettings":null,"UserGroups":" ","CreateFolders":{"Comment":"No folders"}}}' | Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries | Where-Object Available).Count | Should -Be 0
    }
    It 'rejects legacy or empty configurations in the restore overview' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{"StartScript":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } | Should -Throw '*version-3*'
        '{"SchemaVersion":3,"Items":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } | Should -Throw '*no items*'
    }
}

Describe 'Export scheduled task folders' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    BeforeEach {
        Mock Start-Process
    }
    It 'passes the folders as export options, quoted so a name cannot break the command' {
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Tasks' -Items ScheduledTasks -TaskFolders '\HC\', "\It's\"
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$parseErrors)
            $command.Contains("-ExportOptions @{ ScheduledTasks = @{ TaskPath = @('\HC\','\It''s\') } }") -and $parseErrors.Count -eq 0
        }
    }
    It 'adds no export options when scheduled tasks are not exported' {
        Start-ConfigurationJobHC -Action CreateSnapshot -RootFolder $TestDrive -Name 'Users' -Items UserAccounts -TaskFolders '\HC\'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1])) -notmatch 'ExportOptions'
        }
    }
    It 'reads comma-separated folders, uses the export default when empty and rejects invalid names' {
        @(Get-WizardTaskFolderHC -Text '') | Should -Be @('\HC\')
        @(Get-WizardTaskFolderHC -Text ' HC, Vendor\Sub ,, \HC\ ') | Should -Be @('\HC\', '\Vendor\Sub\')
        @(Get-WizardTaskFolderHC -Text '\') | Should -Be @('\')
        { Get-WizardTaskFolderHC -Text '\HC\, Ven|dor' } | Should -Throw "*'\Ven|dor\'*not allowed*"
    }
    It 'asks for confirmation only for the root folder' {
        Mock Show-WizardQuestionHC { [Windows.Forms.DialogResult]::No }
        Confirm-WizardTaskFolderHC -Folders '\HC\', '\Vendor\' | Should -BeTrue
        Should -Invoke Show-WizardQuestionHC -Times 0 -Exactly
        Confirm-WizardTaskFolderHC -Folders '\HC\', '\' | Should -BeFalse
        Mock Show-WizardQuestionHC { [Windows.Forms.DialogResult]::Yes }
        Confirm-WizardTaskFolderHC -Folders '\' | Should -BeTrue
        Should -Invoke Show-WizardQuestionHC -Times 2 -Exactly -ParameterFilter { $Text -like '*every scheduled task*' }
    }
    It 'shows the export default and is enabled only while Scheduled tasks is checked' {
        $form = New-Object Windows.Forms.Form
        try {
            $form.ClientSize = New-Object Drawing.Size 650, 300
            $list = New-SnapshotItemListHC -Entries @(Get-SnapshotItemEntriesHC)
            $panel = New-ExportTaskFolderPanelHC -ItemList $list
            $list.Dock = 'Top'
            $panel.Dock = 'Bottom'
            $form.Controls.AddRange(@($list, $panel))
            $form.Show()
            $box = $panel.Controls.Find('ScheduledTaskFolders', $false)[0]
            $box.Text | Should -BeExactly ((Get-ExportTaskFolderHC) -join ', ')
            $box.Enabled | Should -BeTrue
            $tasks = $list.Items | Where-Object Tag -EQ 'ScheduledTasks'
            $tasks.Checked = $false
            foreach ($control in $panel.Controls) { $control.Enabled | Should -BeFalse }
            $tasks.Checked = $true
            foreach ($control in $panel.Controls) {
                $control.Enabled | Should -BeTrue
                $control.Right | Should -BeLessOrEqual $panel.ClientSize.Width
            }
        }
        finally { $form.Dispose() }
    }
}

Describe 'Optional wizard elevation' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    BeforeEach {
        Mock Start-Process
        Mock Test-WizardElevatedHC { $false }
    }
    It 'requests native UAC elevation and preserves quoted script and root paths' {
        $root = "C:\Snapshot user's files"
        $scriptPath = "$root\Scripts\Invoke GUI.ps1"
        Restart-WizardElevatedHC -RootFolder $root -WizardScript $scriptPath | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $Verb -eq 'RunAs' -and $ArgumentList -contains '-STA' -and $ErrorAction -eq 'Stop' -and
            $command -eq "& 'C:\Snapshot user''s files\Scripts\Invoke GUI.ps1' -RootFolder 'C:\Snapshot user''s files'"
        }
    }
    It 'returns without restarting when UAC is cancelled' {
        Mock Start-Process { throw (New-Object System.ComponentModel.Win32Exception 1223) }
        Restart-WizardElevatedHC -RootFolder $TestDrive -WizardScript 'C:\Wizard.ps1' | Should -BeFalse
    }
    It 'propagates launch errors other than cancellation' {
        Mock Start-Process { throw (New-Object System.ComponentModel.Win32Exception 2) }
        { Restart-WizardElevatedHC -RootFolder $TestDrive -WizardScript 'C:\Wizard.ps1' } | Should -Throw
    }
    It 'distinguishes administrator restart with a shield and accessible accent color' {
        $panel = New-WizardElevationPanelHC -RootFolder $TestDrive -WizardScript 'C:\Wizard.ps1'
        try {
            $button = $panel.Controls.Find('RestartAsAdministrator', $true)[0]
            $button.Image | Should -Not -BeNullOrEmpty
            $button.Image.Width | Should -Be 16
            $button.TextImageRelation | Should -Be ([Windows.Forms.TextImageRelation]::ImageBeforeText)
            if (-not [Windows.Forms.SystemInformation]::HighContrast) {
                $button.BackColor | Should -Be ([Drawing.Color]::FromArgb(245, 199, 92))
                $button.ForeColor | Should -Be ([Drawing.Color]::FromArgb(40, 35, 20))
            }
        }
        finally { $panel.Dispose() }
    }
    It 'omits the button when already elevated' {
        Mock Test-WizardElevatedHC { $true }
        New-WizardElevationPanelHC -RootFolder $TestDrive -WizardScript 'C:\Wizard.ps1' | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'keeps the original wizard open after cancellation and closes it after a successful launch' {
        $window = New-Object Windows.Forms.Form
        try {
            $panel = New-WizardElevationPanelHC -RootFolder $TestDrive -WizardScript 'C:\Wizard.ps1'
            $window.Controls.Add($panel)
            $window.Show()
            $button = $window.Controls.Find('RestartAsAdministrator', $true)[0]
            $button.Visible | Should -BeTrue
            Should -Invoke Start-Process -Times 0 -Exactly
            Mock Start-Process { throw (New-Object System.ComponentModel.Win32Exception 1223) }
            $button.PerformClick()
            $window.Visible | Should -BeTrue
            Mock Start-Process {}
            $button.PerformClick()
            $window.Visible | Should -BeFalse
            Should -Invoke Start-Process -Times 2 -Exactly
        }
        finally { $window.Dispose() }
    }
}

Describe 'Restore selection controls' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    It 'shows answer-file and template controls and makes unattended mode disable browser opening' {
        $file = Join-Path $TestDrive 'answer-controls.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[]},"Settings":{"OpenReportInBrowser":true}}' | Set-Content -LiteralPath $file
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Answers' -ConfigurationFile $file -RootFolder $TestDrive -Entries @(Get-SnapshotItemEntriesHC)
        try {
            $dialog.Show()
            $path = $dialog.Controls.Find('AnswerFile', $true)[0]
            $path.Text | Should -Be ''
            $dialog.Controls.Find('BrowseAnswerFile', $true)[0].Enabled | Should -BeTrue
            $dialog.Controls.Find('CreateAnswerTemplate', $true)[0].Enabled | Should -BeTrue
            $dialog.Controls.Find('AnswerFileGuidance', $true)[0].Text | Should -Match 'Invalid answers always fail'
            $unattended = $dialog.Controls.Find('Unattended', $true)[0]
            $report = $dialog.Controls.Find('OpenReportInBrowser', $true)[0]
            $unattended.Checked | Should -BeFalse
            $report.Checked | Should -BeTrue
            $unattended.Checked = $true
            $report.Checked | Should -BeFalse
            $report.Enabled | Should -BeFalse
            $unattended.Checked = $false
            $report.Enabled | Should -BeTrue
            $report.Checked | Should -BeTrue
            foreach ($name in @('AnswerFile', 'BrowseAnswerFile', 'CreateAnswerTemplate', 'Unattended', 'AnswerFileGuidance')) {
                $control = $dialog.Controls.Find($name, $true)[0]
                $control.Visible | Should -BeTrue
                $control.Right | Should -BeLessOrEqual $control.Parent.ClientSize.Width
                $control.Bottom | Should -BeLessOrEqual $control.Parent.ClientSize.Height
            }
        }
        finally { $dialog.Dispose() }
    }
    It 'emphasizes the primary restore action and neutralizes it while disabled' {
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Primary action' -Entries @(Get-SnapshotItemEntriesHC -Items UserAccounts)
        try {
            $dialog.Show()
            $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
            if (-not [Windows.Forms.SystemInformation]::HighContrast) {
                $confirm.BackColor | Should -Be ([Drawing.Color]::FromArgb(0, 103, 184))
                $confirm.ForeColor | Should -Be ([Drawing.Color]::White)
                ($confirm.Parent.Controls | Where-Object Text -eq 'Clear all').PerformClick()
                $confirm.Enabled | Should -BeFalse
                $confirm.BackColor | Should -Be ([Drawing.SystemColors]::Control)
                ($confirm.Parent.Controls | Where-Object Text -eq 'Select all').PerformClick()
                $confirm.BackColor | Should -Be ([Drawing.Color]::FromArgb(0, 103, 184))
            }
        }
        finally { $dialog.Dispose() }
    }
    It 'fits the initial window height to the rendered checklist without spare rows' {
        foreach ($entries in @(@(Get-SnapshotItemEntriesHC -Items UserAccounts, Software), @(Get-SnapshotItemEntriesHC))) {
            $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Fit checklist' -Entries $entries
            try {
                $dialog.Show()
                [Windows.Forms.Application]::DoEvents()
                $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
                $lastRow = $list.Items[$list.Items.Count - 1]
                $remaining = $list.ClientSize.Height - $lastRow.Bounds.Bottom
                $remaining | Should -BeGreaterOrEqual 0
                $remaining | Should -BeLessOrEqual 4
                $report = $dialog.Controls.Find('OpenReportInBrowser', $true)[0]
                $list.Bottom | Should -BeLessOrEqual $report.Parent.Top
                $dialog.Height | Should -BeLessOrEqual ([Windows.Forms.Screen]::FromControl($dialog).WorkingArea.Height)
            }
            finally { $dialog.Dispose() }
        }
    }
    It 'caps tall checklists at the available screen height and leaves them scrollable' {
        $entries = @(1..100 | ForEach-Object { Get-SnapshotItemEntriesHC -Items UserAccounts })
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Tall checklist' -Entries $entries
        try {
            $dialog.Show()
            [Windows.Forms.Application]::DoEvents()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $workingArea = [Windows.Forms.Screen]::FromControl($dialog).WorkingArea
            $dialog.Height | Should -BeLessOrEqual $workingArea.Height
            $dialog.Top | Should -BeGreaterOrEqual $workingArea.Top
            $dialog.Bottom | Should -BeLessOrEqual $workingArea.Bottom
            $list.Items[99].Bounds.Bottom | Should -BeGreaterThan $list.ClientSize.Height
            $list.EnsureVisible(99)
            $list.Items[99].Bounds.Bottom | Should -BeLessOrEqual $list.ClientSize.Height
        }
        finally { $dialog.Dispose() }
    }
    It 'frames the selected description without a heading and separates it from restore guidance' {
        $path = "$PSScriptRoot\..\Configurations\Example PC1.json"
        $expected = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Description
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Example PC1' -Entries @(Get-RestoreItemEntriesHC -ConfigurationFile $path) -ConfigurationFile $path
        try {
            $dialog.Show()
            $description = $dialog.Controls.Find('ConfigurationDescription', $true)[0]
            $guidance = $dialog.Controls.Find('RestoreGuidance', $true)[0]
            $dialog.Controls.Find('ConfigurationDescriptionHeading', $true).Count | Should -Be 0
            $description.BorderStyle | Should -Be ([Windows.Forms.BorderStyle]::FixedSingle)
            $description.Padding.All | Should -Be 10
            $description.AccessibleName | Should -Be 'Configuration description'
            $description.Text | Should -BeExactly $expected
            $description.Bottom | Should -BeLessThan $guidance.Top
            $guidance.Text | Should -BeLike 'Choose the sections to apply*'
            $guidance.Font.Size | Should -BeLessThan $description.Font.Size
            $guidance.Font.Size | Should -Be 9
        }
        finally { $dialog.Dispose() }
    }
    It 'wraps long descriptions literally and provides a fallback for missing descriptions' {
        $path = Join-Path $TestDrive 'Description.json'
        $text = 'Users & applications for this workstation. ' * 6
        @{ Description = $text } | ConvertTo-Json | Set-Content -LiteralPath $path
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Long description' -Entries @(Get-SnapshotItemEntriesHC) -ConfigurationFile $path
        try {
            $dialog.Size = $dialog.MinimumSize
            $dialog.Show()
            $description = $dialog.Controls.Find('ConfigurationDescription', $true)[0]
            $guidance = $dialog.Controls.Find('RestoreGuidance', $true)[0]
            $description.Text | Should -BeExactly $text
            $description.UseMnemonic | Should -BeFalse
            $description.Height | Should -BeGreaterThan $description.Font.Height
            $description.Bottom | Should -BeLessThan $guidance.Top
            $description.Right | Should -BeLessOrEqual $description.Parent.ClientSize.Width
        }
        finally { $dialog.Dispose() }
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'No description' -Entries @(Get-SnapshotItemEntriesHC)
        try {
            $dialog.Controls.Find('ConfigurationDescription', $true)[0].Text | Should -Be 'No description provided.'
        }
        finally { $dialog.Dispose() }
    }
    It 'initializes separate restore options from the file and permits unsaved overrides' {
        $testFile = Join-Path $TestDrive 'Options.json'
        foreach ($saved in @($false, $true)) {
            @{ SchemaVersion = 3; Settings = @{ RebootComputer = $saved; OpenReportInBrowser = -not $saved }; Items = @{ UserAccounts = @(@{ Name = 'Example' }) } } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testFile
            $before = Get-Content -LiteralPath $testFile -Raw
            $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Options' -Entries @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile) -ConfigurationFile $testFile
            try {
                $dialog.Show()
                $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
                $reboot = $dialog.Controls.Find('RebootComputer', $true)[0]
                $report = $dialog.Controls.Find('OpenReportInBrowser', $true)[0]
                $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
                $reboot.Checked | Should -Be $saved
                $report.Checked | Should -Be (-not $saved)
                $reboot.Parent | Should -Not -Be $list
                $report.Parent | Should -Not -Be $list
                $reboot.Checked = -not $saved
                $report.Checked = $saved
                ($confirm.Parent.Controls | Where-Object Text -eq 'Clear all').PerformClick()
                ($confirm.Parent.Controls | Where-Object Text -eq 'Select all').PerformClick()
                $reboot.Checked | Should -Be (-not $saved)
                $report.Checked | Should -Be $saved
                $confirm.PerformClick()
                $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::OK)
                (Get-Content -LiteralPath $testFile -Raw) | Should -BeExactly $before
            }
            finally { $dialog.Dispose() }
        }
    }
    It 'shows the saved restart countdown, enabled only while restart is checked' {
        $testFile = Join-Path $TestDrive 'Delay.json'
        @{ SchemaVersion = 3; Settings = @{ RebootComputer = $false; RestartDelaySeconds = 300 }; Items = @{ UserAccounts = @(@{ Name = 'Example' }) } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testFile
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Delay' -Entries @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile) -ConfigurationFile $testFile
        try {
            $dialog.Show()
            $reboot = $dialog.Controls.Find('RebootComputer', $true)[0]
            $delay = $dialog.Controls.Find('RestartDelaySeconds', $true)[0]
            $delay.Value | Should -Be 300
            $delay.Minimum | Should -Be 0
            $delay.Maximum | Should -Be 600
            $delay.Enabled | Should -BeFalse
            $reboot.Checked = $true
            $delay.Enabled | Should -BeTrue
            $dialog.Controls.Find('RestartDelayLabel', $true)[0].Enabled | Should -BeTrue
            $reboot.Checked = $false
            $delay.Enabled | Should -BeFalse
        }
        finally { $dialog.Dispose() }
    }
    It 'toggles item and description clicks but leaves checkbox clicks and disabled rows alone' {
        $entries = @(Get-SnapshotItemEntriesHC -Items UserAccounts, Software)
        $entries[1].Available = $false
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Click test' -Entries $entries
        try {
            $dialog.Show()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $mouseClick = $list.GetType().GetMethod('OnMouseClick', [Reflection.BindingFlags]'Instance, NonPublic')
            $row = $list.Items[0]
            $rowY = $row.Bounds.Top + [int]($row.Bounds.Height / 2)
            foreach ($columnX in @(80, 300)) {
                $eventArgs = New-Object Windows.Forms.MouseEventArgs ([Windows.Forms.MouseButtons]::Left), 1, $columnX, $rowY, 0
                $null = $mouseClick.Invoke($list, @($eventArgs.PSObject.BaseObject))
                $row.Checked | Should -BeFalse
                $null = $mouseClick.Invoke($list, @($eventArgs.PSObject.BaseObject))
                $row.Checked | Should -BeTrue
            }
            $checkboxX = $row.Bounds.Left + 4
            ($list.HitTest($checkboxX, $rowY).Location -band [Windows.Forms.ListViewHitTestLocations]::StateImage) | Should -Not -Be 0
            $null = $mouseClick.Invoke($list, @([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, $checkboxX, $rowY, 0)))
            $row.Checked | Should -BeTrue
            $disabledY = $list.Items[1].Bounds.Top + 2
            $null = $mouseClick.Invoke($list, @([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, 300, $disabledY, 0)))
            $list.Items[1].Checked | Should -BeFalse
            $null = $mouseClick.Invoke($list, @([Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Right, 1, 80, $rowY, 0)))
            $row.Checked | Should -BeTrue
        }
        finally { $dialog.Dispose() }
    }
    It 'grays out missing sections and blocks checking them individually or with Select all' {
        $testFile = Join-Path $TestDrive 'Partial.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[{"Name":"Example"}],"Software":{"Install":[{"ExecutablePath":"example.exe"}]}}}' | Set-Content -LiteralPath $testFile
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Partial' -Entries @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        try {
            $dialog.Show()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
            $list.Items.Count | Should -Be (Get-SnapshotScriptsHC).Count
            @($list.CheckedItems | ForEach-Object Tag) | Should -Be @('UserAccounts', 'Software')
            $missing = @($list.Items | Where-Object { $_.Tag -notin @('UserAccounts', 'Software') })
            foreach ($item in $missing) {
                $item.ForeColor | Should -Be ([Drawing.SystemColors]::GrayText)
                $item.ToolTipText | Should -Be 'No settings to restore in this configuration.'
                $item.Checked = $true
                $item.Checked | Should -BeFalse
            }
            ($confirm.Parent.Controls | Where-Object Text -eq 'Clear all').PerformClick()
            $confirm.Enabled | Should -BeFalse
            $missing[0].Checked = $true
            $confirm.Enabled | Should -BeFalse
            ($confirm.Parent.Controls | Where-Object Text -eq 'Select all').PerformClick()
            @($list.CheckedItems | ForEach-Object Tag) | Should -Be @('UserAccounts', 'Software')
            $confirm.PerformClick()
            @($dialog.Tag) | Should -Be @('UserAccounts', 'Software')
        }
        finally { $dialog.Dispose() }
    }
    It 'enables only User accounts and Software for the bundled Example PC1 configuration' {
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile "$PSScriptRoot\..\Configurations\Example PC1.json")
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Example PC1' -Entries $entries
        try {
            $dialog.Show()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
            @($list.CheckedItems | ForEach-Object Tag) | Should -Be @('UserAccounts', 'Software')
            foreach ($item in $list.Items | Where-Object { $_.Tag -notin @('UserAccounts', 'Software') }) {
                $item.ForeColor | Should -Be ([Drawing.SystemColors]::GrayText)
                $item.Checked = $true
                $item.Checked | Should -BeFalse
            }
            ($confirm.Parent.Controls | Where-Object Text -eq 'Select all').PerformClick()
            @($list.CheckedItems | ForEach-Object Tag) | Should -Be @('UserAccounts', 'Software')
        }
        finally { $dialog.Dispose() }
    }
    It 'enables only Create folders and Registry keys for the bundled combined sections example' {
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile "$PSScriptRoot\..\Configurations\Example combined sections.json")
        @($entries | Where-Object Available | ForEach-Object Key) | Should -Be @('CreateFolders', 'RegistryKeys')
    }
    It 'shows checked names and descriptions and returns only checked keys' {
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Example' -Entries @(Get-SnapshotItemEntriesHC -Items UserAccounts, Software)
        try {
            $dialog.Show()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
            $list.Columns[1].Text | Should -Be 'Description'
            $list.CheckedItems.Count | Should -Be 2
            $list.Items[0].Text | Should -Be 'User accounts'
            $buttons = $confirm.Parent.Controls
            ($buttons | Where-Object Text -eq 'Clear all').PerformClick()
            $list.CheckedItems.Count | Should -Be 0
            $confirm.Enabled | Should -BeFalse
            ($buttons | Where-Object Text -eq 'Select all').PerformClick()
            $list.CheckedItems.Count | Should -Be 2
            $list.Items[0].Checked = $false
            $list.Items[1].Checked = $false
            $confirm.Enabled | Should -BeFalse
            $list.Items[1].Checked = $true
            $confirm.Enabled | Should -BeTrue
            $confirm.PerformClick()
            @($dialog.Tag) | Should -Be @('Software')
            $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::OK)
        }
        finally { $dialog.Dispose() }
    }
    It 'cancels without returning a restore selection' {
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Example' -Entries @(Get-SnapshotItemEntriesHC)
        try {
            $dialog.Show()
            $dialog.CancelButton.PerformClick()
            $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::Cancel)
            $dialog.Tag | Should -BeNullOrEmpty
        }
        finally { $dialog.Dispose() }
    }
    It 'keeps the checklist and restore controls inside the minimum window size' {
        $dialog = New-RestoreSelectionFormHC -ConfigurationName 'Example' -Entries @(Get-SnapshotItemEntriesHC)
        try {
            $dialog.Size = $dialog.MinimumSize
            $dialog.Show()
            [Windows.Forms.Application]::DoEvents()
            $dialog.Size = $dialog.MinimumSize
            $dialog.PerformLayout()
            $list = $dialog.Controls.Find('SnapshotItems', $true)[0]
            $confirm = $dialog.Controls.Find('RestoreSelected', $true)[0]
            $list.Right | Should -BeLessOrEqual $list.Parent.ClientSize.Width
            $confirm.Parent.Right | Should -BeLessOrEqual $confirm.Parent.Parent.ClientSize.Width
            foreach ($button in $confirm.Parent.Controls) {
                $button.Left | Should -BeGreaterOrEqual 0
                $button.Right | Should -BeLessOrEqual $button.Parent.ClientSize.Width
                $button.Bottom | Should -BeLessOrEqual $button.Parent.ClientSize.Height
            }
            foreach ($name in @('RebootComputer', 'RestartDelaySeconds', 'OpenReportInBrowser', 'AnswerFile', 'BrowseAnswerFile', 'CreateAnswerTemplate', 'Unattended', 'AnswerFileGuidance')) {
                $option = $dialog.Controls.Find($name, $true)[0]
                $option.Visible | Should -BeTrue
                $option.Right | Should -BeLessOrEqual $option.Parent.ClientSize.Width
                $option.Bottom | Should -BeLessOrEqual $option.Parent.ClientSize.Height
            }
        }
        finally { $dialog.Dispose() }
    }
}