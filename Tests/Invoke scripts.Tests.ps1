#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
. "$PSScriptRoot\Common\Execution contract.ps1"

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