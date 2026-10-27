Describe 'Single-file execution' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\..\Scripts\Common\Execution.psm1" -Force
        Import-Module "$PSScriptRoot\..\..\Scripts\Common\Configuration.psm1" -Force
        $scriptPath = Join-Path $PSScriptRoot '..\..\Scripts\Folders import export.ps1'
    }
    BeforeEach {
        $path = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '.json')
        $params = @{
            Action = 'CreateSnapshot'; ConfigurationFile = $path; RootFolder = $TestDrive
            Script = [ordered]@{ UserAccounts = $scriptPath; CreateFolders = $scriptPath }
            Items = @('CreateFolders', 'UserAccounts'); OpenReportInBrowser = $false
        }
        Mock Write-SnapshotReportHC -ModuleName Execution { Join-Path $TestDrive 'report.html' }
        Mock Test-ElevatedHC -ModuleName Execution { $true }
        Mock Write-Host -ModuleName Execution
        Mock Write-Warning -ModuleName Execution
        Mock Restart-Computer -ModuleName Execution
        Mock Start-Process -ModuleName Execution
        Mock Invoke-ChildScriptHC -ModuleName Execution { [pscustomobject]@{ Data = @(); Messages = [string[]]@('Exported') } }
        Mock Read-RestoreInputHC -ModuleName Execution { throw 'Unexpected input prompt in test.' }
    }
    It 'writes exactly one file and creates no folders' {
        $params.Items = @('UserAccounts')
        $before = @(Get-ChildItem $TestDrive -Recurse).Count
        $result = Invoke-ComputerSnapshotHC @params
        @(Get-ChildItem $TestDrive -Recurse).Count | Should -Be ($before + 1)
        @(Get-ChildItem $TestDrive -Directory).Count | Should -Be 0
        $path | Should -Exist
        @(Test-ConfigurationHC (Read-ConfigurationHC $path $TestDrive) $TestDrive).Count | Should -Be 0
        $result.Success | Should -BeTrue
    }
    It 'rejects an existing file before any child runs unless Force is used' {
        'existing' | Set-Content $path
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*already exists*'
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
        $params.Items = @('UserAccounts')
        Invoke-ComputerSnapshotHC @params -Force
        @(Test-ConfigurationHC (Read-ConfigurationHC $path $TestDrive) $TestDrive).Count | Should -Be 0
    }
    It 'keeps successful sections when another export throws' {
        $params.Script.CreateFolders = Join-Path $PSScriptRoot '..\..\Scripts\User accounts import export.ps1'
        Mock Invoke-ChildScriptHC -ModuleName Execution { throw 'Export failed' } -ParameterFilter { $Path -like '*User accounts import export.ps1' }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $loaded = Read-ConfigurationHC $path $TestDrive
        @($loaded.Items.Keys) | Should -Be @('UserAccounts')
    }
    It 'writes no configuration when all exports fail' {
        Mock Invoke-ChildScriptHC -ModuleName Execution { throw 'Export failed' }
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*No items exported*'
        $path | Should -Not -Exist
    }
    It 'runs no child scripts if restore validation fails' {
        '{"SchemaVersion":1,"Items":{"Unknown":{}}}' | Set-Content $path
        $params.Action = 'RestoreSnapshot'
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*No items executed*'
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 1 -Exactly
    }
    It 'restores in fixed order independently of JSON key order' {
        $document = @{ SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }; Items = [ordered]@{ CreateFolders = @{ FolderPaths = @('C:\Example') }; UserAccounts = @(@{ Name = 'Example' }) } }
        Write-ConfigurationHC $document $path
        $params.Action = 'RestoreSnapshot'
        $script:order = New-Object 'System.Collections.Generic.List[string]'
        Mock Invoke-ChildScriptHC -ModuleName Execution {
            if (-not $Data.FolderPaths) { $Data.GetType().IsArray | Should -BeTrue }
            $script:order.Add($(if ($Data.FolderPaths) { 'CreateFolders' } else { 'UserAccounts' }))
            [pscustomobject]@{ Data = $null; Messages = [string[]]@('Imported') }
        }
        Invoke-ComputerSnapshotHC @params
        @($script:order) | Should -Be @('UserAccounts', 'CreateFolders')
    }
    It 'skips and reports empty sections' {
        Write-ConfigurationHC @{ SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }; Items = @{ UserAccounts = @() } } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $result = Invoke-ComputerSnapshotHC @params
        $result.Results[0].Status | Should -Be 'Skipped'
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
    }
    It 'reports a failed time-service operation and never reboots after it' {
        Write-ConfigurationHC @{
            SchemaVersion = 2
            Settings = @{ OpenReportInBrowser = $false; RebootComputer = $true }
            Items = @{ NtpTimeServers = @{ SyncTimeWithDomain = $true; TimeServerNames = @() } }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $params.Script = [ordered]@{ NtpTimeServers = Join-Path $PSScriptRoot '..\..\Scripts\NTP time servers import export.ps1' }
        Mock Invoke-ChildScriptHC -ModuleName Execution { throw 'w32tm /resync failed with exit code 1: No time data available' }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Failed'
        $result.Results[0].Messages[0] | Should -Match 'exit code 1'
        Should -Invoke Restart-Computer -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 1 -Exactly
    }
    It 'restores only selected sections without changing the configuration file' {
        Write-ConfigurationHC @{
            SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }
            Items = @{ UserAccounts = @(@{ Name = 'Example' }); CreateFolders = @{ FolderPaths = @('C:\Example') } }
        } $path
        $before = Get-Content -LiteralPath $path -Raw
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CreateFolders')
        $result = Invoke-ComputerSnapshotHC @params
        @($result.Results.Name) | Should -Be @('CreateFolders')
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 1 -Exactly -ParameterFilter { $Data.FolderPaths -contains 'C:\Example' }
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
    }
    It 'does not resolve references or validate assets in unchecked sections' {
        Write-ConfigurationHC @{
            SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }
            Items = @{
                UserAccounts = 'missing-users.json'
                Software = @{ Install = @(@{ ExecutablePath = 'missing-installer.exe' }) }
                CreateFolders = @{ FolderPaths = @('C:\Example') }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CreateFolders')
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 1 -Exactly
    }
    It 'restores all configured sections when no selection is supplied' {
        Write-ConfigurationHC @{
            SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }
            Items = @{ UserAccounts = @(@{ Name = 'Example' }); CreateFolders = @{ FolderPaths = @('C:\Example') } }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $result = Invoke-ComputerSnapshotHC @params
        @($result.Results.Name) | Should -Be @('UserAccounts', 'CreateFolders')
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 2 -Exactly
    }
    It 'honors both true and false per-run settings without changing the file' {
        foreach ($override in @($false, $true)) {
            Write-ConfigurationHC @{
                SchemaVersion = 2
                Settings = @{ RebootComputer = -not $override; OpenReportInBrowser = -not $override }
                Items = @{ UserAccounts = @(@{ Name = 'Example' }) }
            } $path
            $before = Get-Content -LiteralPath $path -Raw
            $params.Action = 'RestoreSnapshot'
            $params.Items = @('UserAccounts')
            $params.RebootComputer = $override
            $params.OpenReportInBrowser = $override
            (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
            (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
            $expected = [int]$override
            Should -Invoke Restart-Computer -ModuleName Execution -Times $expected -Exactly
            Should -Invoke Start-Process -ModuleName Execution -Times $expected -Exactly
        }
    }
    It 'uses saved settings when overrides are omitted' {
        Write-ConfigurationHC @{
            SchemaVersion = 2
            Settings = @{ RebootComputer = $true; OpenReportInBrowser = $true }
            Items = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.Remove('OpenReportInBrowser')
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Restart-Computer -ModuleName Execution -Times 1 -Exactly
        Should -Invoke Start-Process -ModuleName Execution -Times 1 -Exactly
    }
    It 'does not reboot after a failed restore even when overridden to true' {
        Write-ConfigurationHC @{
            SchemaVersion = 2
            Settings = @{ RebootComputer = $false; OpenReportInBrowser = $false }
            Items = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.RebootComputer = $true
        Mock Invoke-ChildScriptHC -ModuleName Execution { throw 'Restore failed' }
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeFalse
        Should -Invoke Restart-Computer -ModuleName Execution -Times 0 -Exactly
    }
    It 'collects selected shared-section inputs before execution, redacts passwords, and preserves source files' {
        $sharedPath = Join-Path $TestDrive 'users.json'
        '[{"Name":"{{input:Local account}}","Password":"{{password:Local password}}"}]' | Set-Content -LiteralPath $sharedPath
        Write-ConfigurationHC @{
            SchemaVersion = 2; Settings = @{ OpenReportInBrowser = $false }
            Items = @{ UserAccounts = 'users.json'; Software = @{ Install = @(@{ ExecutablePath = '{{input:Unselected installer}}' }) } }
        } $path
        $before = Get-Content -LiteralPath $path -Raw
        $sharedBefore = Get-Content -LiteralPath $sharedPath -Raw
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC -ModuleName Execution {
            Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
            if ($Field.Kind -eq 'password') { 'Test-secret!42' } else { 'Example' }
        }
        Mock Invoke-ChildScriptHC -ModuleName Execution {
            $Data[0].Name | Should -Be 'Example'
            $Data[0].Password | Should -Be 'Test-secret!42'
            [pscustomobject]@{ Data = $null; Messages = [string[]]@('Applied Test-secret!42') }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.Results[0].Messages | Should -Be @('Applied [redacted]')
        Should -Invoke Read-RestoreInputHC -ModuleName Execution -Times 2 -Exactly
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
        (Get-Content -LiteralPath $sharedPath -Raw) | Should -BeExactly $sharedBefore
    }
    It 'cancels before any script, report or reboot when an input dialog is cancelled' {
        Write-ConfigurationHC @{ SchemaVersion = 2; Settings = @{ RebootComputer = $true }; Items = @{ UserAccounts = @(@{ Name = '{{input:Account}}' }) } } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC -ModuleName Execution { $null }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Cancelled | Should -BeTrue
        $result.Success | Should -BeFalse
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Restart-Computer -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Start-Process -ModuleName Execution -Times 0 -Exactly
    }
    It 'redacts prompted passwords from child failure results and reports' {
        Write-ConfigurationHC @{ SchemaVersion = 2; Items = @{ UserAccounts = @(@{ Name = 'Example'; Password = '{{password:Password}}' }) } } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC -ModuleName Execution { 'Test-secret!42' }
        Mock Invoke-ChildScriptHC -ModuleName Execution { throw 'Rejected Test-secret!42' }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $result.Results[0].Messages | Should -Be @('ERROR: Rejected [redacted]')
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 1 -Exactly -ParameterFilter { $Results[0].Messages -notmatch 'Test-secret' }
    }
    It 'validates resolved values before any child runs and redacts validation messages' {
        Write-ConfigurationHC @{ SchemaVersion = 2; Items = @{ Software = @{ Install = @(@{ ExecutablePath = '{{password:Installer path}}' }) } } } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('Software')
        Mock Read-RestoreInputHC -ModuleName Execution { 'Test-secret!42' }
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*validation failed*'
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
        Should -Invoke Write-Warning -ModuleName Execution -Times 0 -Exactly -ParameterFilter { $Message -match 'Test-secret' }
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 1 -Exactly -ParameterFilter {
            ($Results | ConvertTo-Json -Depth 10) -notmatch 'Test-secret' -and ($Results | ConvertTo-Json -Depth 10) -match '\[redacted\]'
        }
    }
    It 'rejects an empty or unavailable restore selection' {
        Write-ConfigurationHC @{ SchemaVersion = 2; Items = @{ UserAccounts = @() } } $path
        $params.Action = 'RestoreSnapshot'
        foreach ($selection in @(@(), @('CreateFolders'), @('Unknown'))) {
            $params.Items = $selection
            { Invoke-ComputerSnapshotHC @params } | Should -Throw '*No items executed*'
        }
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
    }
    It 'keeps the existing configuration and still writes the report when saving fails' {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        $before = Get-Content -LiteralPath $path -Raw
        $params.Items = @('UserAccounts')
        Mock Write-ConfigurationHC -ModuleName Execution { throw 'disk full' }
        $result = Invoke-ComputerSnapshotHC @params -Force
        $result.Success | Should -BeFalse
        $failed = $result.Results | Where-Object Name -EQ 'Configuration file'
        $failed.Status | Should -Be 'Failed'
        $failed.Messages[0] | Should -BeLike 'ERROR: *disk full*'
        ($result.Results | Where-Object Name -EQ 'UserAccounts').Status | Should -Be 'Success'
        @($result.Results.Name) | Should -Not -Contain 'Export validation'
        Should -Invoke Write-SnapshotReportHC -ModuleName Execution -Times 1 -Exactly
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
    }
}