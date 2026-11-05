#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    . "$PSScriptRoot\..\Scripts\Invoke GUI.ps1" -NoShow
    . "$PSScriptRoot\..\Scripts\Common\RestoreInput.ps1"
}

Describe 'Restore input form' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    BeforeEach {
        $items = [ordered]@{
            Software     = [ordered]@{
                Install = @(
                    [ordered]@{
                        ExecutablePath = 'Setup.exe'
                        TimeoutMinutes = '{{number:Minutes}}'
                    }
                )
            }
            RegistryKeys = [ordered]@{
                RunAsCurrentUser = [ordered]@{
                    RegistryKeys = @(
                        [ordered]@{
                            Path  = 'HKCU:\Software\Example'
                            Name  = '{{input:Account}}'
                            Type  = '{{input:Value type}}'
                            Value = '1'
                        }
                    )
                }
            }
            UserAccounts = @(
                [ordered]@{
                    Name     = '{{input:Account}}'
                    Password = '{{password:Password}}'
                }
            )
        }
        $fields = @(Get-RestoreInputFieldsHC -Data $items)
        $questions = @(Get-RestoreInputQuestionHC -Fields $fields)
        $dialog = New-RestoreInputFormHC -Questions $questions
        $dialog.Show()
        $answer = @{}
        foreach ($control in $dialog.Tag.Inputs) {
            $answer[$control.Tag.Question.Placeholder] = $control
        }
    }
    AfterEach {
        $dialog.Dispose()
    }
    It ('shows every question once, under the header of the section that ' +
        'runs first') {
        @($dialog.Controls.Find('SectionHeader', $true).Text) |
            Should -Be @('User accounts', 'Registry keys', 'Software')
        @($dialog.Tag.Inputs.Count) | Should -Be 4
        @($dialog.Controls.Find('QuestionDescription', $true).Text) |
            Should -Be @('Account', 'Password', 'Value type', 'Minutes')
        $dialog.Controls.Find('QuestionLocation', $true)[0].Text |
            Should -BeLike (
                "Items.UserAccounts[[]0].Name*Also used by: Registry keys"
            )
    }
    It 'masks a password and offers the fixed values of a setting as a list' {
        $answer['{{password:Password}}'].UseSystemPasswordChar |
            Should -BeTrue
        $answer['{{input:Account}}'].UseSystemPasswordChar | Should -BeFalse

        $list = $answer['{{input:Value type}}']
        $list | Should -BeOfType [Windows.Forms.ComboBox]
        $list.DropDownStyle | Should -Be 'DropDownList'
        @($list.Items) -ccontains 'DWord' | Should -BeTrue
        @($list.Items) -ccontains 'REG_DWORD' | Should -BeTrue
        @($list.Items) -ccontains 'DWORD' | Should -BeFalse
        @($list.Items).Count | Should -Be 12
    }
    It ('shows what an answer must look like, and why it is wrong once ' +
        'the field was left') {
        $minutes = $answer['{{number:Minutes}}']
        $message = $minutes.Tag.Message

        $message.Text | Should -Be 'Enter a whole number from 1 to 1440.'
        $message.ForeColor | Should -Be ([Drawing.Color]::DimGray)

        $minutes.Text = '0'
        $minutes.Tag.Touched = $true
        Update-RestoreInputPanelHC -Panel $dialog.Tag.Panel

        $message.Text | Should -Be 'Enter a whole number from 1 to 1440.'
        $message.ForeColor | Should -Be ([Drawing.Color]::Firebrick)

        $minutes.Text = '30'

        $message.Text | Should -Be ''
    }
    It ('enables Continue only when every answer is valid and returns the ' +
        'answers by placeholder') {
        $confirm = $dialog.Controls.Find('ConfirmInput', $true)[0]
        $summary = $dialog.Controls.Find('InputSummary', $true)[0]

        $confirm.Enabled | Should -BeFalse
        $summary.Text | Should -Be '4 of 4 answer(s) still needed'

        $answer['{{input:Account}}'].Text = 'kiosk'
        $answer['{{password:Password}}'].Text = 'Test-only password!"\$'
        $answer['{{input:Value type}}'].SelectedItem = 'DWord'
        $answer['{{number:Minutes}}'].Text = '1441'

        $confirm.Enabled | Should -BeFalse
        $summary.Text | Should -Be '1 of 4 answer(s) still needed'

        $answer['{{number:Minutes}}'].Text = '1440'

        $confirm.Enabled | Should -BeTrue
        $summary.Text | Should -Be 'All answers are valid'

        $confirm.PerformClick()

        $dialog.DialogResult | Should -Be ([Windows.Forms.DialogResult]::OK)
        $dialog.Tag.Values.Count | Should -Be 4
        $dialog.Tag.Values['{{input:Account}}'] | Should -BeExactly 'kiosk'
        $dialog.Tag.Values['{{password:Password}}'] |
            Should -BeExactly 'Test-only password!"\$'
        $dialog.Tag.Values['{{input:Value type}}'] | Should -BeExactly 'DWord'
        $dialog.Tag.Values['{{number:Minutes}}'] | Should -BeExactly '1440'
    }
    It 'returns no answers when the form is cancelled' {
        $answer['{{input:Account}}'].Text = 'kiosk'

        $dialog.CancelButton.PerformClick()

        $dialog.DialogResult |
            Should -Be ([Windows.Forms.DialogResult]::Cancel)
        $dialog.Tag.Values | Should -BeNullOrEmpty
    }
}

