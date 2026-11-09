#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Execution contract.ps1"

Describe 'Readable report filenames' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\Common\Execution.psm1" -Force
    }
    It ('includes the computer, timestamp, readable action and ' +
        'configuration name') {
        InModuleScope Execution -Parameters @{ ReportFolder = $TestDrive } {
            Mock Get-Date { '20261022-084204' } -ParameterFilter {
                $Format -eq 'yyyyMMdd-HHmmss'
            }
            foreach ($action in @('CreateSnapshot', 'RestoreSnapshot')) {
                $reportParams = @{
                    ReportsFolder     = $ReportFolder
                    Action            = $action
                    ConfigurationFile = 'C:\Configurations\Example PC1.json'
                    Results           = @()
                }
                $path = Write-SnapshotReportHC @reportParams
                $operation = if ($action -eq 'CreateSnapshot') {
                    'Export'
                }
                else {
                    'Restore'
                }

                [IO.Path]::GetFileName($path) | Should -BeExactly (
                    "$env:COMPUTERNAME-20261022-084204-" +
                    "$operation-Example PC1.html"
                )
                $path | Should -Exist
            }
        }
    }
    It ('preserves existing reports when the same configuration runs ' +
        'within one second') {
        InModuleScope Execution -Parameters @{ ReportFolder = $TestDrive } {
            Mock Get-Date { '20261022-084204' } -ParameterFilter {
                $Format -eq 'yyyyMMdd-HHmmss'
            }
            $reportParams = @{
                ReportsFolder     = $ReportFolder
                Action            = 'RestoreSnapshot'
                ConfigurationFile = 'Example.json'
                Results           = @()
            }

            $first = Write-SnapshotReportHC @reportParams
            $original = Get-Content -LiteralPath $first -Raw
            $second = Write-SnapshotReportHC @reportParams
            $third = Write-SnapshotReportHC @reportParams

            [IO.Path]::GetFileName($second) | Should -BeExactly (
                "$env:COMPUTERNAME-20261022-084204-Restore-Example-2.html"
            )
            [IO.Path]::GetFileName($third) | Should -BeExactly (
                "$env:COMPUTERNAME-20261022-084204-Restore-Example-3.html"
            )
            (Get-Content -LiteralPath $first -Raw) |
            Should -BeExactly $original
        }
    }
    It ('shows who exported, when, where the file is saved and that it ' +
        'can be edited') {
        InModuleScope Execution -Parameters @{ ReportFolder = $TestDrive } {
            $reportParams = @{
                ReportsFolder        = $ReportFolder
                Action               = 'CreateSnapshot'
                ConfigurationFile    = 'C:\Configurations\PC 1 & co.json'
                ConfigurationWritten = $true
                Results              = @(
                    [pscustomobject]@{
                        Name = 'UserAccounts'; Status = 'Success'
                        Messages = @('Exported <2> accounts')
                    }
                    [pscustomobject]@{
                        Name = 'MyCustomItem'; Status = 'Failed'
                        Messages = @('ERROR: broken')
                    }
                )
            }
            $html = Get-Content -LiteralPath (
                Write-SnapshotReportHC @reportParams
            ) -Raw

            $html | Should -Not -Match 'CreateSnapshot'
            $html | Should -Match '<h1>Export report</h1>'
            $html | Should -Match '<p>PC 1 &amp; co</p>'
            $html | Should -Match ([regex]::Escape(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name))
            $html | Should -Match "<td>$env:COMPUTERNAME</td>"
            $html | Should -Match '<th>Date</th><td>\d{4}-\d\d-\d\d \d\d:\d\d'
            $html | Should -Match '<th>Saved to</th><td><a href="file:///'
            $html | Should -Match 'C:\\Configurations\\PC 1 &amp; co.json</a>'
            $html | Should -Match 'can be edited|edit it'
            $html | Should -Match 'User accounts<span class="name">UserAccounts'
            $html | Should -Match 'Exported &lt;2&gt; accounts'
            $html | Should -Match '<li class="err">ERROR: broken'
            $html | Should -Match 'Completed with errors'

            $reportParams.ConfigurationWritten = $false
            $html = Get-Content -LiteralPath (
                Write-SnapshotReportHC @reportParams
            ) -Raw
            $html | Should -Match '<th>Not saved</th>'
            $html | Should -Not -Match 'class="note"'

            $reportParams.Action = 'RestoreSnapshot'
            $html = Get-Content -LiteralPath (
                Write-SnapshotReportHC @reportParams
            ) -Raw
            $html | Should -Match '<h1>Restore report</h1>'
            $html | Should -Match '<th>Configuration</th>'
        }
    }
}

