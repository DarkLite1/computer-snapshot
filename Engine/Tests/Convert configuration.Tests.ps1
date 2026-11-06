#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    Import-Module "$PSScriptRoot\..\Common\Configuration.psm1" -Force
    $testScript = "$PSScriptRoot\..\Scripts\Convert configuration.ps1"
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

Describe 'One-time configuration conversion' {
    It ('converts the original example without deleting its data and ' +
        'matches expected JSON') {
        $testParams = @{
            Path     = "$TestDrive\Configurations", "$TestDrive\Software"
            ItemType = 'Directory'
            Force    = $true
        }
        $null = New-Item @testParams
        $testParams = @{
            LiteralPath = "$PSScriptRoot\Fixtures\Snapshots"
            Destination = "$TestDrive\Snapshots"
            Recurse     = $true
        }
        Copy-Item @testParams
        $testParams = @{
            LiteralPath = "$repositoryRoot\Software\App hello world 1.exe"
            Destination = "$TestDrive\Software"
        }
        Copy-Item @testParams
        $oldPath = Join-Path $TestDrive (
            'Configurations\RestoreSnapshot PC1 Example.json'
        )
        $testParams = @{
            LiteralPath = (
                "$PSScriptRoot\Fixtures\RestoreSnapshot PC1 Example.v1.json"
            )
            Destination = $oldPath
        }
        Copy-Item @testParams
        $originalHash = (Get-FileHash -LiteralPath $oldPath).Hash

        $testParams = @{
            OldConfigurationFile = $oldPath
            RootFolder           = $TestDrive
        }
        $result = & $testScript @testParams

        $result.Problems.Count | Should -Be 0
        (Get-FileHash -LiteralPath $result.Original).Hash |
            Should -Be $originalHash
        ("$TestDrive\Snapshots\RestoreSnapshot PC1 Example\Software\" +
            'Packages\App hello world 2.exe') | Should -Exist
        "$TestDrive\Software\App hello world 2.exe" | Should -Exist
        $actual = Get-Content -LiteralPath $result.Path -Raw |
            ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
        $expected = Get-Content -Raw -LiteralPath (
            "$PSScriptRoot\Fixtures\Converted configuration.json"
        ) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
        $actual | Should -Be $expected
    }
    It 'does not overwrite an existing migration backup' {
        $oldPath = Join-Path $TestDrive (
            'Configurations\RestoreSnapshot PC1 Example.json'
        )
        $legacy = @{
            StartScript = @{
                SnapshotFolder = '..\..\Snapshots\RestoreSnapshot PC1 Example'
                Snapshot       = @{ Software = $true }
            }
        }
        $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath

        {
            & $testScript -OldConfigurationFile $oldPath -RootFolder $TestDrive
        } | Should -Throw '*already exists*'
    }
    It ('flattens share arrays and embeds task XML without deleting ' +
        'original files') {
        $legacyRoot = Join-Path $TestDrive 'Legacy'
        $testParams = @{
            Path     = "$legacyRoot\SmbShares", "$legacyRoot\ScheduledTasks"
            ItemType = 'Directory'
            Force    = $true
        }
        $null = New-Item @testParams
        '[{"Name":"Example","Path":"C:\\Example"}]' |
            Set-Content "$legacyRoot\SmbShares\SmbShares.json"
        '[]' | Set-Content "$legacyRoot\SmbShares\SmbSharesAccess.json"
        [pscustomobject]@{
            TaskName = 'Example'
            TaskPath = '\HC\'
            Settings = @{ Enabled = $false }
        } | Export-Clixml "$legacyRoot\ScheduledTasks\1 - Example.xml"
        '<Task/>' | Set-Content (
            "$legacyRoot\ScheduledTasks\1 - Example - Definition.xml"
        )
        $oldPath = Join-Path $TestDrive 'Configurations\Tasks and shares.json'
        @{
            StartScript = @{
                SnapshotFolder = $legacyRoot
                Snapshot       = @{ ScheduledTasks = $true; SmbShares = $true }
            }
        } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath

        $testParams = @{
            OldConfigurationFile = $oldPath
            RootFolder           = $TestDrive
        }
        $result = & $testScript @testParams

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
        $null = New-Item -ItemType Directory -Force -Path (
            "$legacyRoot\NetworkCards"
        )
        ('[{"?":"Office","NetworkCardName":"LAN",' +
            '"NetworkCardDescription":"Intel","NetworkCategory":"Private",' +
            '"NetworkCardDnsSuffix":"contoso.com"}]') |
            Set-Content -LiteralPath (
                "$legacyRoot\NetworkCards\NetworkCards.json"
            )
        $oldPath = Join-Path $TestDrive 'Configurations\Network.json'
        @{
            StartScript = @{
                SnapshotFolder = $legacyRoot
                Snapshot       = @{ NetworkCards = $true }
            }
        } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath

        $testParams = @{
            OldConfigurationFile = $oldPath
            RootFolder           = $TestDrive
        }
        $result = & $testScript @testParams 6>$null

        $result.Problems.Count |
            Should -Be 0 -Because ($result.Problems -join '; ')
        $card = (
            Read-ConfigurationHC $result.Path $TestDrive
        ).Items.NetworkCards[0]
        $card.Comment | Should -Be 'Office'
        $card.FindBy.Description | Should -Be 'Intel'
        $card.Change.NewName | Should -Be 'LAN'
        $card.Change.NetworkCategory | Should -Be 'Private'
        $card.Change.DnsSuffix | Should -Be 'contoso.com'
    }
    It 'turns version 1 Software.Remove names into objects' {
        $legacyRoot = Join-Path $TestDrive 'LegacySoftware'
        $null = New-Item -Path "$legacyRoot\Software" -ItemType Directory -Force
        ('{ "SoftwarePackages": { "Remove": ["Old App", "Other App"], ' +
            '"Install": [] } }') |
            Set-Content -LiteralPath "$legacyRoot\Software\Software.json"
        $oldPath = Join-Path $TestDrive 'Configurations\Software only.json'
        @{
            StartScript = @{
                SnapshotFolder = $legacyRoot
                Snapshot       = @{ Software = $true }
            }
        } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $oldPath

        $testParams = @{
            OldConfigurationFile = $oldPath
            RootFolder           = $TestDrive
        }
        $result = & $testScript @testParams 6>$null

        $result.Problems.Count |
            Should -Be 0 -Because ($result.Problems -join '; ')
        $loaded = Read-ConfigurationHC $result.Path $TestDrive
        @($loaded.Items.Software.Remove.DisplayName) |
            Should -Be @('Old App', 'Other App')
    }
    It 'only converts version 1 files' {
        $path = Join-Path $TestDrive 'Configurations\Other.json'
        '{ "SchemaVersion": 2, "Items": { "UserAccounts": [] } }' |
            Set-Content -LiteralPath $path
        {
            & $testScript -OldConfigurationFile $path -RootFolder $TestDrive
        } | Should -Throw '*version 1*'

        '{ "SchemaVersion": 3, "Items": { "UserAccounts": [] } }' |
            Set-Content -LiteralPath $path
        {
            & $testScript -OldConfigurationFile $path -RootFolder $TestDrive
        } | Should -Throw '*already a version-3 configuration*'
    }
}