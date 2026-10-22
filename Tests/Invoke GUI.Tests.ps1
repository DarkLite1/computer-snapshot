#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    . "$PSScriptRoot\..\Scripts\Invoke GUI.ps1" -NoShow
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
        '{"SchemaVersion":2,"Items":{"Software":{"Install":[{"ExecutablePath":"example.exe"}]},"UserAccounts":"missing.json","Comment":"Example"}}' | Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries.Key) | Should -Be @((Get-SnapshotScriptsHC).Keys)
        @($entries | Where-Object Available | ForEach-Object Key) | Should -Be @('UserAccounts', 'Software')
        @($entries | Where-Object { -not $_.Available }).Count | Should -Be ($entries.Count - 2)
    }
    It 'disables empty arrays, objects, nulls, blank references and comment-only sections' {
        $testFile = Join-Path $TestDrive 'Empty sections.json'
        '{"SchemaVersion":2,"Items":{"UserAccounts":[],"Software":{},"RegionalSettings":null,"UserGroups":" ","CreateFolders":{"Comment":"No folders"}}}' | Set-Content -LiteralPath $testFile
        $entries = @(Get-RestoreItemEntriesHC -ConfigurationFile $testFile)
        @($entries | Where-Object Available).Count | Should -Be 0
    }
    It 'rejects legacy or empty configurations in the restore overview' {
        $testFile = Join-Path $TestDrive 'Example.json'
        '{"StartScript":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } | Should -Throw '*version-2*'
        '{"SchemaVersion":2,"Items":{}}' | Set-Content -LiteralPath $testFile
        { Get-RestoreItemEntriesHC -ConfigurationFile $testFile } | Should -Throw '*no items*'
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
        '{"SchemaVersion":2,"Items":{"UserAccounts":[{"Name":"Example"}],"Software":{"Install":[{"ExecutablePath":"example.exe"}]}}}' | Set-Content -LiteralPath $testFile
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
        }
        finally { $dialog.Dispose() }
    }
}