Describe 'Prompted password output protection' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\Common\Execution.psm1" -Force
    }
    It ('redacts child host, warning and nonterminating error streams ' +
        'while preserving the result object') {
        $child = Join-Path $TestDrive 'output.ps1'
        @'
param($Action, $Data, $RootFolder)
Write-Host "Host $Data"
Write-Warning "Warning $Data"
Write-Error "Error $Data"
[pscustomobject]@{
    Data     = $null
    Messages = [string[]]@('Completed')
    Errors   = [string[]]@()
}
'@ | Set-Content -LiteralPath $child -Encoding UTF8

        $scopeParams = @{ Child = $child; Root = $TestDrive }
        InModuleScope Execution -Parameters $scopeParams {
            $childParams = @{
                Path         = $Child
                Action       = 'Import'
                Data         = 'Test-secret!42'
                RootFolder   = $Root
                SecretValues = @('Test-secret!42')
            }
            $output = @(Invoke-ChildScriptHC @childParams *>&1)

            ($output | Out-String) | Should -Not -Match 'Test-secret'
            ($output | Out-String) | Should -Match '\[redacted\]'
            @(
                $output | Where-Object {
                    $_ -is [System.Management.Automation.ErrorRecord]
                }
            ).Count | Should -Be 1
            @(
                $output | Where-Object { $_.Messages -contains 'Completed' }
            ).Count | Should -Be 1
        }
    }
}

Describe 'Main entry point script catalogue' {
    BeforeAll {
        $entryScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"
    }
    It ('exports a selected section without data as an empty entry, using ' +
        'the default catalogue, without changing Windows') {
        $path = Join-Path $TestDrive 'default.json'
        $params = @{
            Action              = 'CreateSnapshot'
            ConfigurationFile   = $path
            Items               = 'CreateFolders'
            ReportsFolder       = $TestDrive
            OpenReportInBrowser = $false
        }

        $result = & $entryScript @params

        $result.Success | Should -BeTrue
        $result.ReportFile | Should -Exist
        $text = Get-Content -LiteralPath $path -Raw
        $json = $text | ConvertFrom-Json
        @($json.Items.PSObject.Properties.Name) | Should -Be @('CreateFolders')
        $text | Should -Match '"CreateFolders": \{\}'
    }
    It 'preserves explicit script-map overrides' {
        $child = Join-Path $TestDrive 'custom.ps1'
        @'
param($Action, $Data, $RootFolder)
[pscustomobject]@{
    Data = [pscustomobject]@{ FolderPaths = @('C:\CustomCatalogueTest') }
    Messages = [string[]]@('Custom export')
    Errors = [string[]]@()
}
'@ | Set-Content -LiteralPath $child -Encoding UTF8
        $path = Join-Path $TestDrive 'custom.json'
        $params = @{
            Action              = 'CreateSnapshot'
            ConfigurationFile   = $path
            Script              = [ordered]@{ CreateFolders = $child }
            ReportsFolder       = $TestDrive
            OpenReportInBrowser = $false
        }

        $result = & $entryScript @params

        $result.Success | Should -BeTrue
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json.Items.CreateFolders.FolderPaths |
        Should -Be @('C:\CustomCatalogueTest')
        $result.Results[0].Messages | Should -Contain 'Custom export'
    }
}

