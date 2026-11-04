#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Scripts\Copy files folders import export.ps1"
    Name       = 'Copy files folders'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Copy files folders import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'Copy files folders import export.ps1'
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'Files\App'
        $destination = Join-Path $root 'Destination\App'
        $null = New-Item -Path (Join-Path $source 'sub') -ItemType Directory
        'a' | Set-Content -LiteralPath (Join-Path $source 'a.txt')
        's' | Set-Content -LiteralPath (Join-Path $source 'sub\s.txt')
        'b' | Set-Content -LiteralPath (Join-Path $source '[b].txt')
        $hidden = Join-Path $source 'hidden.txt'
        'h' | Set-Content -LiteralPath $hidden
        (Get-Item -LiteralPath $hidden).Attributes = 'Hidden'
    }
    It ('copies hidden files, names with brackets and subfolders, and ' +
        'keeps other destination files') {
        $null = New-Item -Path $destination -ItemType Directory
        'keep' | Set-Content -LiteralPath (Join-Path $destination 'keep.txt')

        $data = @([pscustomobject]@{ From = 'Files\App'; To = $destination })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $root)

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        foreach (
            $name in 'a.txt', 'sub\s.txt', '[b].txt', 'hidden.txt', 'keep.txt'
        ) {
            Test-Path -LiteralPath (Join-Path $destination $name) |
                Should -BeTrue -Because $name
        }
    }
    It 'overwrites a read-only destination file' {
        $null = New-Item -Path $destination -ItemType Directory
        $target = Join-Path $destination 'a.txt'
        'old' | Set-Content -LiteralPath $target
        Set-ItemProperty -LiteralPath $target -Name IsReadOnly -Value $true

        $data = @([pscustomobject]@{ From = 'Files\App'; To = $destination })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $root)

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Get-Content -LiteralPath $target | Should -Be 'a'
    }
    It ('copies a single file with brackets in its name and creates ' +
        'missing folders') {
        $target = Join-Path $root 'New\Deep\[b].txt'

        $data = @(
            [pscustomobject]@{ From = 'Files\App\[b].txt'; To = $target }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $root)

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Get-Content -LiteralPath $target | Should -Be 'b'
    }
    It ('copies the other files when one file is locked, and reports the ' +
        'locked file') {
        $null = New-Item -Path $destination -ItemType Directory
        $locked = Join-Path $destination 'a.txt'
        'old' | Set-Content -LiteralPath $locked

        $data = @([pscustomobject]@{ From = 'Files\App'; To = $destination })
        $stream = [IO.File]::Open($locked, 'Open', 'ReadWrite', 'None')
        try {
            $result = @(
                & $scriptPath -Action Import -Data $data -RootFolder $root
            )
        }
        finally { $stream.Dispose() }

        $result[0].Errors.Count | Should -Be 1
        $result[0].Errors[0] | Should -BeLike (
            '*1 item(s) could not be copied, the others were copied*'
        )
        Test-Path -LiteralPath (Join-Path $destination 'sub\s.txt') |
            Should -BeTrue
    }
    It 'reports a missing source and still copies the next entry' {
        $data = @(
            [pscustomobject]@{
                From = 'Files\Missing.txt'
                To   = (Join-Path $root 'x.txt')
            }
            [pscustomobject]@{ From = 'Files\App'; To = $destination }
        )

        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $root)

        $result[0].Errors[0] |
            Should -BeLike "Failed to copy 'Files\Missing.txt'*not found"
        $result[0].Messages | Should -Be @(
            "Copied the contents of folder 'Files\App' to '$destination'"
        )
    }
    It 'expands environment variables in the destination' {
        $env:COMPUTER_SNAPSHOT_TEST = $root
        try {
            $data = @(
                [pscustomobject]@{
                    From = 'Files\App'
                    To   = '%COMPUTER_SNAPSHOT_TEST%\Expanded'
                }
            )
            $result = @(
                & $scriptPath -Action Import -Data $data -RootFolder $root
            )
        }
        finally { Remove-Item Env:\COMPUTER_SNAPSHOT_TEST }

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        Join-Path $root 'Expanded\a.txt' | Should -Exist
    }
}

