#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
BeforeAll {
    Import-Module "$PSScriptRoot\..\Scripts\Common\Configuration.psm1" -Force
    $testScript = "$PSScriptRoot\..\Scripts\Convert configuration.ps1"
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
}
Describe 'One-time configuration conversion' {
    It 'converts the original example without deleting its data and matches expected JSON' {
        $null = New-Item -Path "$TestDrive\Configurations", "$TestDrive\Software" -ItemType Directory -Force
        Copy-Item -LiteralPath "$repositoryRoot\Snapshots" -Destination "$TestDrive\Snapshots" -Recurse
        Copy-Item -LiteralPath "$repositoryRoot\Software\App hello world 1.exe" -Destination "$TestDrive\Software"
        $oldPath = Join-Path $TestDrive 'Configurations\RestoreSnapshot PC1 Example.json'
        Copy-Item -LiteralPath "$PSScriptRoot\Fixtures\RestoreSnapshot PC1 Example.v1.json" -Destination $oldPath
        $originalHash = (Get-FileHash -LiteralPath $oldPath).Hash
        $result = & $testScript -OldConfigurationFile $oldPath -RootFolder $TestDrive
        $result.Problems.Count | Should -Be 0
        (Get-FileHash -LiteralPath $result.Original).Hash | Should -Be $originalHash
        "$TestDrive\Snapshots\RestoreSnapshot PC1 Example\Software\Packages\App hello world 2.exe" | Should -Exist
        "$TestDrive\Software\App hello world 2.exe" | Should -Exist
        $actual = Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
        $expected = Get-Content -LiteralPath "$PSScriptRoot\Fixtures\Converted configuration.json" -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
        $actual | Should -Be $expected
    }
    It 'does not overwrite an existing migration backup' {
        $oldPath = Join-Path $TestDrive 'Configurations\RestoreSnapshot PC1 Example.json'
        $legacy = @{ StartScript = @{ SnapshotFolder = '..\..\Snapshots\RestoreSnapshot PC1 Example'; Snapshot = @{ Software = $true } } }
        $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath
        { & $testScript -OldConfigurationFile $oldPath -RootFolder $TestDrive } | Should -Throw '*already exists*'
    }
    It 'flattens share arrays and embeds task XML without deleting original files' {
        $legacyRoot = Join-Path $TestDrive 'Legacy'
        $null = New-Item -Path "$legacyRoot\SmbShares", "$legacyRoot\ScheduledTasks" -ItemType Directory -Force
        '[{"Name":"Example","Path":"C:\\Example"}]' | Set-Content "$legacyRoot\SmbShares\SmbShares.json"
        '[]' | Set-Content "$legacyRoot\SmbShares\SmbSharesAccess.json"
        [pscustomobject]@{ TaskName = 'Example'; TaskPath = '\HC\'; Settings = @{ Enabled = $false } } | Export-Clixml "$legacyRoot\ScheduledTasks\1 - Example.xml"
        '<Task/>' | Set-Content "$legacyRoot\ScheduledTasks\1 - Example - Definition.xml"
        $oldPath = Join-Path $TestDrive 'Configurations\Tasks and shares.json'
        @{ StartScript = @{ SnapshotFolder = $legacyRoot; Snapshot = @{ ScheduledTasks = $true; SmbShares = $true } } } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath
        $result = & $testScript -OldConfigurationFile $oldPath -RootFolder $TestDrive
        $result.Problems.Count | Should -Be 0
        $loaded = Read-ConfigurationHC $result.Path $TestDrive
        $loaded.Items.SmbShares.Shares.Count | Should -Be 1
        $loaded.Items.SmbShares.Shares[0].Name | Should -Be 'Example'
        $loaded.Items.ScheduledTasks[0].Enabled | Should -BeFalse
        $loaded.Items.ScheduledTasks[0].Xml.Trim() | Should -Be '<Task/>'
        "$legacyRoot\ScheduledTasks\1 - Example.xml" | Should -Exist
    }
}