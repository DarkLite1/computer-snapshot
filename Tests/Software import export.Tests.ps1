#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Software import export.ps1" -Name 'Software'
Describe 'Software import' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        function Get-InstalledApplicationsHC { }
        function Remove-ApplicationHC { param($ApplicationName, $UninstallString, $TimeoutSeconds, [switch]$WaitForAllProcesses) }
        function Wait-ProcessTreeHC { param($Process, $TimeoutSeconds, $What, [switch]$WaitForAllProcesses) }
        function New-FakeProcessResultHC {
            param([int]$ExitCode, [string[]]$LeftRunning = @())
            [pscustomobject]@{ ExitCode = $ExitCode; LeftRunning = $LeftRunning }
        }
    }
    BeforeEach {
        Mock Start-Sleep
        Mock Wait-ProcessTreeHC { New-FakeProcessResultHC -ExitCode $Process.ExitCode }
        $fakeInstalledApplications = [System.Collections.Generic.List[string]]@('Old App', 'Stuck App', 'Msi App')
        Mock Get-InstalledApplicationsHC {
            foreach ($name in $fakeInstalledApplications) {
                [pscustomobject]@{ DisplayName = $name; UninstallString = if ($name -eq 'Msi App') { 'MsiExec.exe /I{AAAA}' } else { "C:\$name\uninstall.exe" } }
            }
        }
        Mock Remove-ApplicationHC { if ($ApplicationName -ne 'Stuck App') { $null = $fakeInstalledApplications.Remove($ApplicationName) }; New-FakeProcessResultHC 0 }
        Mock Remove-ApplicationHC { New-FakeProcessResultHC 3010 } -ParameterFilter { $ApplicationName -eq 'Msi App' }
        Mock Test-Path { $true }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } } -ParameterFilter { $FilePath -like '*reboot.exe' }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1603 } } -ParameterFilter { $FilePath -like '*fail.exe' }
    }
    It 'reports a failed removal and still removes and installs the rest' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Stuck App' }, [pscustomobject]@{ DisplayName = 'Old App' }); Install = @([pscustomobject]@{ ExecutablePath = 'Software\ok.exe'; Arguments = '/S' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to remove application 'Stuck App': the application is still installed 60 seconds after the uninstall (exit code 0)")
        $result[0].Messages | Should -Be @("Removed application 'Old App'", "Installed 'Software\ok.exe' with arguments '/S'")
    }
    It 'makes a Windows Installer uninstall silent and uses /X' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Msi App' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'MsiExec.exe /X{AAAA} /qn /norestart' }
        $result[0].Messages | Should -Be @("Removed application 'Msi App', a restart is needed to complete the removal")
    }
    It 'treats exit code 3010 as success that needs a restart and reports other exit codes' {
        $data = [pscustomobject]@{ Install = @(
                [pscustomobject]@{ ExecutablePath = 'Software\reboot.exe' }
                [pscustomobject]@{ ExecutablePath = 'Software\fail.exe' }
                [pscustomobject]@{ ExecutablePath = 'Software\ok.exe' }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Installed 'Software\reboot.exe', a restart is needed to complete the installation", "Installed 'Software\ok.exe'")
        $result[0].Errors | Should -Be @("Failed to install 'Software\fail.exe': the installation failed with exit code 1603, success exit codes are 0")
    }
    It 'reports a missing installer with its full path' {
        Mock Test-Path { $false }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\missing.exe' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors[0] | Should -BeLike "Failed to install 'Software\missing.exe': the file '*\Software\missing.exe' does not exist"
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'reports an application that is not installed as nothing to remove' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Not There' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Application 'Not There' is not installed, nothing to remove")
        Should -Invoke Remove-ApplicationHC -Times 0 -Exactly
    }
    It 'restores the working folder' {
        $before = (Get-Location).Path
        $null = & $scriptPath -Action Import -Data ([pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\fail.exe' }) }) -RootFolder $TestDrive
        (Get-Location).Path | Should -Be $before
    }
    It 'accepts the exit codes listed in SuccessExitCodes and shows them' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } } -ParameterFilter { $FilePath -like '*vendor.exe' }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\vendor.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Installed 'Software\vendor.exe' (exit code 1)")
    }
    It 'still treats 3010 as success with a restart when SuccessExitCodes is set' {
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\reboot.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Installed 'Software\reboot.exe', a restart is needed to complete the installation")
    }
    It 'reports an exit code that is not listed' {
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\fail.exe'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to install 'Software\fail.exe': the installation failed with exit code 1603, success exit codes are 0, 1")
    }
    It 'gives uninstallers and installers TimeoutMinutes, by default 15' {
        $data = [pscustomobject]@{
            Remove  = @([pscustomobject]@{ DisplayName = 'Old App'; TimeoutMinutes = 5 }, [pscustomobject]@{ DisplayName = 'Msi App' })
            Install = @([pscustomobject]@{ ExecutablePath = 'Software\ok.exe'; TimeoutMinutes = 60 }, [pscustomobject]@{ ExecutablePath = 'Software\reboot.exe' })
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $ApplicationName -eq 'Old App' -and $TimeoutSeconds -eq 300 }
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $ApplicationName -eq 'Msi App' -and $TimeoutSeconds -eq 900 }
        Should -Invoke Wait-ProcessTreeHC -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 3600 -and $What -eq 'the installation' }
        Should -Invoke Wait-ProcessTreeHC -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 900 }
    }
    It 'reports an installer that runs too long' {
        Mock Wait-ProcessTreeHC { throw 'the installation did not finish within 15 minute(s) and was stopped' }
        $data = [pscustomobject]@{ Install = @([pscustomobject]@{ ExecutablePath = 'Software\ok.exe' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to install 'Software\ok.exe': the installation did not finish within 15 minute(s) and was stopped")
    }
    It 'waits for an application that disappears shortly after its uninstaller ends' {
        $checksAfterRemoval = [ref]0
        Mock Remove-ApplicationHC { New-FakeProcessResultHC 0 } -ParameterFilter { $ApplicationName -eq 'Old App' }
        Mock Get-InstalledApplicationsHC {
            $names = @($fakeInstalledApplications)
            if ((Get-PSCallStack).Command -contains 'Wait-ApplicationRemovedHC') {
                $checksAfterRemoval.Value++
                if ($checksAfterRemoval.Value -ge 3) { $names = @($names | Where-Object { $_ -ne 'Old App' }) }
            }
            foreach ($name in $names) { [pscustomobject]@{ DisplayName = $name; UninstallString = "C:\$name\uninstall.exe" } }
        }
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Old App' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Old App'")
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }
    It 'names the processes an installer or uninstaller left running, as a message' {
        Mock Wait-ProcessTreeHC {
            New-FakeProcessResultHC -ExitCode 0 -LeftRunning 'XApp.exe'
        }
        Mock Wait-ProcessTreeHC {
            New-FakeProcessResultHC -ExitCode 3010 `
                -LeftRunning 'Tray.exe', 'Updater.exe'
        } -ParameterFilter { $Process.ExitCode -eq 3010 }
        Mock Remove-ApplicationHC {
            $null = $fakeInstalledApplications.Remove($ApplicationName)
            New-FakeProcessResultHC -ExitCode 0 -LeftRunning 'Feedback.exe'
        } -ParameterFilter { $ApplicationName -eq 'Old App' }
        $data = [pscustomobject]@{
            Remove  = @([pscustomobject]@{ DisplayName = 'Old App' })
            Install = @(
                [pscustomobject]@{ ExecutablePath = 'Software\X.exe' }
                [pscustomobject]@{ ExecutablePath = 'Software\reboot.exe' }
            )
        }

        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)

        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @(
            "Removed application 'Old App'; 'Feedback.exe' started by the uninstaller is still running and was left alone"
            "Installed 'Software\X.exe'; 'XApp.exe' started by the installer is still running and was left alone"
            "Installed 'Software\reboot.exe', a restart is needed to complete the installation; 'Tray.exe', 'Updater.exe' started by the installer are still running and were left alone"
        )
    }
    It 'passes WaitForAllProcesses of Install and Remove entries, by default false' {
        $data = [pscustomobject]@{
            Remove  = @(
                [pscustomobject]@{ DisplayName = 'Old App'; WaitForAllProcesses = $true }
                [pscustomobject]@{ DisplayName = 'Msi App' }
            )
            Install = @(
                [pscustomobject]@{ ExecutablePath = 'Software\ok.exe'; WaitForAllProcesses = $true }
                [pscustomobject]@{ ExecutablePath = 'Software\reboot.exe' }
            )
        }

        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)

        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter {
            $ApplicationName -eq 'Old App' -and $WaitForAllProcesses
        }
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter {
            $ApplicationName -eq 'Msi App' -and -not $WaitForAllProcesses
        }
        Should -Invoke Wait-ProcessTreeHC -Times 1 -Exactly -ParameterFilter {
            $Process.ExitCode -eq 0 -and $WaitForAllProcesses
        }
        Should -Invoke Wait-ProcessTreeHC -Times 1 -Exactly -ParameterFilter {
            $Process.ExitCode -eq 3010 -and -not $WaitForAllProcesses
        }
    }
}


Describe 'Software removal by pattern' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        function Get-InstalledApplicationsHC { }
        function Remove-ApplicationHC { param($ApplicationName, $UninstallString, $TimeoutSeconds, [switch]$WaitForAllProcesses) }
        function New-FakeProcessResultHC {
            param([int]$ExitCode, [string[]]$LeftRunning = @())
            [pscustomobject]@{ ExitCode = $ExitCode; LeftRunning = $LeftRunning }
        }
    }
    BeforeEach {
        Mock Start-Sleep
        $fakeApplications = [System.Collections.Generic.List[object]]::new()
        foreach ($fake in @(
                , @('Vendor Tool 1.0', 'C:\Tool1\uninst.exe', $null)
                , @('Vendor Tool 2.0', 'C:\Tool2\uninst.exe', 'C:\Tool2\uninst.exe /quiet')
                , @('Twice', 'C:\Twice64\uninst.exe', $null)
                , @('Twice', 'C:\Twice32\uninst.exe', $null)
                , @('App [x64]', 'C:\Bracket\uninst.exe', $null)
                , @('App 1', 'C:\App1\uninst.exe', $null)
            )) {
            $fakeApplications.Add([pscustomobject]@{ DisplayName = $fake[0]; UninstallString = $fake[1]; QuietUninstallString = $fake[2]; User = $null })
        }
        Mock Get-InstalledApplicationsHC { $fakeApplications.ToArray() }
        Mock Remove-ApplicationHC {
            foreach ($fake in @($fakeApplications | Where-Object { $UninstallString -like "$($_.UninstallString)*" -or $UninstallString -like '*custom.exe*' })) {
                $null = $fakeApplications.Remove($fake)
            }
            New-FakeProcessResultHC 0
        }
    }
    It 'removes every application that matches *, each with its own command' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'vendor tool*' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Vendor Tool 1.0'", "Removed application 'Vendor Tool 2.0'")
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool1\uninst.exe' }
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool2\uninst.exe /quiet' }
    }
    It 'removes both applications with the same name and treats brackets literally' {
        $data = [pscustomobject]@{ Remove = @(
                [pscustomobject]@{ DisplayName = 'Twice' }
                [pscustomobject]@{ DisplayName = 'App [x64]' }
            )
        }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Twice'", "Removed application 'Twice'", "Removed application 'App [x64]'")
        @($fakeApplications.DisplayName) | Should -Be @('Vendor Tool 1.0', 'Vendor Tool 2.0', 'App 1')
    }
    It 'adds UninstallArguments to the uninstall string, not the quiet command' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Vendor Tool 2.0'; UninstallArguments = '/S' }) }
        $null = & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\Tool2\uninst.exe /S' }
    }
    It 'runs UninstallCommand once for all matches and accepts its SuccessExitCodes' {
        Mock Remove-ApplicationHC {
            foreach ($fake in @($fakeApplications | Where-Object { $_.DisplayName -like 'Vendor Tool*' })) { $null = $fakeApplications.Remove($fake) }
            New-FakeProcessResultHC 1
        }
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Vendor Tool*'; UninstallCommand = 'C:\custom.exe /all'; SuccessExitCodes = @(0, 1) }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Vendor Tool 1.0', 'Vendor Tool 2.0'")
        Should -Invoke Remove-ApplicationHC -Times 1 -Exactly -ParameterFilter { $UninstallString -eq 'C:\custom.exe /all' }
    }
    It 'names the user of a per-user installation' {
        $fakeApplications.Add([pscustomobject]@{ DisplayName = 'Zoom'; UninstallString = 'C:\Users\kiosk\Zoom\uninst.exe'; QuietUninstallString = $null; User = 'PC1\kiosk' })
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = 'Zoom' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Removed application 'Zoom' for user 'PC1\kiosk'")
    }
    It 'refuses a pattern that matches more than 5 applications unless AllowMultiple is set' {
        $data = [pscustomobject]@{ Remove = @([pscustomobject]@{ DisplayName = '*' }) }
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to remove application '*': '*' matches 6 applications; nothing was removed. Use a narrower DisplayName, or set AllowMultiple to remove them all")
        Should -Invoke Remove-ApplicationHC -Times 0 -Exactly
        $data.Remove[0] | Add-Member -NotePropertyName AllowMultiple -NotePropertyValue $true
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $fakeApplications.Count | Should -Be 0
    }
}

Describe 'Waiting for installers and uninstallers' {
    BeforeAll {
        . "$PSScriptRoot\..\Scripts\Software import export.ps1" -Action Export -RootFolder $TestDrive | Out-Null
        $cmd = "$env:SystemRoot\System32\cmd.exe"
    }
    It 'returns the exit code of the process' {
        $process = Start-Process -FilePath $cmd -ArgumentList '/D /C exit 7' -WindowStyle Hidden -PassThru
        (Wait-ProcessTreeHC -Process $process -TimeoutSeconds 30 -What 'the test').ExitCode | Should -Be 7
    }
    It 'also waits for a process the command started and did not wait for' {
        $marker = Join-Path $TestDrive 'child.txt'
        $child = Join-Path $TestDrive 'child.cmd'
        # start runs a batch file with cmd /K, so the batch file ends with exit
        "@ping -n 3 127.0.0.1 >nul`r`n@echo done>`"$marker`"`r`n@exit`r`n" | Set-Content -LiteralPath $child -Encoding Ascii
        $process = Start-Process -FilePath $cmd -ArgumentList "/D /C start `"`" /B `"$child`"" -WindowStyle Hidden -PassThru
        $null = Wait-ProcessTreeHC -Process $process -TimeoutSeconds 30 -What 'the test'
        $marker | Should -Exist
    }
    It 'stops the process and the processes it started after the time limit' {
        $process = Start-Process -FilePath $cmd -ArgumentList '/D /C ping -n 30 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
        { Wait-ProcessTreeHC -Process $process -TimeoutSeconds 1 -What 'the test' } |
            Should -Throw 'the test did not finish within 0.02 minute(s) and was stopped'
        $process.WaitForExit(5000) | Should -BeTrue
        @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($process.Id)" |
            Where-Object { $_.Name -eq 'PING.EXE' -or $_.Name -eq 'ping.exe' }).Count | Should -Be 0
    }
    Context 'process IDs that Windows reused' {
        BeforeEach {
            $fakeMarker = "fake-reuse-$([guid]::NewGuid().ToString('N'))"
            $startFake = {
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
                    -PassThru -ArgumentList '-NoProfile', '-NonInteractive',
                '-Command', "Start-Sleep -Seconds 120 # $fakeMarker"
            }
            $fakeTreeChild = & $startFake
            $fakeUnrelated = & $startFake
            $fakeTreeChildCreated = (
                Get-CimInstance -ClassName Win32_Process `
                    -Filter "ProcessId = $($fakeTreeChild.Id)"
            ).CreationDate
            $fakeUnrelatedCreated = (
                Get-CimInstance -ClassName Win32_Process `
                    -Filter "ProcessId = $($fakeUnrelated.Id)"
            ).CreationDate
            # An installer that is not a real process; its ID is never used
            $fakeInstaller = [pscustomobject]@{
                Id        = 2147480000
                StartTime = (Get-Date).AddHours(-2)
                HasExited = $false
                Handle    = [IntPtr]::Zero
                ExitCode  = 0
            } | Add-Member -MemberType ScriptMethod -Name WaitForExit `
                -Value { } -PassThru
        }
        AfterEach {
            foreach ($fake in @($fakeTreeChild, $fakeUnrelated)) {
                if (-not $fake.HasExited) {
                    $fake.Kill()
                }
                $fake.Dispose()
            }
        }
        It 'never stops a process that got the ID of a process in the tree' {
            # The tree had a child with the ID of the unrelated process, but
            # it started earlier; the unrelated process got its ID later
            Mock Get-CimInstance {
                [pscustomobject]@{
                    ProcessId       = $fakeInstaller.Id
                    ParentProcessId = 4
                    CreationDate    = $fakeInstaller.StartTime
                    Name            = 'setup.exe'
                }
                [pscustomobject]@{
                    ProcessId       = $fakeTreeChild.Id
                    ParentProcessId = $fakeInstaller.Id
                    CreationDate    = $fakeTreeChildCreated
                    Name            = 'powershell.exe'
                }
                [pscustomobject]@{
                    ProcessId       = $fakeUnrelated.Id
                    ParentProcessId = $fakeInstaller.Id
                    CreationDate    = $fakeUnrelatedCreated.AddMinutes(-30)
                    Name            = 'powershell.exe'
                }
            } -ParameterFilter { $ClassName -eq 'Win32_Process' -and -not $Filter }

            {
                Wait-ProcessTreeHC -Process $fakeInstaller -TimeoutSeconds 0 `
                    -What 'the test'
            } | Should -Throw 'the test did not finish within 0 minute(s) and was stopped'

            $fakeTreeChild.WaitForExit(5000) | Should -BeTrue
            $fakeUnrelated.HasExited | Should -BeFalse
        }
        It 'does not count a process that got the ID of an exited child' {
            $fakeInstaller.HasExited = $true
            $script:fakeListings = 0
            Mock Get-CimInstance {
                $script:fakeListings++
                if ($script:fakeListings -eq 1) {
                    # First seen as a child of the installer
                    [pscustomobject]@{
                        ProcessId       = $fakeUnrelated.Id
                        ParentProcessId = $fakeInstaller.Id
                        CreationDate    = $fakeUnrelatedCreated.AddMinutes(-30)
                        Name            = 'child.exe'
                    }
                }
                else {
                    # That child exited; its ID now belongs to another process
                    [pscustomobject]@{
                        ProcessId       = $fakeUnrelated.Id
                        ParentProcessId = 4
                        CreationDate    = $fakeUnrelatedCreated
                        Name            = 'powershell.exe'
                    }
                }
            } -ParameterFilter { $ClassName -eq 'Win32_Process' -and -not $Filter }

            $result = Wait-ProcessTreeHC -Process $fakeInstaller `
                -TimeoutSeconds 60 -What 'the test' -GraceSeconds 30

            $script:fakeListings | Should -BeGreaterOrEqual 2
            $result.ExitCode | Should -Be 0
            $result.LeftRunning | Should -BeNullOrEmpty
            $fakeUnrelated.HasExited | Should -BeFalse
        }
    }
    Context 'an installer that starts a long-running application' {
        BeforeEach {
            # Unique, so cleanup only stops the processes of this test
            $fakeMarker = "fake-app-$([guid]::NewGuid().ToString('N'))"
            $fakeInstaller = Join-Path $TestDrive "$fakeMarker setup.cmd"
            @(
                '@echo off'
                "start `"`" /B powershell.exe -NoProfile -NonInteractive -Command `"Start-Sleep -Seconds 600 # $fakeMarker`""
                # Like a real installer, run long enough to be seen
                'ping -n 2 127.0.0.1 >nul'
                'exit /b 0'
            ) | Set-Content -LiteralPath $fakeInstaller -Encoding Ascii
            $getFakeApplication = {
                @(
                    Get-CimInstance -ClassName Win32_Process `
                        -Filter "Name = 'powershell.exe'" |
                    Where-Object { $_.CommandLine -like "*$fakeMarker*" }
                )
            }
            Mock Get-GraceSecondsHC { 2 }
        }
        AfterEach {
            foreach ($fake in @(& $getFakeApplication)) {
                Stop-Process -Id $fake.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        It 'reports it installed after the grace period and leaves the application running' {
            $data = [pscustomobject]@{
                Install = @([pscustomobject]@{ ExecutablePath = $fakeInstaller })
            }
            $timer = [Diagnostics.Stopwatch]::StartNew()

            $result = @(
                & "$PSScriptRoot\..\Scripts\Software import export.ps1" `
                    -Action Import -Data $data -RootFolder $TestDrive
            )

            $timer.Elapsed.TotalSeconds | Should -BeLessThan 30
            $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
            $result[0].Messages | Should -Be @(
                "Installed '$fakeInstaller'; 'powershell.exe' started by the installer is still running and was left alone"
            )
            @(& $getFakeApplication).Count | Should -Be 1
        }
        It 'times out and stops the application with WaitForAllProcesses' {
            Mock Get-TimeoutSecondsHC { 3 }
            $data = [pscustomobject]@{
                Install = @(
                    [pscustomobject]@{
                        ExecutablePath      = $fakeInstaller
                        WaitForAllProcesses = $true
                    }
                )
            }

            $result = @(
                & "$PSScriptRoot\..\Scripts\Software import export.ps1" `
                    -Action Import -Data $data -RootFolder $TestDrive
            )

            $result[0].Errors | Should -Be @(
                "Failed to install '$fakeInstaller': the installation did not finish within 0.05 minute(s) and was stopped"
            )
            Start-Sleep -Seconds 1
            @(& $getFakeApplication).Count | Should -Be 0
        }
        It 'leaves the application of an uninstaller started through cmd.exe running' {
            $uninstaller = "`"$cmd`" /D /C `"$fakeInstaller`""
            $timer = [Diagnostics.Stopwatch]::StartNew()

            $uninstall = Remove-ApplicationHC -ApplicationName 'Fake' `
                -UninstallString $uninstaller -TimeoutSeconds 60

            $timer.Elapsed.TotalSeconds | Should -BeLessThan 30
            $uninstall.ExitCode | Should -Be 0
            $uninstall.LeftRunning | Should -Be @('powershell.exe')
            @(& $getFakeApplication).Count | Should -Be 1
        }
    }
}

Describe 'Installed applications lookup' {
    BeforeEach {
        Mock Get-ChildItem { } -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS' }
    }
    It 'also lists the applications of signed-in users, by account' {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        Mock Get-ChildItem {
            foreach ($name in @('.DEFAULT', 'S-1-5-18', 'S-1-5-21-1-2-3-1001', 'S-1-5-21-1-2-3-1001_Classes')) { [pscustomobject]@{ PSChildName = $name } }
        } -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS' }
        Mock Get-ItemProperty { } -ParameterFilter { $Path -like 'HKLM:*' }
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Zoom'; UninstallString = 'x' } } -ParameterFilter { $Path -like 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\*' }
        . $scriptPath -Action Export -RootFolder $TestDrive | Out-Null
        $applications = @(Get-InstalledApplicationsHC)
        $applications.Count | Should -Be 1
        $applications[0].DisplayName | Should -Be 'Zoom'
        $applications[0].User | Should -Be 'S-1-5-21-1-2-3-1001'
        Should -Invoke Get-ItemProperty -Times 3 -Exactly
    }
    It 'handles exactly one 32-bit application next to 64-bit applications' {
        $scriptPath = "$PSScriptRoot\..\Scripts\Software import export.ps1"
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'One32'; UninstallString = 'x' } } -ParameterFilter { $Path -like '*Wow6432Node*' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ DisplayName = 'A64'; UninstallString = 'x' }
            [pscustomobject]@{ DisplayName = 'B64'; UninstallString = 'x' }
        } -ParameterFilter { $Path -notlike '*Wow6432Node*' }
        . $scriptPath -Action Export -RootFolder $TestDrive | Out-Null
        @(Get-InstalledApplicationsHC).DisplayName | Should -Be @('A64', 'B64', 'One32')
    }
}