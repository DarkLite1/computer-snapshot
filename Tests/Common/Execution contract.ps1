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
        $result = Invoke-ComputerSnapshotHC @params
        $result.Results[0].Status | Should -Be 'Skipped'
        Should -Invoke Invoke-ChildScriptHC -ModuleName Execution -Times 0 -Exactly
    }
}