Describe 'Copy a file with its placeholders filled in' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'Copy files folders import export.ps1'
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path $root 'Files') -ItemType Directory
        $template = Join-Path $root 'Files\Start terminal.ps1'
        $placeholder = '{{ipv4:IP address of the terminal server}}'
        # An en dash, as in the real kiosk script
        $line = ("`$ArgumentList = '--kiosk http://${placeholder}:1353" +
            "/terminal/ $([char]0x2013)overscroll'")
        [IO.File]::WriteAllText(
            $template, $line, (New-Object System.Text.UTF8Encoding $true)
        )
        $target = Join-Path $root 'Out\Start terminal.ps1'
        $entry = [pscustomobject]@{
            From              = 'Files\Start terminal.ps1'
            To                = $target
            FillPlaceholders  = $true
            PlaceholderValues = @{ $placeholder = '10.20.60.47' }
        }
    }
    It ('writes the answer in the middle of a line, keeps the encoding and ' +
        'leaves the template alone') {
        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @(
            ("Copied file 'Files\Start terminal.ps1' with 1 placeholder(s) " +
                "filled in to '$target'")
        )
        $bytes = [IO.File]::ReadAllBytes($target)
        @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        [IO.File]::ReadAllText($target) | Should -BeExactly (
            "`$ArgumentList = '--kiosk http://10.20.60.47:1353/terminal/ " +
            "$([char]0x2013)overscroll'"
        )
        [IO.File]::ReadAllText($template) |
            Should -Match ([regex]::Escape($placeholder))
    }
    It 'keeps a file in the Windows code page in that code page' {
        $codePage = [Text.Encoding]::GetEncoding(
            [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        )
        [IO.File]::WriteAllText(
            $template, "# caf$([char]0xE9)`r`n$placeholder", $codePage
        )

        $null = & $scriptPath -Action Import -Data @($entry) -RootFolder $root

        [IO.File]::ReadAllBytes($target) | Should -Be (
            $codePage.GetBytes("# caf$([char]0xE9)`r`n10.20.60.47")
        )
    }
    It ('overwrites a read-only copy and reports a placeholder without an ' +
        'answer') {
        $null = & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        Set-ItemProperty -LiteralPath $target -Name IsReadOnly -Value $true

        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')

        $entry.PlaceholderValues = @{}
        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors | Should -Be @(
            ("Failed to copy 'Files\Start terminal.ps1' to '$target': " +
                "no answer for the placeholder(s) $placeholder")
        )
    }
    It ('writes into an existing destination folder under the source ' +
        'file name, also over a read-only file') {
        $folder = Join-Path $root 'Out'
        $null = New-Item -Path $folder -ItemType Directory
        $entry.To = $folder
        $expected = Join-Path $folder 'Start terminal.ps1'

        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @(
            ("Copied file 'Files\Start terminal.ps1' with 1 placeholder(s) " +
                "filled in to '$expected'")
        )
        [IO.File]::ReadAllText($expected) | Should -Match '10\.20\.60\.47'

        Set-ItemProperty -LiteralPath $expected -Name IsReadOnly -Value $true
        $entry.PlaceholderValues[$placeholder] = '10.20.60.48'

        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        [IO.File]::ReadAllText($expected) | Should -Match '10\.20\.60\.48'
    }
    It 'refuses FillPlaceholders for a folder' {
        $entry.From = 'Files'

        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors[0] | Should -BeLike (
            '*FillPlaceholders only works for a file, not for a folder'
        )
    }
    It 'fills in a number placeholder as text' {
        $number = '{{number:Seconds to wait}}'
        [IO.File]::WriteAllText(
            $template,
            "Start-Sleep -Seconds $number # $placeholder",
            (New-Object System.Text.UTF8Encoding $false)
        )
        $entry.PlaceholderValues[$number] = '30'

        $result = @(
            & $scriptPath -Action Import -Data @($entry) -RootFolder $root
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages[0] | Should -BeLike '*with 2 placeholder(s)*'
        [IO.File]::ReadAllText($target) |
            Should -BeExactly 'Start-Sleep -Seconds 30 # 10.20.60.47'
    }
}