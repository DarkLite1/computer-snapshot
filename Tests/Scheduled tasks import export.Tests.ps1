#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Scheduled tasks import export.ps1" -Name 'Scheduled tasks'
Describe 'Scheduled tasks import and export' {
    BeforeAll { $scriptPath = "$PSScriptRoot\..\Scripts\Scheduled tasks import export.ps1" }
    BeforeEach {
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Existing'; TaskPath = '\HC\' } } -ParameterFilter { $TaskName -eq 'Existing' }
        Mock Register-ScheduledTask { 'command output' }
        Mock Register-ScheduledTask { throw '(1,2)::ERROR: incorrect document syntax' } -ParameterFilter { $Xml -eq 'bad' }
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
    }
    It 'reports a task that cannot be registered and still registers the others' {
        $data = @(
            [pscustomobject]@{ TaskName = 'Existing'; TaskPath = '\HC\'; Enabled = $true; Xml = '<Task/>' }
            [pscustomobject]@{ TaskName = 'Bad'; TaskPath = '\HC\'; Enabled = $true; Xml = 'bad' }
            [pscustomobject]@{ TaskName = 'New'; TaskPath = '\HC\'; Enabled = $false; Xml = '<Task/>' }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Replaced scheduled task '\HC\Existing' (enabled)", "Created scheduled task '\HC\New' (disabled)")
        $result[0].Errors | Should -Be @("Failed to register scheduled task '\HC\Bad': (1,2)::ERROR: incorrect document syntax")
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskName -eq 'Bad' }
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'New' }
    }
    It 'reports a task that cannot be exported and still exports the others' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'Good'; TaskPath = '\HC\'; Settings = @{ Enabled = $true } }
            [pscustomobject]@{ TaskName = 'Broken'; TaskPath = '\HC\'; Settings = @{ Enabled = $false } }
        } -ParameterFilter { $TaskPath -eq '\HC\*' }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Export-ScheduledTask { throw 'The task XML is malformed' } -ParameterFilter { $TaskName -eq 'Broken' }
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        @($result[0].Data.TaskName) | Should -Be @('Good')
        $result[0].Errors | Should -Be @("Failed to export scheduled task '\HC\Broken': The task XML is malformed")
    }
    It 'exports nothing without an error when the \HC\ task folder does not exist' {
        Mock Get-ScheduledTask { Write-Error 'No MSFT_ScheduledTask objects found' } -ParameterFilter { $TaskPath -eq '\HC\*' }
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0
        $result[0].Messages | Should -Be @("Exported 0 scheduled task(s) from the task folder(s) '\HC\'")
    }
}

Describe 'Scheduled task folders and XML files' {
    BeforeAll { $scriptPath = "$PSScriptRoot\..\Scripts\Scheduled tasks import export.ps1" }
    BeforeEach {
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'A'; TaskPath = '\HC\'; Settings = @{ Enabled = $true } }
            [pscustomobject]@{ TaskName = 'B'; TaskPath = '\HC\Sub\'; Settings = @{ Enabled = $true } }
        } -ParameterFilter { $TaskPath -eq '\HC\*' }
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'B'; TaskPath = '\HC\Sub\'; Settings = @{ Enabled = $true } }
        } -ParameterFilter { $TaskPath -eq '\HC\Sub\*' }
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'V'; TaskPath = '\Vendor\'; Settings = @{ Enabled = $false } }
        } -ParameterFilter { $TaskPath -eq '\Vendor\*' }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Register-ScheduledTask
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
        $taskFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path $taskFolder 'Files') -ItemType Directory
        # Task Scheduler exports UTF-16 with a byte order mark
        $xmlText = '<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" />'
        [IO.File]::WriteAllText((Join-Path $taskFolder 'Files\Task.xml'), $xmlText, [Text.Encoding]::Unicode)
    }
    It 'exports the \HC\ folder by default' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)
        @($result[0].Data | ForEach-Object { $_.TaskPath + $_.TaskName }) | Should -Be @('\HC\A', '\HC\Sub\B')
    }
    It 'exports the task folders given in the export options, each task once' {
        $options = @{ TaskPath = @('HC', '\HC\Sub\', 'Vendor\', '\Missing') }
        $result = @(& $scriptPath -Action Export -Data $options -RootFolder $TestDrive)
        @($result[0].Data | ForEach-Object { $_.TaskPath + $_.TaskName }) | Should -Be @('\HC\A', '\HC\Sub\B', '\Vendor\V')
        $result[0].Messages | Should -Be @("Exported 3 scheduled task(s) from the task folder(s) '\HC\', '\HC\Sub\', '\Vendor\', '\Missing\'")
    }
    It 'registers a task from an exported Task Scheduler file' {
        $data = @([pscustomobject]@{ TaskName = 'FromFile'; TaskPath = '\HC\'; Enabled = $true; XmlFile = 'Files\Task.xml' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $taskFolder)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Created scheduled task '\HC\FromFile' from 'Files\Task.xml' (enabled)")
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Xml -eq '<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" />' }
    }
    It 'reports a missing XML file and a task with both Xml and XmlFile' {
        $data = @(
            [pscustomobject]@{ TaskName = 'Missing'; TaskPath = '\HC\'; Enabled = $true; XmlFile = 'Files\Nope.xml' }
            [pscustomobject]@{ TaskName = 'Both'; TaskPath = '\HC\'; Enabled = $true; Xml = '<Task/>'; XmlFile = 'Files\Task.xml' }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $taskFolder)
        $result[0].Errors[0] | Should -BeLike "Failed to register scheduled task '\HC\Missing': the file '*Nope.xml' does not exist"
        $result[0].Errors[1] | Should -Be "Failed to register scheduled task '\HC\Both': use either Xml or XmlFile, not both"
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
}