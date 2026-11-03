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
        @($loaded.Items.SmbShares).Count | Should -Be 1
        $loaded.Items.SmbShares[0].Name | Should -Be 'Example'
        $loaded.Items.ScheduledTasks[0].Enabled | Should -BeFalse
        $loaded.Items.ScheduledTasks[0].Xml.Trim() | Should -Be '<Task/>'
        "$legacyRoot\ScheduledTasks\1 - Example.xml" | Should -Exist
    }
    It 'splits version 1 network cards into FindBy and Change' {
        $legacyRoot = Join-Path $TestDrive 'LegacyNetwork'
        $null = New-Item -Path "$legacyRoot\NetworkCards" -ItemType Directory -Force
        '[{"?":"Office","NetworkCardName":"LAN","NetworkCardDescription":"Intel","NetworkCategory":"Private","NetworkCardDnsSuffix":"contoso.com"}]' |
            Set-Content -LiteralPath "$legacyRoot\NetworkCards\NetworkCards.json"
        $oldPath = Join-Path $TestDrive 'Configurations\Network.json'
        @{ StartScript = @{ SnapshotFolder = $legacyRoot; Snapshot = @{ NetworkCards = $true } } } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath
        $result = & $testScript -OldConfigurationFile $oldPath -RootFolder $TestDrive 6>$null
        $result.Problems.Count | Should -Be 0 -Because ($result.Problems -join '; ')
        $card = (Read-ConfigurationHC $result.Path $TestDrive).Items.NetworkCards[0]
        $card.Comment | Should -Be 'Office'
        $card.FindBy.Description | Should -Be 'Intel'
        $card.Change.NewName | Should -Be 'LAN'
        $card.Change.NetworkCategory | Should -Be 'Private'
        $card.Change.DnsSuffix | Should -Be 'contoso.com'
    }
    It 'converts a version-2 configuration in place and moves share permissions into each share' {
        $folder = Join-Path $TestDrive 'Version2'
        $null = New-Item -Path "$folder\Configurations", "$folder\Shared" -ItemType Directory -Force
        $path = Join-Path $folder 'Configurations\Office.json'
        @'
{
  "SchemaVersion": 2,
  "Description": "Office PC",
  "Settings": { "RebootComputer": true },
  "Items": {
    "SmbShares": {
      "Shares": [ { "Name": "Data", "Path": "C:\\Data" }, { "Name": "Scans", "Path": "D:\\Scans" } ],
      "Access": [
        { "Name": "Data", "AccountName": "S-1-5-32-544", "AccessControlType": "Allow", "AccessRight": "Full" },
        { "Name": "Scans", "AccountName": "S-1-5-11", "AccessControlType": "Allow", "AccessRight": "Read" },
        { "Name": "Gone", "AccountName": "S-1-1-0", "AccessControlType": "Allow", "AccessRight": "Read" }
      ],
      "NTFS": [ { "Name": "Data", "Owner": "S-1-5-32-544", "AreAccessRulesProtected": false, "Access": [] } ]
    }
  }
}
'@ | Set-Content -LiteralPath $path -Encoding UTF8
        $original = Get-Content -LiteralPath $path -Raw
        $result = & $testScript -OldConfigurationFile $path -RootFolder $folder 3>$null
        $result.Path | Should -Be $path
        Get-Content -LiteralPath $result.Original -Raw | Should -BeExactly $original
        $result.Problems | Should -Be @("SmbShares: permissions for share 'Gone' were dropped, because that share is not in Shares")
        $loaded = Read-ConfigurationHC $path $folder
        $loaded.SchemaVersion | Should -Be 3
        $loaded.Description | Should -Be 'Office PC'
        $loaded.Settings.RebootComputer | Should -BeTrue
        @($loaded.Items.SmbShares).Count | Should -Be 2
        $data = $loaded.Items.SmbShares | Where-Object { $_.Name -eq 'Data' }
        @($data.Access).Count | Should -Be 1
        $data.Access[0].AccountName | Should -Be 'S-1-5-32-544'
        $data.Access[0].PSObject.Properties.Name | Should -Not -Contain 'Name'
        $data.NTFS.Owner | Should -Be 'S-1-5-32-544'
        ($loaded.Items.SmbShares | Where-Object { $_.Name -eq 'Scans' }).Access[0].AccountName | Should -Be 'S-1-5-11'
        { & $testScript -OldConfigurationFile $path -RootFolder $folder } | Should -Throw '*already a version-3 configuration*'
    }
    It 'turns Software.Remove names into objects, inline and in a shared file' {
        $folder = Join-Path $TestDrive 'Version2Software'
        $null = New-Item -Path "$folder\Configurations", "$folder\Shared" -ItemType Directory -Force
        '{ "Remove": ["Shared App"], "Install": [] }' | Set-Content -LiteralPath "$folder\Shared\Software.json" -Encoding UTF8
        '{ "SchemaVersion": 2, "Items": { "Software": { "Remove": ["Old App", "Other App"] } } }' |
            Set-Content -LiteralPath "$folder\Configurations\Inline.json" -Encoding UTF8
        '{ "SchemaVersion": 2, "Items": { "Software": "Shared\\Software.json" } }' |
            Set-Content -LiteralPath "$folder\Configurations\Shared.json" -Encoding UTF8
        foreach ($name in @('Inline', 'Shared')) {
            $result = & $testScript -OldConfigurationFile "$folder\Configurations\$name.json" -RootFolder $folder 6>$null
            $result.Problems.Count | Should -Be 0 -Because ($result.Problems -join '; ')
        }
        $inline = Read-ConfigurationHC "$folder\Configurations\Inline.json" $folder
        @($inline.Items.Software.Remove.DisplayName) | Should -Be @('Old App', 'Other App')
        $shared = Read-ConfigurationHC "$folder\Configurations\Shared.json" $folder
        @($shared.Items.Software.Remove.DisplayName) | Should -Be @('Shared App')
        "$folder\Shared\Software.v2.json" | Should -Exist
    }
    It 'converts a shared SmbShares file that a version-2 configuration refers to' {
        $folder = Join-Path $TestDrive 'Version2Shared'
        $null = New-Item -Path "$folder\Configurations", "$folder\Shared" -ItemType Directory -Force
        '{ "Shares": [ { "Name": "Common", "Path": "C:\\Common" } ], "Access": [ { "Name": "Common", "AccountName": "S-1-1-0", "AccessControlType": "Allow", "AccessRight": "Read" } ], "NTFS": [] }' |
            Set-Content -LiteralPath "$folder\Shared\Shares.json" -Encoding UTF8
        '{ "SchemaVersion": 2, "Items": { "SmbShares": "Shared\\Shares.json" } }' |
            Set-Content -LiteralPath "$folder\Configurations\Office.json" -Encoding UTF8
        $result = & $testScript -OldConfigurationFile "$folder\Configurations\Office.json" -RootFolder $folder 3>$null
        $result.Problems.Count | Should -Be 0 -Because ($result.Problems -join '; ')
        "$folder\Shared\Shares.v2.json" | Should -Exist
        $loaded = Read-ConfigurationHC "$folder\Configurations\Office.json" $folder
        $loaded.Items.SmbShares[0].Name | Should -Be 'Common'
        $loaded.Items.SmbShares[0].Access[0].AccountName | Should -Be 'S-1-1-0'
    }
}