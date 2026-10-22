#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
. "$PSScriptRoot\Common\Execution contract.ps1"

Describe 'Readable report filenames' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\Scripts\Common\Execution.psm1" -Force
    }
    It 'includes the computer, timestamp, readable action and configuration name' {
        InModuleScope Execution -Parameters @{ ReportFolder = $TestDrive } {
            Mock Get-Date { '20261022-084204' } -ParameterFilter { $Format -eq 'yyyyMMdd-HHmmss' }
            foreach ($action in @('CreateSnapshot', 'RestoreSnapshot')) {
                $path = Write-SnapshotReportHC -ReportsFolder $ReportFolder -Action $action -ConfigurationFile 'C:\Configurations\Example PC1.json' -Results @()
                $operation = if ($action -eq 'CreateSnapshot') { 'Export' } else { 'Restore' }
                [IO.Path]::GetFileName($path) | Should -BeExactly "$env:COMPUTERNAME-20261022-084204-$operation-Example PC1.html"
                $path | Should -Exist
            }
        }
    }
    It 'preserves existing reports when the same configuration runs within one second' {
        InModuleScope Execution -Parameters @{ ReportFolder = $TestDrive } {
            Mock Get-Date { '20261022-084204' } -ParameterFilter { $Format -eq 'yyyyMMdd-HHmmss' }
            $first = Write-SnapshotReportHC -ReportsFolder $ReportFolder -Action RestoreSnapshot -ConfigurationFile 'Example.json' -Results @()
            $original = Get-Content -LiteralPath $first -Raw
            $second = Write-SnapshotReportHC -ReportsFolder $ReportFolder -Action RestoreSnapshot -ConfigurationFile 'Example.json' -Results @()
            $third = Write-SnapshotReportHC -ReportsFolder $ReportFolder -Action RestoreSnapshot -ConfigurationFile 'Example.json' -Results @()
            [IO.Path]::GetFileName($second) | Should -BeExactly "$env:COMPUTERNAME-20261022-084204-Restore-Example-2.html"
            [IO.Path]::GetFileName($third) | Should -BeExactly "$env:COMPUTERNAME-20261022-084204-Restore-Example-3.html"
            (Get-Content -LiteralPath $first -Raw) | Should -BeExactly $original
        }
    }
}

Describe 'Prompted password output protection' {
    BeforeAll { Import-Module "$PSScriptRoot\..\Scripts\Common\Execution.psm1" -Force }
    It 'redacts child host, warning and nonterminating error streams while preserving the result object' {
        $child = Join-Path $TestDrive 'output.ps1'
        @'
param($Action, $Data, $RootFolder)
Write-Host "Host $Data"
Write-Warning "Warning $Data"
Write-Error "Error $Data"
[pscustomobject]@{ Data = $null; Messages = [string[]]@('Completed') }
'@ | Set-Content -LiteralPath $child -Encoding UTF8
        InModuleScope Execution -Parameters @{ Child = $child; Root = $TestDrive } {
            $output = @(Invoke-ChildScriptHC -Path $Child -Action Import -Data 'Test-secret!42' -RootFolder $Root -SecretValues @('Test-secret!42') *>&1)
            ($output | Out-String) | Should -Not -Match 'Test-secret'
            ($output | Out-String) | Should -Match '\[redacted\]'
            @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 1
            @($output | Where-Object { $_.Messages -contains 'Completed' }).Count | Should -Be 1
        }
    }
}

Describe 'Main entry point script catalogue' {
    BeforeAll {
        $entryScript = "$PSScriptRoot\..\Scripts\Invoke scripts.ps1"
    }
    It 'exports a template using the default catalogue without changing Windows' {
        $path = Join-Path $TestDrive 'default.json'
        $result = & $entryScript -Action CreateSnapshot -ConfigurationFile $path -Items CreateFolders -ReportsFolder $TestDrive -OpenReportInBrowser $false
        $result.Success | Should -BeTrue
        $result.ReportFile | Should -Exist
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Items.CreateFolders.FolderPaths.Count | Should -BeGreaterThan 0
    }
    It 'preserves explicit script-map overrides' {
        $child = Join-Path $TestDrive 'custom.ps1'
        @'
param($Action, $Data, $RootFolder)
[pscustomobject]@{
    Data = [pscustomobject]@{ FolderPaths = @('C:\CustomCatalogueTest') }
    Messages = [string[]]@('Custom export')
}
'@ | Set-Content -LiteralPath $child -Encoding UTF8
        $path = Join-Path $TestDrive 'custom.json'
        $result = & $entryScript -Action CreateSnapshot -ConfigurationFile $path -Script ([ordered]@{ CreateFolders = $child }) -ReportsFolder $TestDrive -OpenReportInBrowser $false
        $result.Success | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Items.CreateFolders.FolderPaths | Should -Be @('C:\CustomCatalogueTest')
        $result.Results[0].Messages | Should -Contain 'Custom export'
    }
}