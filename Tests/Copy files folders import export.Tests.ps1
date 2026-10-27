#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Copy files folders import export.ps1" -Name 'Copy files folders'
Describe 'Copy files folders import' {
    BeforeAll { $scriptPath = "$PSScriptRoot\..\Scripts\Copy files folders import export.ps1" }
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
    It 'copies hidden files, names with brackets and subfolders, and keeps other destination files' {
        $null = New-Item -Path $destination -ItemType Directory
        'keep' | Set-Content -LiteralPath (Join-Path $destination 'keep.txt')
        $result = @(& $scriptPath -Action Import -Data @([pscustomobject]@{ From = 'Files\App'; To = $destination }) -RootFolder $root)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        foreach ($name in 'a.txt', 'sub\s.txt', '[b].txt', 'hidden.txt', 'keep.txt') {
            Test-Path -LiteralPath (Join-Path $destination $name) | Should -BeTrue -Because $name
        }
    }
    It 'overwrites a read-only destination file' {
        $null = New-Item -Path $destination -ItemType Directory
        $target = Join-Path $destination 'a.txt'
        'old' | Set-Content -LiteralPath $target
        Set-ItemProperty -LiteralPath $target -Name IsReadOnly -Value $true
        $result = @(& $scriptPath -Action Import -Data @([pscustomobject]@{ From = 'Files\App'; To = $destination }) -RootFolder $root)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Get-Content -LiteralPath $target | Should -Be 'a'
    }
    It 'copies a single file with brackets in its name and creates missing folders' {
        $target = Join-Path $root 'New\Deep\[b].txt'
        $result = @(& $scriptPath -Action Import -Data @([pscustomobject]@{ From = 'Files\App\[b].txt'; To = $target }) -RootFolder $root)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Get-Content -LiteralPath $target | Should -Be 'b'
    }
    It 'copies the other files when one file is locked, and reports the locked file' {
        $null = New-Item -Path $destination -ItemType Directory
        $locked = Join-Path $destination 'a.txt'
        'old' | Set-Content -LiteralPath $locked
        $stream = [IO.File]::Open($locked, 'Open', 'ReadWrite', 'None')
        try {
            $result = @(& $scriptPath -Action Import -Data @([pscustomobject]@{ From = 'Files\App'; To = $destination }) -RootFolder $root)
        }
        finally { $stream.Dispose() }
        $result[0].Errors.Count | Should -Be 1
        $result[0].Errors[0] | Should -BeLike '*1 item(s) could not be copied, the others were copied*'
        Test-Path -LiteralPath (Join-Path $destination 'sub\s.txt') | Should -BeTrue
    }
    It 'reports a missing source and still copies the next entry' {
        $data = @(
            [pscustomobject]@{ From = 'Files\Missing.txt'; To = (Join-Path $root 'x.txt') }
            [pscustomobject]@{ From = 'Files\App'; To = $destination }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $root)
        $result[0].Errors[0] | Should -BeLike "Failed to copy 'Files\Missing.txt'*not found"
        $result[0].Messages | Should -Be @("Copied the contents of folder 'Files\App' to '$destination'")
    }
}