Describe 'Child script error reporting' {
    BeforeAll {
        $entryScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"

        $partialChild = Join-Path $TestDrive 'partial.ps1'
        @'
param($Action, $Data, $RootFolder)
foreach ($entry in 'A', 'B', 'C') {
    try {
        if ($entry -ne 'A') { throw "entry $entry rejected" }
        $null = $entry
    }
    catch { Write-Error "Failed entry ${entry}: $_" }
}
[pscustomobject]@{
    Data     = [pscustomobject]@{ FolderPaths = @('C:\Partial') }
    Messages = [string[]]@('Applied entry A')
    Errors   = [string[]]@()
}
'@ | Set-Content -LiteralPath $partialChild -Encoding UTF8

        $throwingChild = Join-Path $TestDrive 'throwing.ps1'
        @'
param($Action, $Data, $RootFolder)
Write-Error 'first problem'
throw 'fatal problem'
'@ | Set-Content -LiteralPath $throwingChild -Encoding UTF8

        $goodChild = Join-Path $TestDrive 'good.ps1'
        @'
param($Action, $Data, $RootFolder)
[pscustomobject]@{
    Data     = [pscustomobject]@{ FolderPaths = @('C:\Good') }
    Messages = [string[]]@('Exported good')
    Errors   = [string[]]@()
}
'@ | Set-Content -LiteralPath $goodChild -Encoding UTF8
    }
    BeforeEach {
        $path = Join-Path $TestDrive (
            ([guid]::NewGuid().ToString('N')) + '.json'
        )
        $params = @{
            Action              = 'CreateSnapshot'
            ConfigurationFile   = $path
            ReportsFolder       = $TestDrive
            OpenReportInBrowser = $false
            Script              = [ordered]@{
                UserAccounts  = $partialChild
                FirewallRules = $throwingChild
                CreateFolders = $goodChild
            }
        }
    }
    It ('reports every error once, keeps the success messages and still ' +
        'runs the other sections') {
        $result = & $entryScript @params 3>$null

        $result.Success | Should -BeFalse
        $users = $result.Results | Where-Object Name -EQ 'UserAccounts'
        $users.Status | Should -Be 'Failed'
        $users.Messages | Should -Contain 'Applied entry A'
        @(
            $users.Messages | Where-Object { $_ -like 'ERROR: Failed entry B*' }
        ).Count | Should -Be 1
        @(
            $users.Messages | Where-Object { $_ -like 'ERROR: Failed entry C*' }
        ).Count | Should -Be 1
        @(
            $users.Messages | Where-Object {
                $_ -like '*rejected*' -and $_ -notlike 'ERROR: Failed entry*'
            }
        ).Count | Should -Be 0
        ($result.Results | Where-Object Name -EQ 'CreateFolders').Status |
        Should -Be 'Success'
    }
    It 'keeps errors written before a terminating error' {
        $result = & $entryScript @params 3>$null

        $firewall = $result.Results | Where-Object Name -EQ 'FirewallRules'
        $firewall.Status | Should -Be 'Failed'
        $firewall.Messages | Should -Be @(
            'ERROR: first problem'
            'ERROR: fatal problem'
        )
    }
    It 'reports a terminating error from nested functions only once' {
        $nestedChild = Join-Path $TestDrive 'nested.ps1'
        @'
param($Action, $Data, $RootFolder)
function Invoke-InnerHC { [CmdletBinding()] param() throw 'nested failure' }
function Invoke-OuterHC { [CmdletBinding()] param() Invoke-InnerHC }
Invoke-OuterHC
'@ | Set-Content -LiteralPath $nestedChild -Encoding UTF8
        $params.Script.FirewallRules = $nestedChild

        $result = & $entryScript @params 3>$null

        ($result.Results | Where-Object Name -EQ 'FirewallRules').Messages |
        Should -Be @('ERROR: nested failure')
    }
    It 'does not depend on the caller error preference' {
        $ErrorActionPreference = 'Stop'

        $result = & $entryScript @params 3>$null

        @($result.Results | Where-Object Status -EQ 'Failed').Count |
        Should -Be 2
        ($result.Results | Where-Object Name -EQ 'CreateFolders').Status |
        Should -Be 'Success'
    }
    It ('exports the data of sections without errors, and a failed section ' +
        'empty') {
        $null = & $entryScript @params 3>$null

        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($json.Items.PSObject.Properties.Name) |
            Should -Be @('UserAccounts', 'FirewallRules', 'CreateFolders')
        @($json.Items.UserAccounts).Count | Should -Be 0
        @($json.Items.FirewallRules).Count | Should -Be 0
        $json.Items.CreateFolders.FolderPaths | Should -Not -BeNullOrEmpty
    }
}

