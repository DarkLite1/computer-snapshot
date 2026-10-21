#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $scriptPath = "$PSScriptRoot\..\Scripts\Regional settings new accounts.ps1"
}

Describe 'Regional settings resource cleanup' {
    BeforeEach {
        $savedTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $tempRoot -ItemType Directory
        $env:TEMP = $tempRoot
        $importedContents = New-Object 'System.Collections.Generic.List[string]'
        $mountCommands = New-Object 'System.Collections.Generic.List[string]'
        Mock Start-Process {
            if ($FilePath -eq 'regedit.exe' -and $ArgumentList -like '/e *') {
                $null = ($ArgumentList -join ' ') -match '^/e "([^"]+)" "([^"]+)"$'
                [IO.File]::WriteAllLines($Matches[1], @(
                    'Windows Registry Editor Version 5.00', '', "[$($Matches[2])]",
                    ('"Currency"="' + [char]0x20AC + '"')
                ), [Text.Encoding]::Unicode)
            }
            elseif ($FilePath -eq 'regedit.exe' -and $ArgumentList -like '/s *') {
                $null = ($ArgumentList -join ' ') -match '^/s "([^"]+)"$'
                $bytes = [IO.File]::ReadAllBytes($Matches[1])
                $bytes[0] | Should -Be 255
                $bytes[1] | Should -Be 254
                $importedContents.Add([IO.File]::ReadAllText($Matches[1]))
            }
            elseif ($FilePath -eq 'reg.exe') {
                $mountCommands.Add(($ArgumentList -join ' '))
            }
            [pscustomobject]@{ ExitCode = 0 }
        }
    }
    AfterEach {
        $env:TEMP = $savedTemp
    }
    It 'unloads its own hive and deletes all temporary files on success' {
        $result = & $scriptPath
        $result | Should -Match 'newly created accounts'
        $importedContents.Count | Should -Be 4
        $importedContents[1] | Should -Match 'HKEY_USERS\\ComputerSnapshot_[a-f0-9]{32}'
        foreach ($text in $importedContents) {
            $text | Should -Not -Match 'HKEY_CURRENT_USER'
            $text | Should -Match ([string][char]0x20AC)
            ([regex]::Matches($text, 'Windows Registry Editor Version 5.00')).Count | Should -Be 1
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'reg.exe' -and $ArgumentList -like 'unload "HKEY_USERS\ComputerSnapshot_*"' }
        $null = $mountCommands[0] -match '^load "([^"]+)"'
        $mountCommands[1] | Should -BeExactly ('unload "' + $Matches[1] + '"')
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'uses a distinct hive mount for each invocation' {
        $null = & $scriptPath
        $null = & $scriptPath
        $mountCommands.Count | Should -Be 4
        $mountCommands[0] | Should -Not -Be $mountCommands[2]
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'cleans up files after export fails without attempting to unload an unmounted hive' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 2 } } -ParameterFilter { $ArgumentList -like '/e *' }
        { & $scriptPath } | Should -Throw '*Failed to export*exit code 2*'
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'reg.exe' }
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'does not unload a hive if loading it failed' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } } -ParameterFilter { $ArgumentList -like 'load *' }
        { & $scriptPath } | Should -Throw '*Failed to load*exit code 5*'
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $ArgumentList -like 'unload *' -or $ArgumentList -like '/s *' }
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'unloads the hive and removes files if an import fails' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3 } } -ParameterFilter { $ArgumentList -like '/s *' }
        { & $scriptPath } | Should -Throw '*Failed to import*exit code 3*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -like 'unload *' }
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'cleans up when launching an import process throws' {
        Mock Start-Process { throw 'Process launch failed' } -ParameterFilter { $ArgumentList -like '/s *' }
        { & $scriptPath } | Should -Throw '*Process launch failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -like 'unload *' }
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'still deletes temporary files and reports the hive name if unloading fails' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 6 } } -ParameterFilter { $ArgumentList -like 'unload *' }
        { & $scriptPath } | Should -Throw '*Failed to unload*HKEY_USERS\ComputerSnapshot_*exit code 6*'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'preserves both the original failure and a cleanup failure' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3 } } -ParameterFilter { $ArgumentList -like '/s *' }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 6 } } -ParameterFilter { $ArgumentList -like 'unload *' }
        { & $scriptPath } | Should -Throw '*Failed to import*exit code 3*Failed to unload*exit code 6*'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
    }
    It 'does not remove unrelated files' {
        $sentinel = Join-Path $tempRoot 'existing.reg'
        'Keep' | Set-Content -LiteralPath $sentinel
        $null = & $scriptPath
        Get-Content -LiteralPath $sentinel | Should -Be 'Keep'
        @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 1
    }
    It 'reports file cleanup failures while cleaning the other files' {
        Mock Remove-Item {
            if ([IO.Directory]::Exists($LiteralPath)) { [IO.Directory]::Delete($LiteralPath) }
            else { [IO.File]::Delete($LiteralPath) }
        }
        Mock Remove-Item { throw 'File locked' } -ParameterFilter { $LiteralPath -like '*\target-0.reg' }
        { & $scriptPath } | Should -Throw '*Failed to remove temporary file*File locked*'
        @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File).Name | Should -Be @('target-0.reg')
    }
}