Describe 'Wizard console welcome' {
    BeforeEach {
        Mock Clear-Host
        Mock Write-Host
        Mock Test-ElevatedHC { $false }
        $console = [pscustomobject]@{
            BackgroundColor = [ConsoleColor]::DarkBlue
            ForegroundColor = [ConsoleColor]::Yellow
            WindowTitle     = 'PowerShell'
        }
    }
    It 'sets a black console and shows ASCII art with launch details' {
        $params = @{
            ConsoleUI    = $console
            ComputerName = 'TEST-PC'
            UserName     = 'DOMAIN\Example'
            StartedAt    = [datetime]'2026-10-22T08:42:04'
        }
        Show-WizardConsoleHC @params

        $console.BackgroundColor | Should -Be ([ConsoleColor]::Black)
        $console.ForegroundColor | Should -Be ([ConsoleColor]::Gray)
        $console.WindowTitle | Should -Be 'Computer Snapshot | TEST-PC'
        Should -Invoke Clear-Host -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*COMPUTER SNAPSHOT*' -and
            $Object -like '*[[] SNAPSHOT ]*' -and
            $Object -notmatch '[^\x00-\x7F]' -and $BackgroundColor -eq 'Black'
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Hostname   : TEST-PC*' -and
            $Object -like '*2026-10-22 08:42:04*' -and
            $Object -like '*User       : DOMAIN\Example*' -and
            $Object -like '*PowerShell :*' -and
            $Object -like '*Standard (not elevated)*' -and
            $BackgroundColor -eq 'Black'
        }
    }
    It 'identifies an elevated session' {
        Mock Test-ElevatedHC { $true }
        Show-WizardConsoleHC -ConsoleUI $console
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Access     : Administrator*'
        }
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
    It ('launches an export without creating a configuration or temporary ' +
        'files') {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count
        $params = @{
            Action              = 'CreateSnapshot'
            RootFolder          = $TestDrive
            Name                = 'Kiosk example'
            Items               = 'UserAccounts', 'Software'
            OpenReportInBrowser = $false
        }
        Start-ConfigurationJobHC @params

        @(Get-ChildItem -LiteralPath $TestDrive -Recurse).Count |
            Should -Be $before
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command -like '*-Action CreateSnapshot*' -and
            $command -like '*Configurations\Kiosk example.json*' -and
            $command -like '*-Items*UserAccounts*Software*'
        }
    }
    It 'includes HHmmss in the suggested export filename' {
        Mock Get-Date { '2026-10-21 142536' } -ParameterFilter {
            $Format -eq 'yyyy-MM-dd HHmmss'
        }
        $name = Get-DefaultConfigurationNameHC
        $name | Should -BeExactly "$env:COMPUTERNAME 2026-10-21 142536"

        $params = @{
            Action     = 'CreateSnapshot'
            RootFolder = $TestDrive
            Name       = $name
            Items      = 'UserAccounts'
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command -like '* 2026-10-21 142536.json*'
        }
    }
    It 'rejects directory traversal in a configuration name' {
        $params = @{
            Action     = 'CreateSnapshot'
            RootFolder = $TestDrive
            Name       = '..\outside'
            Items      = 'UserAccounts'
        }
        { Start-ConfigurationJobHC @params } | Should -Throw '*file name*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'requires at least one selected export item' {
        $params = @{
            Action     = 'CreateSnapshot'
            RootFolder = $TestDrive
            Name       = 'Example'
            Items      = @()
        }
        { Start-ConfigurationJobHC @params } |
            Should -Throw '*Select at least one*'
    }
    It 'launches restore through the configuration launcher' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $testFile
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command -like
            '*Invoke configuration.ps1*-ConfigurationFile*Example.json*'
        }
    }
    It ('passes a quoted answer-file path and unattended mode without ' +
        'putting answers in the command') {
        $file = Join-Path $TestDrive 'answer-configuration.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[]}}' |
            Set-Content -LiteralPath $file
        $answerFile = Join-Path $TestDrive "kiosk's answers.json"
        '{"Answers":{"{{password:Password}}":"PRIVATE-ANSWER"}}' |
            Set-Content -LiteralPath $answerFile
        Mock Test-ElevatedHC { $true }
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $file
            AnswerFile        = $answerFile
            Unattended        = $true
        }
        Start-ConfigurationJobHC @params

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains("kiosk''s answers.json'") -and
            $command.Contains(' -AnswerFile ') -and
            $command.Contains(' -Unattended') -and
            $command -notmatch 'PRIVATE-ANSWER' -and
            $ArgumentList -contains '-NonInteractive' -and -not $Verb
        }
    }
    It ('refuses a missing answer file or an unattended UAC requirement ' +
        'before launching') {
        $file = Join-Path $TestDrive 'elevated-answer-configuration.json'
        ('{"SchemaVersion":3,"Settings":{"RunElevated":true},' +
            '"Items":{"UserAccounts":[]}}') | Set-Content -LiteralPath $file
        Mock Test-ElevatedHC { $false }
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $file
        }
        {
            Start-ConfigurationJobHC @params -AnswerFile 'missing.answers.json'
        } | Should -Throw '*not found*'
        { Start-ConfigurationJobHC @params -Unattended } |
            Should -Throw '*administrator rights*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It ('refuses unattended without administrator rights, RunElevated ' +
        '<RunElevated>') -ForEach @(
        @{ RunElevated = 'true' }
        @{ RunElevated = 'false' }
    ) {
        $file = Join-Path $TestDrive 'unattended-configuration.json'
        '{"SchemaVersion":3,"Settings":{"RunElevated":' + $RunElevated +
            '},"Items":{"UserAccounts":[]}}' |
            Set-Content -LiteralPath $file
        Mock Test-ElevatedHC { $false }

        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $file
            Unattended        = $true
        }
        { Start-ConfigurationJobHC @params } |
            Should -Throw 'Unattended restore requires administrator rights.*'

        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'passes checked restore keys to the configuration launcher' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $testFile
            Items             = 'UserAccounts', 'Software'
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains("-Items @('UserAccounts','Software')")
        }
    }
    It ('passes only the name of the answer pipe to the restore, and ' +
        'refuses it on export') {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $testFile
            AnswerPipe        = 'ComputerSnapshot-0123'
        }

        Start-ConfigurationJobHC @params

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains(" -AnswerPipe 'ComputerSnapshot-0123'")
        }

        $exportParams = @{
            Action     = 'CreateSnapshot'
            RootFolder = $TestDrive
            Name       = 'Example'
            Items      = 'UserAccounts'
            AnswerPipe = 'ComputerSnapshot-0123'
        }
        { Start-ConfigurationJobHC @exportParams } |
            Should -Throw '*restore-only*'
    }
    It 'rejects an empty restore selection before launching' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $testFile
            Items             = @()
        }
        { Start-ConfigurationJobHC @params } |
            Should -Throw '*Select at least one*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It ('passes explicit restore setting choices without adding defaults ' +
        'when omitted') {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{}' | Set-Content -LiteralPath $testFile
        $params = @{
            Action              = 'RestoreSnapshot'
            RootFolder          = $TestDrive
            ConfigurationFile   = $testFile
            Items               = 'UserAccounts'
            RebootComputer      = $true
            RestartDelaySeconds = 300
            OpenReportInBrowser = $false
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command.Contains('-RebootComputer $true') -and
            $command.Contains('-RestartDelaySeconds 300') -and
            $command.Contains('-OpenReportInBrowser $false')
        }

        $params = @{
            Action            = 'RestoreSnapshot'
            RootFolder        = $TestDrive
            ConfigurationFile = $testFile
            Items             = 'UserAccounts'
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command -notmatch
            'RebootComputer|RestartDelaySeconds|OpenReportInBrowser'
        }
    }
    It ('uses configuration defaults when restore settings are missing and ' +
        'rejects non-Boolean values') {
        $testFile = Join-Path $TestDrive 'Settings.json'
        '{"SchemaVersion":3,"Items":{"UserAccounts":[]}}' |
            Set-Content -LiteralPath $testFile
        $settings = Get-RestoreSettingsHC -ConfigurationFile $testFile
        $settings.RebootComputer | Should -BeFalse
        $settings.OpenReportInBrowser | Should -BeTrue
        $settings.RestartDelaySeconds | Should -Be 60

        '{"Settings":{"RebootComputer":"false"}}' |
            Set-Content -LiteralPath $testFile
        { Get-RestoreSettingsHC -ConfigurationFile $testFile } |
            Should -Throw '*must be a Boolean*'

        '{"Settings":{"RestartDelaySeconds":601}}' |
            Set-Content -LiteralPath $testFile
        { Get-RestoreSettingsHC -ConfigurationFile $testFile } |
            Should -Throw '*0 to 600*'
    }
    It 'provides readable labels and descriptions for every supported item' {
        $entries = @(Get-SnapshotItemEntriesHC)
        @($entries.Key) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        foreach ($entry in $entries) {
            $entry.Name | Should -Not -BeNullOrEmpty
            $entry.Description | Should -Not -BeNullOrEmpty
            $entry.Available | Should -BeTrue
        }
        ($entries | Where-Object Key -eq 'CopyFilesFolders').Name |
            Should -Be 'Copy files and folders'
    }
    It ('lists all sections but only marks configured sections available ' +
        'without resolving references') {
        $testFile = Join-Path $TestDrive 'Example.json'
        ('{"SchemaVersion":3,"Items":{"Software":{"Install":' +
            '[{"ExecutablePath":"example.exe"}]},' +
            '"UserAccounts":"missing.json","Comment":"Example"}}') |
            Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries.Key) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        @($entries | Where-Object Available | ForEach-Object Key) |
            Should -Be @('UserAccounts', 'Software')
        @($entries | Where-Object { -not $_.Available }).Count |
            Should -Be ($entries.Count - 2)
    }
    It ('disables empty arrays, objects, nulls, blank references and ' +
        'comment-only sections') {
        $testFile = Join-Path $TestDrive 'Empty sections.json'
        ('{"SchemaVersion":3,"Items":{"UserAccounts":[],"Software":{},' +
            '"RegionalSettings":null,"UserGroups":" ",' +
            '"CreateFolders":{"Comment":"No folders"}}}') |
            Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries | Where-Object Available).Count | Should -Be 0
    }
    It 'rejects legacy or empty configurations in the restore overview' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{"StartScript":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } |
            Should -Throw '*version-3*'
        '{"SchemaVersion":3,"Items":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } |
            Should -Throw '*no items*'
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
    It ('passes the folders as export options, quoted so a name cannot ' +
        'break the command') {
        $params = @{
            Action      = 'CreateSnapshot'
            RootFolder  = $TestDrive
            Name        = 'Tasks'
            Items       = 'ScheduledTasks'
            TaskFolders = '\HC\', "\It's\"
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput(
                $command, [ref]$null, [ref]$parseErrors
            )
            $command.Contains(
                "-ExportOptions @{ ScheduledTasks = @{ " +
                "TaskPath = @('\HC\','\It''s\') } }"
            ) -and $parseErrors.Count -eq 0
        }
    }
    It 'adds no export options when scheduled tasks are not exported' {
        $params = @{
            Action      = 'CreateSnapshot'
            RootFolder  = $TestDrive
            Name        = 'Users'
            Items       = 'UserAccounts'
            TaskFolders = '\HC\'
        }
        Start-ConfigurationJobHC @params
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $command -notmatch 'ExportOptions'
        }
    }
    It ('reads comma-separated folders, uses the export default when empty ' +
        'and rejects invalid names') {
        @(Get-WizardTaskFolderHC -Text '') | Should -Be @('\HC\')
        @(Get-WizardTaskFolderHC -Text ' HC, Vendor\Sub ,, \HC\ ') |
            Should -Be @('\HC\', '\Vendor\Sub\')
        @(Get-WizardTaskFolderHC -Text '\') | Should -Be @('\')
        { Get-WizardTaskFolderHC -Text '\HC\, Ven|dor' } |
            Should -Throw "*'\Ven|dor\'*not allowed*"
    }
    It 'asks for confirmation only for the root folder' {
        Mock Show-WizardQuestionHC { [Windows.Forms.DialogResult]::No }
        Confirm-WizardTaskFolderHC -Folders '\HC\', '\Vendor\' | Should -BeTrue
        Should -Invoke Show-WizardQuestionHC -Times 0 -Exactly
        Confirm-WizardTaskFolderHC -Folders '\HC\', '\' | Should -BeFalse

        Mock Show-WizardQuestionHC { [Windows.Forms.DialogResult]::Yes }
        Confirm-WizardTaskFolderHC -Folders '\' | Should -BeTrue
        $invokeParams = @{
            Times   = 2
            Exactly = $true
        }
        Should -Invoke Show-WizardQuestionHC @invokeParams -ParameterFilter {
            $Text -like '*every scheduled task*'
        }
    }
    It ('shows the export default and is enabled only while Scheduled ' +
        'tasks is checked') {
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
            foreach ($control in $panel.Controls) {
                $control.Enabled | Should -BeFalse
            }
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
        Mock Test-ElevatedHC { $false }
    }
    It ('requests native UAC elevation and preserves quoted script and ' +
        'root paths') {
        $root = "C:\Snapshot user's files"
        $scriptPath = "$root\Scripts\Invoke GUI.ps1"
        Restart-WizardElevatedHC -RootFolder $root -WizardScript $scriptPath |
            Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $command = [Text.Encoding]::Unicode.GetString(
                [Convert]::FromBase64String($ArgumentList[-1])
            )
            $Verb -eq 'RunAs' -and $ArgumentList -contains '-STA' -and
            $ErrorAction -eq 'Stop' -and
            $command -eq (
                "& 'C:\Snapshot user''s files\Scripts\Invoke GUI.ps1' " +
                "-RootFolder 'C:\Snapshot user''s files'"
            )
        }
    }
    It 'returns without restarting when UAC is cancelled' {
        Mock Start-Process {
            throw (New-Object System.ComponentModel.Win32Exception 1223)
        }
        $params = @{ RootFolder = $TestDrive; WizardScript = 'C:\Wizard.ps1' }
        Restart-WizardElevatedHC @params | Should -BeFalse
    }
    It 'propagates launch errors other than cancellation' {
        Mock Start-Process {
            throw (New-Object System.ComponentModel.Win32Exception 2)
        }
        $params = @{ RootFolder = $TestDrive; WizardScript = 'C:\Wizard.ps1' }
        { Restart-WizardElevatedHC @params } | Should -Throw
    }
    It ('distinguishes administrator restart with a shield and accessible ' +
        'accent color') {
        $params = @{ RootFolder = $TestDrive; WizardScript = 'C:\Wizard.ps1' }
        $panel = New-WizardElevationPanelHC @params
        try {
            $button = $panel.Controls.Find('RestartAsAdministrator', $true)[0]
            $button.Image | Should -Not -BeNullOrEmpty
            $button.Image.Width | Should -Be 16
            $button.TextImageRelation |
                Should -Be ([Windows.Forms.TextImageRelation]::ImageBeforeText)
            if (-not [Windows.Forms.SystemInformation]::HighContrast) {
                $button.BackColor |
                    Should -Be ([Drawing.Color]::FromArgb(245, 199, 92))
                $button.ForeColor |
                    Should -Be ([Drawing.Color]::FromArgb(40, 35, 20))
            }
        }
        finally { $panel.Dispose() }
    }
    It 'omits the button when already elevated' {
        Mock Test-ElevatedHC { $true }
        $params = @{ RootFolder = $TestDrive; WizardScript = 'C:\Wizard.ps1' }
        New-WizardElevationPanelHC @params | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It ('keeps the original wizard open after cancellation and closes it ' +
        'after a successful launch') {
        $window = New-Object Windows.Forms.Form
        try {
            $params = @{
                RootFolder   = $TestDrive
                WizardScript = 'C:\Wizard.ps1'
            }
            $panel = New-WizardElevationPanelHC @params
            $window.Controls.Add($panel)
            $window.Show()
            $button = $window.Controls.Find('RestartAsAdministrator', $true)[0]
            $button.Visible | Should -BeTrue
            Should -Invoke Start-Process -Times 0 -Exactly

            Mock Start-Process {
                throw (New-Object System.ComponentModel.Win32Exception 1223)
            }
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

Describe 'Restore wizard' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        function New-TestWizardHC {
            param([string]$RootFolder)

            $form = New-Object Windows.Forms.Form
            $form.ClientSize = New-Object Drawing.Size 820, 580
            $form.Font = New-Object Drawing.Font 'Segoe UI', 10
            $wizard = New-RestoreWizardHC -RootFolder $RootFolder -Font (
                $form.Font
            )
            $form.Controls.Add($wizard)
            $form.Show()
            Update-RestoreConfigurationListHC -Wizard $wizard

            return , $wizard
        }

        function Write-TestJsonHC {
            param([string]$Path, $Data)

            $null = New-Item -Path (Split-Path $Path -Parent) -ItemType (
                'Directory'
            ) -Force
            $Data | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }
    BeforeEach {
        Mock Show-WizardErrorHC
        Mock Start-ConfigurationJobHC
        $once = @{ Times = 1; Exactly = $true }
        Mock Start-RestoreAnswerServerHC {
            [pscustomobject]@{
                PipeName   = 'ComputerSnapshot-test'
                PowerShell = $null
            }
        }

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-TestJsonHC "$root\Configurations\Prompted.json" ([ordered]@{
                SchemaVersion = 3
                Description   = 'Prompted kiosk'
                Settings      = [ordered]@{
                    RebootComputer      = $true
                    RestartDelaySeconds = 30
                    OpenReportInBrowser = $false
                }
                Items         = [ordered]@{
                    UserAccounts   = @(
                        [ordered]@{
                            Name     = '{{input:Account}}'
                            Password = '{{password:Password}}'
                        }
                    )
                    NtpTimeServers = [ordered]@{
                        SyncTimeWithDomain = $false
                        TimeServerNames    = @('{{ipv4:Server}}')
                    }
                }
            })
        Write-TestJsonHC "$root\Configurations\Plain.json" ([ordered]@{
                SchemaVersion = 3
                Items         = [ordered]@{
                    UserAccounts = @([ordered]@{ Name = 'Example' })
                }
            })
        Write-TestJsonHC "$root\Answers\Kiosk\Brussels\Kiosk.json" @{
            Answers = [ordered]@{
                '{{input:Account}}' = 'kiosk-brussels'
                '{{ipv4:Server}}'   = '192.0.2.10'
            }
        }
        Write-TestJsonHC "$root\Answers\Kiosk\Gent\Kiosk.json" @{
            Answers = [ordered]@{
                '{{input:Account}}'     = 'kiosk-gent'
                '{{password:Password}}' = 'File-secret!42'
                '{{ipv4:Server}}'       = '192.0.2.20'
            }
        }
        Write-TestJsonHC "$root\Answers\Other.json" @{
            Answers = @{ '{{input:Something else}}' = 'x' }
        }
        '{"Answers":' | Set-Content -LiteralPath "$root\Answers\Broken.json"
        (Get-Item "$root\Answers\Other.json").LastWriteTime = (
            Get-Date '2026-01-01'
        )

        $wizard = New-TestWizardHC -RootFolder $root
        $find = { param($name) Find-RestoreWizardControlHC $wizard $name }
        $next = & $find 'WizardNext'
        $chooseConfiguration = {
            param($name)
            $item = (& $find 'Configurations').Items |
                Where-Object Text -eq $name
            $item.Selected = $true
            $next.PerformClick()
        }
        $chooseAnswerFile = {
            param($path)
            $item = (& $find 'AnswerFiles').Items | Where-Object Text -eq $path
            $item.Selected = $true
            $next.PerformClick()
        }
    }
    AfterEach {
        $wizard.FindForm().Dispose()
    }
    It ('shows one step at a time in the same window, from the ' +
        'configuration to the sections and back') {
        $openForms = [Windows.Forms.Application]::OpenForms.Count

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 1: Choose a configuration'
        (& $find 'ConfigurationStep').Visible | Should -BeTrue
        (& $find 'SectionsStep').Visible | Should -BeFalse
        (& $find 'WizardBack').Enabled | Should -BeFalse
        (& $find 'RefreshConfigurations').Visible | Should -BeTrue
        @((& $find 'Configurations').Items.Text) |
            Should -Be @('Plain', 'Prompted')
        $next.Enabled | Should -BeFalse

        & $chooseConfiguration 'Prompted'

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 2: Choose the sections to restore'
        (& $find 'ConfigurationStep').Visible | Should -BeFalse
        (& $find 'SectionsStep').Visible | Should -BeTrue
        (& $find 'ConfigurationDescription').Text | Should -Be 'Prompted kiosk'
        (& $find 'RefreshConfigurations').Visible | Should -BeFalse
        (& $find 'SelectAll').Visible | Should -BeTrue
        (& $find 'WizardBack').Enabled | Should -BeTrue

        (& $find 'WizardBack').PerformClick()

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 1: Choose a configuration'
        (& $find 'ConfigurationStep').Visible | Should -BeTrue
        [Windows.Forms.Application]::OpenForms.Count | Should -Be $openForms
    }
    It ('grays out sections without data and needs at least one checked ' +
        'section') {
        & $chooseConfiguration 'Prompted'
        $list = & $find 'SnapshotItems'

        @($list.CheckedItems | ForEach-Object Tag) |
            Should -Be @('UserAccounts', 'NtpTimeServers')
        $software = $list.Items | Where-Object Tag -eq 'Software'
        $software.ForeColor | Should -Be ([Drawing.SystemColors]::GrayText)
        $software.Checked = $true
        $software.Checked | Should -BeFalse

        (& $find 'ClearAll').PerformClick()
        $next.Enabled | Should -BeFalse
        if (-not [Windows.Forms.SystemInformation]::HighContrast) {
            $next.BackColor | Should -Be ([Drawing.SystemColors]::Control)
        }

        (& $find 'SelectAll').PerformClick()
        @($list.CheckedItems | ForEach-Object Tag) |
            Should -Be @('UserAccounts', 'NtpTimeServers')
        $next.Enabled | Should -BeTrue
        if (-not [Windows.Forms.SystemInformation]::HighContrast) {
            $next.BackColor |
                Should -Be ([Drawing.Color]::FromArgb(0, 103, 184))
        }
    }
    It ('takes the restart and report options from the configuration and ' +
        'lets unattended turn off the report') {
        & $chooseConfiguration 'Prompted'
        $reboot = & $find 'RebootComputer'
        $delay = & $find 'RestartDelaySeconds'
        $report = & $find 'OpenReportInBrowser'
        $unattended = & $find 'Unattended'

        $reboot.Checked | Should -BeTrue
        $delay.Value | Should -Be 30
        $delay.Enabled | Should -BeTrue
        $report.Checked | Should -BeFalse

        $reboot.Checked = $false
        $delay.Enabled | Should -BeFalse

        $report.Checked = $true
        $unattended.Checked = $true
        $report.Checked | Should -BeFalse
        $report.Enabled | Should -BeFalse
        $unattended.Checked = $false
        $report.Checked | Should -BeTrue
    }
    It ('lists every answer file under Answers with its path and the ' +
        'questions it answers, and grays out the unusable ones') {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        $list = & $find 'AnswerFiles'

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 3: Choose an answer file'
        @($list.Items.Text) | Should -Be @(
            '(None) - answer the questions in the next step'
            'Broken.json'
            'Kiosk\Brussels\Kiosk.json'
            'Kiosk\Gent\Kiosk.json'
            'Other.json'
        )
        @($list.Items | ForEach-Object { $_.SubItems[1].Text }) |
            Should -Be @('0 of 3', 'Invalid', '2 of 3', '3 of 3', '0 of 3')
        $list.SelectedItems[0].Index | Should -Be 0
        $next.Enabled | Should -BeTrue

        foreach ($index in 1, 4) {
            $list.Items[$index].ForeColor |
                Should -Be ([Drawing.SystemColors]::GrayText)
            $list.Items[$index].Selected = $true
            $list.Items[$index].Selected | Should -BeFalse
            $list.SelectedItems[0].Index | Should -Be 0
        }
        $list.Items[1].ToolTipText | Should -BeLike '*not valid JSON*'
        $list.Items[4].ToolTipText | Should -BeLike '*answers none*'
    }
    It 'sorts the answer files by path or date modified, both ways' {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        $list = & $find 'AnswerFiles'
        $click = {
            param($column)
            $method = $list.GetType().GetMethod(
                'OnColumnClick',
                [Reflection.BindingFlags]'NonPublic, Instance'
            )
            $null = $method.Invoke(
                $list, @([Windows.Forms.ColumnClickEventArgs]::new($column))
            )
        }

        & $click 0

        $list.Columns[0].Text | Should -BeLike "Answer file *$([char]0x25BC)"
        @($list.Items.Text)[1..4] | Should -Be @(
            'Other.json'
            'Kiosk\Gent\Kiosk.json'
            'Kiosk\Brussels\Kiosk.json'
            'Broken.json'
        )

        & $click 2

        $list.Columns[2].Text | Should -BeLike "Date modified *$([char]0x25B2)"
        @($list.Items.Text)[1] | Should -Be 'Other.json'
        $list.Items[0].Text | Should -BeLike '(None)*'
    }
    It ('skips the questions that a complete answer file answers and ' +
        'reviews every answer with its source') {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        & $chooseAnswerFile 'Kiosk\Gent\Kiosk.json'

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 4: Review and restore'
        $next.Text | Should -Be 'Restore'
        (& $find 'ReviewSummary').Text | Should -BeLike (
            '*Answer file: Answers\Kiosk\Gent\Kiosk.json*'
        )
        $review = & $find 'ReviewAnswers'
        @($review.Items | ForEach-Object { $_.SubItems[1].Text }) |
            Should -Be @(
            'kiosk-gent', ([string]([char]0x25CF) * 8), '192.0.2.20'
        )
        @($review.Items | ForEach-Object { $_.SubItems[2].Text } |
            Select-Object -Unique) | Should -Be @('Answer file')
        @($review.Items | ForEach-Object { $_.Group.Header } |
            Select-Object -Unique) |
            Should -Be @('User accounts', 'Time synchronization')

        $next.PerformClick()

        Should -Invoke Start-ConfigurationJobHC @once -ParameterFilter {
            $AnswerFile -like '*\Answers\Kiosk\Gent\Kiosk.json' -and
            -not $AnswerPipe -and
            @($Items) -join ',' -eq 'UserAccounts,NtpTimeServers' -and
            $RebootComputer -and $RestartDelaySeconds -eq 30 -and
            -not $OpenReportInBrowser
        }
        Should -Invoke Start-RestoreAnswerServerHC -Times 0 -Exactly
        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 1: Choose a configuration'
    }
    It ('asks only what the answer file leaves open, keeps typed answers ' +
        'on Back and hands them over by pipe') {
        # The wizard forgets the answers once they are handed over
        Mock Start-RestoreAnswerServerHC {
            $script:handedOver = @(
                $Answers.Keys | ForEach-Object { "$_=$($Answers[$_])" }
            )
            [pscustomobject]@{
                PipeName   = 'ComputerSnapshot-test'
                PowerShell = $null
            }
        }
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        & $chooseAnswerFile 'Kiosk\Brussels\Kiosk.json'

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 4: Answer the questions'
        $inputs = $wizard.Tag.InputPanel.Tag.Inputs
        @($inputs | ForEach-Object { $_.Tag.Question.Placeholder }) |
            Should -Be @('{{password:Password}}')
        $next.Enabled | Should -BeFalse
        $inputs[0].Text = 'Typed-secret!42'

        (& $find 'WizardBack').PerformClick()
        $next.PerformClick()

        $wizard.Tag.InputPanel.Tag.Inputs[0].Text |
            Should -BeExactly 'Typed-secret!42'

        $next.PerformClick()

        $review = & $find 'ReviewAnswers'
        $password = $review.Items[1]
        $password.SubItems[1].Text | Should -Not -Match 'Typed-secret'
        $password.SubItems[2].Text | Should -Be 'Typed'

        $next.PerformClick()

        Should -Invoke Start-RestoreAnswerServerHC @once
        $handedOver | Should -Be @('{{password:Password}}=Typed-secret!42')
        Should -Invoke Start-ConfigurationJobHC @once -ParameterFilter {
            $AnswerPipe -eq 'ComputerSnapshot-test' -and
            $AnswerFile -like '*\Answers\Kiosk\Brussels\Kiosk.json'
        }
        $wizard.Tag.Answers | Should -BeNullOrEmpty
    }
    It ('asks every question without an answer file, and goes straight to ' +
        'the review when the checked sections ask nothing') {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        $next.PerformClick()

        $inputs = $wizard.Tag.InputPanel.Tag.Inputs
        $inputs.Count | Should -Be 3
        $inputs[0].Text = 'kiosk'
        $inputs[1].Text = 'Typed-secret!42'
        $inputs[2].Text = '192.0.2.30'
        $next.PerformClick()

        @((& $find 'ReviewAnswers').Items |
            ForEach-Object { $_.SubItems[2].Text } | Select-Object -Unique) |
            Should -Be @('Typed')
        (& $find 'ReviewSummary').Text | Should -BeLike '*Answer file: None*'

        foreach ($step in 1..4) {
            (& $find 'WizardBack').PerformClick()
        }
        & $chooseConfiguration 'Plain'
        $next.PerformClick()

        (& $find 'WizardStepTitle').Text |
            Should -Be 'Step 3: Review and restore'
        (& $find 'ReviewNoAnswers').Visible | Should -BeTrue
        (& $find 'ReviewAnswers').Visible | Should -BeFalse

        $next.PerformClick()

        Should -Invoke Start-ConfigurationJobHC @once -ParameterFilter {
            $ConfigurationFile -like '*\Plain.json' -and -not $AnswerFile
        }
    }
    It 'accepts only an answer file that answers everything when unattended' {
        & $chooseConfiguration 'Prompted'
        (& $find 'Unattended').Checked = $true
        $next.PerformClick()
        $list = & $find 'AnswerFiles'

        $list.SelectedItems.Count | Should -Be 0
        $next.Enabled | Should -BeFalse
        foreach ($item in @($list.Items)) {
            $usable = $item.Text -eq 'Kiosk\Gent\Kiosk.json'
            $item.Tag.Usable | Should -Be $usable -Because $item.Text
        }

        & $chooseAnswerFile 'Kiosk\Gent\Kiosk.json'
        (& $find 'ReviewSummary').Text | Should -BeLike '*Unattended*'
        $next.PerformClick()

        Should -Invoke Start-ConfigurationJobHC @once -ParameterFilter {
            $Unattended -and -not $OpenReportInBrowser
        }
    }
    It 'creates a new answer file in a subfolder of Answers' {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()

        (& $find 'NewAnswerFile').Text = 'Kiosk\Antwerp\Kiosk'
        (& $find 'CreateAnswerFile').PerformClick()

        $path = "$root\Answers\Kiosk\Antwerp\Kiosk.json"
        $path | Should -Exist
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $answers = $document.Answers
        @($answers.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            '{{input:Account}}', '{{ipv4:Server}}', '{{password:Password}}'
        )
        @($answers.PSObject.Properties.Value | Where-Object { $_ }).Count |
            Should -Be 0
        $item = (& $find 'AnswerFiles').Items |
            Where-Object Text -eq 'Kiosk\Antwerp\Kiosk.json'
        $item.SubItems[1].Text | Should -Be '0 of 3'
        (& $find 'AnswerFileStatus').Text |
            Should -BeLike 'Created Answers\Kiosk\Antwerp\Kiosk.json*'

        foreach ($name in @('..\Escape', 'C:\Escape.json', '')) {
            (& $find 'NewAnswerFile').Text = $name
            (& $find 'CreateAnswerFile').PerformClick()
        }
        Should -Invoke Show-WizardErrorHC -Times 3 -Exactly -ParameterFilter {
            $Caption -eq 'Answer file error'
        }
        "$root\Escape.json" | Should -Not -Exist
    }
    It 'reports configuration problems on Next and stays on the sections' {
        Write-TestJsonHC "$root\Configurations\Broken.json" @{
            SchemaVersion = 3
            Items         = @{
                Software = @{
                    Install = @(
                        @{
                            ExecutablePath = 'Missing\setup.exe'
                            Arguments      = '{{input:Arguments}}'
                        }
                    )
                }
            }
        }
        (& $find 'RefreshConfigurations').PerformClick()
        & $chooseConfiguration 'Broken'

        $next.PerformClick()

        $wizard.Tag.Step | Should -Be 'Sections'
        Should -Invoke Show-WizardErrorHC @once -ParameterFilter {
            $Caption -eq 'Restore error' -and
            $Text -like "*Install[[]0].ExecutablePath: file 'Missing*"
        }
    }
    It ('ignores the events of controls that are taken out of the wizard ' +
        'while it closes') {
        & $chooseConfiguration 'Prompted'
        $next.PerformClick()
        $list = & $find 'AnswerFiles'
        $detached = New-Object Windows.Forms.Label

        Get-RestoreWizardHC $detached | Should -BeNullOrEmpty
        { Update-RestoreWizardButtonsHC -Wizard $null } | Should -Not -Throw
        { Update-RestoreAnswerFileListHC -Wizard $null } | Should -Not -Throw
        { Show-RestoreWizardStepHC -Wizard $null -Step 'Sections' } |
            Should -Not -Throw
        Find-RestoreWizardControlHC $null 'WizardNext' | Should -BeNullOrEmpty

        $list.Parent.Controls.Remove($list)
        { $list.Items[2].Selected = $true } | Should -Not -Throw
        $list.Dispose()
        $detached.Dispose()
    }
    It 'keeps the steps and buttons inside the minimum window size' {
        $form = $wizard.FindForm()
        $form.ClientSize = New-Object Drawing.Size 640, 440
        & $chooseConfiguration 'Prompted'
        [Windows.Forms.Application]::DoEvents()

        foreach ($name in @(
                'SnapshotItems', 'RebootComputer', 'Unattended', 'WizardNext',
                'WizardBack'
            )) {
            $control = & $find $name
            $control.Right |
                Should -BeLessOrEqual $control.Parent.ClientSize.Width
            $control.Bottom |
                Should -BeLessOrEqual $control.Parent.ClientSize.Height
        }
    }
}