Describe 'Child error capture with password redaction' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\Common\Execution.psm1" -Force
    }
    It 'reports the same errors with and without secrets' {
        $child = Join-Path $TestDrive 'errors.ps1'
        @'
param($Action, $Data, $RootFolder)
try { throw "handled $Data" } catch { Write-Error "Failed with $Data" }
Write-Error 'second problem'
[pscustomobject]@{
    Data     = $null
    Messages = [string[]]@('Completed')
    Errors   = [string[]]@()
}
'@ | Set-Content -LiteralPath $child -Encoding UTF8

        $scopeParams = @{ Child = $child; Root = $TestDrive }
        InModuleScope Execution -Parameters $scopeParams {
            foreach ($secrets in @(@(), @('Test-secret!42'))) {
                $childParams = @{
                    Path         = $Child
                    Action       = 'Import'
                    Data         = 'Test-secret!42'
                    RootFolder   = $Root
                    SecretValues = $secrets
                    ErrorAction  = 'Continue'
                }
                $streams = @(Invoke-ChildScriptHC @childParams 2>&1)
                $errors = @(
                    $streams | Where-Object {
                        $_ -is [System.Management.Automation.ErrorRecord]
                    }
                )
                $errors.Count | Should -Be 2
            }
            ([string]$errors[0]) | Should -Be 'Failed with [redacted]'
            ([string]$errors[1]) | Should -Be 'second problem'
        }
    }
}

Describe 'Script map validation' {
    BeforeAll {
        $entryScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"
        $child = Join-Path $TestDrive 'child.ps1'
        @'
param($Action, $Data, $RootFolder)
[pscustomobject]@{
    Data     = [pscustomobject]@{ FolderPaths = @('C:\MapTest') }
    Messages = [string[]]@('Exported')
    Errors   = [string[]]@()
}
'@ | Set-Content -LiteralPath $child -Encoding UTF8
    }
    BeforeEach {
        $path = Join-Path $TestDrive (
            ([guid]::NewGuid().ToString('N')) + '.json'
        )
        $params = @{
            Action              = 'CreateSnapshot'
            ConfigurationFile   = $path
            ReportsFolder       = $TestDrive
            OpenReportInBrowser = $false
        }
    }
    It 'rejects an unknown item in the script map before any child runs' {
        $params.Script = [ordered]@{
            CreateFolders = $child
            MyCustomItem  = $child
        }

        { & $entryScript @params 3>$null } | Should -Throw '*No items executed*'

        $path | Should -Not -Exist
        $report = Get-ChildItem -LiteralPath $TestDrive -Filter '*.html' |
        Sort-Object LastWriteTime | Select-Object -Last 1
        (Get-Content -LiteralPath $report.FullName -Raw) |
        Should -Match 'MyCustomItem'
    }
    It 'rejects an unknown item name in Items' {
        $params.Script = [ordered]@{ CreateFolders = $child }
        $params.Items = @('CreateFolders', 'Typo')

        { & $entryScript @params 3>$null } | Should -Throw '*No items executed*'

        $path | Should -Not -Exist
    }
    It 'rejects a known item that has no script in the map' {
        $params.Script = [ordered]@{ CreateFolders = $child }
        $params.Items = @('UserAccounts')

        { & $entryScript @params 3>$null } | Should -Throw '*No items executed*'
    }
    It 'accepts item names in any case and stores the official name' {
        $params.Script = [ordered]@{ CreateFolders = $child }
        $params.Items = @('createfolders')

        $result = & $entryScript @params 3>$null

        $result.Success | Should -BeTrue
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($json.Items.PSObject.Properties.Name) |
        Should -BeExactly @('CreateFolders')
    }
}
