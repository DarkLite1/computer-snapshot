#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Engine\Scripts\Scheduled tasks import export.ps1"
    Name       = 'Scheduled tasks'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Scheduled tasks import and export' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Scheduled tasks import export.ps1'
    }
    BeforeEach {
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'Existing'; TaskPath = '\HC\' }
        } -ParameterFilter { $TaskName -eq 'Existing' }
        Mock Register-ScheduledTask { 'command output' }
        Mock Register-ScheduledTask {
            throw '(1,2)::ERROR: incorrect document syntax'
        } -ParameterFilter { $Xml -eq 'bad' }
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
    }
    It ('reports a task that cannot be registered and still registers ' +
        'the others') {
        $data = @(
            [pscustomobject]@{
                TaskName = 'Existing'
                TaskPath = '\HC\'
                Enabled  = $true
                Xml      = '<Task/>'
            }
            [pscustomobject]@{
                TaskName = 'Bad'
                TaskPath = '\HC\'
                Enabled  = $true
                Xml      = 'bad'
            }
            [pscustomobject]@{
                TaskName = 'New'
                TaskPath = '\HC\'
                Enabled  = $false
                Xml      = '<Task/>'
            }
        )
        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages | Should -Be @(
            "Replaced scheduled task '\HC\Existing' (enabled, runs as SYSTEM)"
            "Created scheduled task '\HC\New' (disabled, runs as SYSTEM)"
        )
        $result[0].Errors | Should -Be @(
            ("Failed to register scheduled task '\HC\Bad': " +
                '(1,2)::ERROR: incorrect document syntax')
        )
        Should -Invoke Enable-ScheduledTask -Times 0 -Exactly -ParameterFilter {
            $TaskName -eq 'Bad'
        }
        $invokeParams = @{
            CommandName = 'Disable-ScheduledTask'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $TaskName -eq 'New'
        }
    }
    It 'reports a task that cannot be exported and still exports the others' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'Good'
                TaskPath = '\HC\'
                Settings = @{ Enabled = $true }
            }
            [pscustomobject]@{
                TaskName = 'Broken'
                TaskPath = '\HC\'
                Settings = @{ Enabled = $false }
            }
        } -ParameterFilter { $TaskPath -eq '\HC\*' }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Export-ScheduledTask {
            throw 'The task XML is malformed'
        } -ParameterFilter { $TaskName -eq 'Broken' }

        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        @($result[0].Data.TaskName) | Should -Be @('Good')
        $result[0].Errors | Should -Be @(
            ("Failed to export scheduled task '\HC\Broken': " +
                'The task XML is malformed')
        )
    }
    It ('exports nothing without an error when the \HC\ task folder does ' +
        'not exist') {
        Mock Get-ScheduledTask {
            Write-Error 'No MSFT_ScheduledTask objects found'
        } -ParameterFilter { $TaskPath -eq '\HC\*' }

        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $result[0].Errors.Count | Should -Be 0
        $result[0].Messages | Should -Be @(
            "Exported 0 scheduled task(s) from the task folder(s) '\HC\'"
        )
    }
}

