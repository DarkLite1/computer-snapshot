#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Folders import export.ps1" -Name 'Folders'
Describe 'Folders import' {
    BeforeAll { $scriptPath = "$PSScriptRoot\..\Scripts\Folders import export.ps1" }
    It 'creates folders with characters the old path check rejected' {
        $paths = @(
            (Join-Path $TestDrive 'Program Files (x86)\Vendor\Logs')
            (Join-Path $TestDrive 'R&D')
            (Join-Path $TestDrive "Caf$([char]0xE9)")
        )
        $result = @(& $scriptPath -Action Import -Data ([pscustomobject]@{ FolderPaths = $paths }) -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        foreach ($path in $paths) { $path | Should -Exist }
    }
    It 'reports an existing folder as a message' {
        $path = Join-Path $TestDrive 'Existing'
        $null = New-Item -Path $path -ItemType Directory
        $result = @(& $scriptPath -Action Import -Data ([pscustomobject]@{ FolderPaths = @($path) }) -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Folder '$path' already exists")
    }
    It 'reports invalid paths and still creates the other folders' {
        $good = Join-Path $TestDrive 'Good'
        $data = [pscustomobject]@{ FolderPaths = @('relative\folder', (Join-Path $TestDrive 'bad?name'), $good, '') }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 3
        $result[0].Errors[0] | Should -BeLike "Failed to create folder 'relative\folder': not a full path*"
        $result[0].Errors[1] | Should -BeLike '*cannot contain*'
        $result[0].Errors[2] | Should -BeLike "Failed to create folder '': the path is empty"
        $result[0].Messages | Should -Be @("Created folder '$good'")
        $good | Should -Exist
        'relative' | Should -Not -Exist
    }
}