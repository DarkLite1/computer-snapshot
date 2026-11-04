#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath  = "$PSScriptRoot\..\Scripts\" +
        'Hosts file entries import export.ps1'
    Name        = 'Hosts file entries'
    EmptyExport = $true
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Hosts file entries' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'Hosts file entries import export.ps1'
        function Get-HostsFilePathHC {}
    }
    BeforeEach {
        $testHostsFile = Join-Path $TestDrive 'hosts'
        @(
            '# Copyright (c) Microsoft Corp.'
            '#'
            '# 127.0.0.1       localhost'
            ''
            '10.0.0.5    oldserver   belsdaise0001   # moved later'
            '10.0.0.9 keep.contoso.com'
        ) | Set-Content -LiteralPath $testHostsFile -Encoding Ascii
        Remove-Item -LiteralPath "$testHostsFile.bak" -ErrorAction Ignore

        Mock Get-HostsFilePathHC { $testHostsFile }
        Mock Clear-DnsClientCache
    }
    It ('adds names, moves a name that points elsewhere and keeps every ' +
        'other line as it was') {
        $data = @(
            [pscustomobject]@{
                IPAddress = '10.20.60.47'
                Hostnames = @('belsdaise0001', 'belsdaise0001.grouphc.net')
            }
            [pscustomobject]@{
                IPAddress = 'fd00::47'
                Hostnames = @('belsdaise0001-v6')
            }
        )

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = & $scriptPath @testParams

        $result.Errors.Count |
            Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages | Should -Be @(
            ("Host name 'belsdaise0001' pointed to 10.0.0.5; it now points " +
                'to 10.20.60.47')
            "Added host name 'belsdaise0001.grouphc.net' for 10.20.60.47"
            "Added host name 'belsdaise0001-v6' for fd00::47"
        )
        @(Get-Content -LiteralPath $testHostsFile) | Should -Be @(
            '# Copyright (c) Microsoft Corp.'
            '#'
            '# 127.0.0.1       localhost'
            ''
            "10.0.0.5`toldserver # moved later"
            '10.0.0.9 keep.contoso.com'
            "10.20.60.47`tbelsdaise0001 belsdaise0001.grouphc.net"
            "fd00::47`tbelsdaise0001-v6"
        )
        "$testHostsFile.bak" | Should -Exist
        Should -Invoke Clear-DnsClientCache -Times 1 -Exactly
    }
    It ('does not write the file when every name already points to its ' +
        'address') {
        $before = [IO.File]::ReadAllBytes($testHostsFile)
        $data = @(
            [pscustomobject]@{
                IPAddress = '10.0.0.9'
                Hostnames = @('KEEP.contoso.com')
            }
        )

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = & $scriptPath @testParams

        $result.Messages | Should -Be @(
            "Host name 'KEEP.contoso.com' already points to 10.0.0.9"
        )
        [IO.File]::ReadAllBytes($testHostsFile) | Should -Be $before
        "$testHostsFile.bak" | Should -Not -Exist
        Should -Invoke Clear-DnsClientCache -Times 0 -Exactly
    }
    It ('removes names, drops a line without names and reports a name ' +
        'that is not there') {
        $data = @(
            [pscustomobject]@{
                Action    = 'Remove'
                Hostnames = @('keep.contoso.com', 'missing')
            }
        )

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = & $scriptPath @testParams

        $result.Errors.Count |
            Should -Be 0 -Because ($result.Errors -join '; ')
        $result.Messages | Should -Be @(
            ("Removed host name 'keep.contoso.com' (pointed to 10.0.0.9) " +
                'from the hosts file')
            "Host name 'missing' is not in the hosts file, nothing to remove"
        )
        Get-Content -LiteralPath $testHostsFile |
            Should -Not -Contain '10.0.0.9 keep.contoso.com'
        @(Get-Content -LiteralPath $testHostsFile).Count | Should -Be 5
    }
    It 'reports an invalid entry and still applies the others' {
        $data = @(
            [pscustomobject]@{
                IPAddress = '10.0.0.300'; Hostnames = @('bad')
            }
            [pscustomobject]@{
                IPAddress = '10.20.60.47'; Hostnames = @('good')
            }
        )

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = & $scriptPath @testParams

        $result.Errors | Should -Be @(
            ("Failed to apply hosts file entry '10.0.0.300': '10.0.0.300' " +
                'is not an IPv4 or IPv6 address')
        )
        Get-Content -LiteralPath $testHostsFile |
            Should -Contain "10.20.60.47`tgood"
    }
    It 'keeps the previous content as hosts.bak after a change' {
        $before = [IO.File]::ReadAllBytes($testHostsFile)
        $data = @(
            [pscustomobject]@{
                IPAddress = '10.20.60.47'
                Hostnames = @('new')
            }
        )

        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }
        $result = & $scriptPath @testParams

        $result.Errors.Count |
            Should -Be 0 -Because ($result.Errors -join '; ')
        [IO.File]::ReadAllBytes("$testHostsFile.bak") | Should -Be $before
    }
    It ('keeps the hosts file and leaves no temporary file when the ' +
        'write fails') {
        $before = [IO.File]::ReadAllBytes($testHostsFile)
        $data = @(
            [pscustomobject]@{
                IPAddress = '10.20.60.47'
                Hostnames = @('new')
            }
        )
        $testParams = @{
            Action     = 'Import'
            Data       = $data
            RootFolder = $TestDrive
        }

        # Others may read the file, but it cannot be replaced
        $stream = [IO.File]::Open($testHostsFile, 'Open', 'Read', 'Read')
        try {
            $result = & $scriptPath @testParams
        }
        finally {
            $stream.Dispose()
        }

        $result.Errors.Count | Should -Be 1
        $result.Errors[0] |
            Should -BeLike "Failed to write the hosts file '$testHostsFile':*"
        [IO.File]::ReadAllBytes($testHostsFile) | Should -Be $before
        "$testHostsFile.computer-snapshot.tmp" | Should -Not -Exist
        Should -Invoke Clear-DnsClientCache -Times 0 -Exactly
    }
    It 'exports every active line, one entry per address' {
        Add-Content -LiteralPath $testHostsFile -Value '10.0.0.5 another'

        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        $result.Errors.Count | Should -Be 0
        $result.Data.Count | Should -Be 2
        $result.Data[0].IPAddress | Should -Be '10.0.0.5'
        $result.Data[0].Hostnames |
            Should -Be @('oldserver', 'belsdaise0001', 'another')
        $result.Data[1].Hostnames | Should -Be @('keep.contoso.com')
    }
}