Describe 'Scheduled task folders and XML files' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Scheduled tasks import export.ps1'
    }
    BeforeEach {
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'A'
                TaskPath = '\HC\'
                Settings = @{ Enabled = $true }
            }
            [pscustomobject]@{
                TaskName = 'B'
                TaskPath = '\HC\Sub\'
                Settings = @{ Enabled = $true }
            }
        } -ParameterFilter { $TaskPath -eq '\HC\*' }
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'B'
                TaskPath = '\HC\Sub\'
                Settings = @{ Enabled = $true }
            }
        } -ParameterFilter { $TaskPath -eq '\HC\Sub\*' }
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'V'
                TaskPath = '\Vendor\'
                Settings = @{ Enabled = $false }
            }
        } -ParameterFilter { $TaskPath -eq '\Vendor\*' }
        Mock Export-ScheduledTask { '<Task/>' }
        Mock Register-ScheduledTask
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask

        $taskFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (
            Join-Path $taskFolder 'Files'
        )

        # Task Scheduler exports UTF-16 with a byte order mark
        $xmlText = ('<?xml version="1.0" encoding="UTF-16"?>' +
            '<Task version="1.2" />')
        [IO.File]::WriteAllText(
            (Join-Path $taskFolder 'Files\Task.xml'),
            $xmlText,
            [Text.Encoding]::Unicode
        )
    }
    It 'exports the \HC\ folder by default' {
        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        @($result[0].Data | ForEach-Object { $_.TaskPath + $_.TaskName }) |
            Should -Be @('\HC\A', '\HC\Sub\B')
    }
    It 'exports the task folders given in the export options, each task once' {
        $options = @{ TaskPath = @('HC', '\HC\Sub\', 'Vendor\', '\Missing') }

        $result = @(
            & $scriptPath -Action Export -Data $options -RootFolder $TestDrive
        )

        @($result[0].Data | ForEach-Object { $_.TaskPath + $_.TaskName }) |
            Should -Be @('\HC\A', '\HC\Sub\B', '\Vendor\V')
        $result[0].Messages | Should -Be @(
            ("Exported 3 scheduled task(s) from the task folder(s) '\HC\', " +
                "'\HC\Sub\', '\Vendor\', '\Missing\'")
        )
    }
    It 'registers a task from an exported Task Scheduler file' {
        $data = @(
            [pscustomobject]@{
                TaskName = 'FromFile'
                TaskPath = '\HC\'
                Enabled  = $true
                XmlFile  = 'Files\Task.xml'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $taskFolder
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @(
            ("Created scheduled task '\HC\FromFile' from 'Files\Task.xml' " +
                '(enabled, runs as SYSTEM)')
        )
        $invokeParams = @{
            CommandName = 'Register-ScheduledTask'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $Xml -eq ('<?xml version="1.0" encoding="UTF-16"?>' +
                '<Task version="1.2" />')
        }
    }
    It 'reports a missing XML file and a task with both Xml and XmlFile' {
        $data = @(
            [pscustomobject]@{
                TaskName = 'Missing'
                TaskPath = '\HC\'
                Enabled  = $true
                XmlFile  = 'Files\Nope.xml'
            }
            [pscustomobject]@{
                TaskName = 'Both'
                TaskPath = '\HC\'
                Enabled  = $true
                Xml      = '<Task/>'
                XmlFile  = 'Files\Task.xml'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $taskFolder
        )

        $result[0].Errors[0] | Should -BeLike (
            "Failed to register scheduled task '\HC\Missing': " +
            "the file '*Nope.xml' does not exist"
        )
        $result[0].Errors[1] | Should -Be (
            "Failed to register scheduled task '\HC\Both': " +
            'use either Xml or XmlFile, not both'
        )
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Scheduled task accounts' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Scheduled tasks import export.ps1'
        function Convert-AccountNameHC { param($Name) }
        function ConvertTo-PortableAccountNameHC { param($Name, $Sid) }
        function Get-AccountSidHC { param($Name) }
        function Get-AccountRightsHC { param($Sid) }
        function Add-AccountRightHC { param($Sid, $Right) }
    }
    BeforeEach {
        Mock Get-AccountSidHC { 'S-1-5-21-1-2-3-1001' }
        Mock Get-AccountRightsHC { 'SeBatchLogonRight' }
        Mock Add-AccountRightHC
        Mock Convert-AccountNameHC { $Name -replace '^PC1\\', 'PC2\' }
        Mock ConvertTo-PortableAccountNameHC {
            if ($Name -eq 'SYSTEM') { 'S-1-5-18' } else { $Name }
        }
        Mock Get-ScheduledTask { }
        Mock Register-ScheduledTask
        Mock Register-ScheduledTask {
            throw 'The user name or password is incorrect.'
        } -ParameterFilter { $Password -eq 'wrong' }
        Mock Enable-ScheduledTask
        Mock Disable-ScheduledTask
        Mock Export-ScheduledTask { '<Task/>' }
    }
    It ('registers a task as a user with a saved password, as a service ' +
        'account, or as SYSTEM') {
        $data = @(
            [pscustomobject]@{
                TaskName      = 'Saved'
                TaskPath      = '\HC\'
                Enabled       = $true
                Xml           = '<Task/>'
                RunAsUser     = 'PC1\backup'
                RunAsPassword = 'S3cret!'
            }
            [pscustomobject]@{
                TaskName  = 'Service'
                TaskPath  = '\HC\'
                Enabled   = $true
                Xml       = '<Task/>'
                RunAsUser = 'S-1-5-19'
            }
            [pscustomobject]@{
                TaskName = 'Default'
                TaskPath = '\HC\'
                Enabled  = $true
                Xml      = '<Task/>'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages[0] | Should -Be (
            "Created scheduled task '\HC\Saved' (enabled, runs as " +
            "'PC2\backup' with saved password)"
        )
        $invokeParams = @{
            CommandName = 'Register-ScheduledTask'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $TaskName -eq 'Saved' -and
            $User -eq 'PC2\backup' -and
            $Password -eq 'S3cret!'
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $TaskName -eq 'Service' -and
            $User -eq 'S-1-5-19' -and
            -not $Password
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $TaskName -eq 'Default' -and $User -eq 'NT AUTHORITY\SYSTEM'
        }
    }
    It ('grants Log on as a batch job to an account with a saved password ' +
        'that does not have it') {
        Mock Get-AccountRightsHC { 'SeInteractiveLogonRight' }
        $data = @(
            [pscustomobject]@{
                TaskName      = 'Saved'
                TaskPath      = '\HC\'
                Enabled       = $true
                Xml           = '<Task/>'
                RunAsUser     = 'kiosk'
                RunAsPassword = 'S3cret!'
            }
            [pscustomobject]@{
                TaskName  = 'Service'
                TaskPath  = '\HC\'
                Enabled   = $true
                Xml       = '<Task/>'
                RunAsUser = 'S-1-5-19'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -BeNullOrEmpty
        Should -Invoke Add-AccountRightHC -ParameterFilter {
            $Sid -eq 'S-1-5-21-1-2-3-1001' -and $Right -eq 'SeBatchLogonRight'
        } -Times 1 -Exactly
        Should -Invoke Get-AccountSidHC -ParameterFilter {
            $Name -eq 'kiosk'
        } -Times 1 -Exactly
        $result[0].Messages[0] | Should -Be (
            "Granted 'Log on as a batch job' to 'kiosk', needed for " +
            "scheduled task '\HC\Saved'"
        )
    }
    It 'reports a wrong password and a password without a user' {
        $data = @(
            [pscustomobject]@{
                TaskName      = 'Wrong'
                TaskPath      = '\HC\'
                Enabled       = $true
                Xml           = '<Task/>'
                RunAsUser     = 'kiosk'
                RunAsPassword = 'wrong'
            }
            [pscustomobject]@{
                TaskName      = 'NoUser'
                TaskPath      = '\HC\'
                Enabled       = $true
                Xml           = '<Task/>'
                RunAsPassword = 'x'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to register scheduled task '\HC\Wrong': " +
                'The user name or password is incorrect.')
            ("Failed to register scheduled task '\HC\NoUser': " +
                'RunAsPassword needs RunAsUser, the account the password ' +
                'is for')
        )
    }
    It 'exports the account, with a password placeholder for a saved password' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName  = 'Backup'
                TaskPath  = '\HC\'
                Settings  = @{ Enabled = $true }
                Principal = [pscustomobject]@{
                    UserId    = 'PC1\backup'
                    LogonType = 'Password'
                }
            }
            [pscustomobject]@{
                TaskName  = 'Cleanup'
                TaskPath  = '\HC\'
                Settings  = @{ Enabled = $true }
                Principal = [pscustomobject]@{
                    UserId    = 'SYSTEM'
                    LogonType = 'ServiceAccount'
                }
            }
            [pscustomobject]@{
                TaskName  = 'ForUsers'
                TaskPath  = '\HC\'
                Settings  = @{ Enabled = $true }
                Principal = [pscustomobject]@{
                    UserId    = $null
                    GroupId   = 'Users'
                    LogonType = 'Group'
                }
            }
        } -ParameterFilter { $TaskPath -eq '\HC\*' }

        $result = @(& $scriptPath -Action Export -RootFolder $TestDrive)

        $tasks = @{}
        foreach ($task in $result[0].Data) { $tasks[$task.TaskName] = $task }
        $tasks['Backup'].RunAsUser | Should -Be 'PC1\backup'
        $tasks['Backup'].RunAsPassword | Should -Be (
            "{{password:Password of 'PC1\backup' for scheduled task " +
            "'\HC\Backup'}}"
        )
        $tasks['Cleanup'].RunAsUser | Should -Be 'S-1-5-18'
        $tasks['Cleanup'].PSObject.Properties.Name |
            Should -Not -Contain 'RunAsPassword'
        $tasks['ForUsers'].PSObject.Properties.Name |
            Should -Not -Contain 'RunAsUser'
        $result[0].Messages | Should -Contain (
            "Task '\HC\ForUsers' runs for group 'Users', which cannot be " +
            'exported; it is restored to run as SYSTEM unless you set ' +
            'RunAsUser'
        )
    }
}