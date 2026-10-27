#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Software as a configuration section.
.DESCRIPTION
    Import first removes the applications in Remove, by their display name in
    Programs and Features, then runs the installers in Install, relative to
    the USB root unless they are full paths. Each removal and installation is
    handled independently: a failure is reported in Errors and the remaining
    ones still run.

    - Removal uses the application's quiet uninstall command when it has one.
      Windows Installer (MsiExec) commands are made silent and always uninstall
      (/X); other uninstallers without a quiet command may show a window.
    - Exit codes 0, 3010 and 1641 mean success; 3010 and 1641 mean that a
      restart is needed to complete the change.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
function Get-InstalledApplicationsHC {
    # Unreadable uninstall entries are skipped instead of failing the lookup
    $applications = foreach ($path in @(
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, QuietUninstallString
    }
    @($applications) | Sort-Object DisplayName -Unique
}
function Get-UninstallCommandHC {
    param([Parameter(Mandatory)]$Application)
    if ($Application.QuietUninstallString) { return $Application.QuietUninstallString }
    $command = [string]$Application.UninstallString
    if ($command -match '(?i)^\s*"?([^"]*\\)?msiexec(\.exe)?"?\s') {
        # MsiExec /I installs or repairs; /X uninstalls
        $command = $command -replace '(?i)\s/I\s*(\{)', ' /X$1'
        if ($command -notmatch '(?i)\s/q') { $command += ' /qn' }
        if ($command -notmatch '(?i)/norestart') { $command += ' /norestart' }
    }
    $command
}
function Remove-ApplicationHC {
    # Returns the exit code of the uninstall command
    param(
        [Parameter(Mandatory)][String]$ApplicationName,
        [Parameter(Mandatory)][String]$UninstallString
    )
    Write-Verbose "Remove application '$ApplicationName' with '$UninstallString'"
    # Windows PowerShell 5.1 turns output on the error stream of a program
    # into a stopping error when the preference is Stop
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $null = cmd /C $UninstallString 2>&1
    $global:LASTEXITCODE
}
function Get-ExitCodeResultHC {
    # $null for success, 'restart' for success that needs a restart
    param([int]$ExitCode, [string]$What)
    switch ($ExitCode) {
        0 { return $null }
        3010 { return 'restart' }
        1641 { return 'restart' }
        default { throw "$What failed with exit code $ExitCode" }
    }
}
#endregion
$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}

if ($Action -eq 'Export') {
    #region Capture section
    $exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\Software.json"
    #endregion
    $messages = @('Exported Software')
}
else {
    #region Apply section
    $workPath = Get-Location
    # Installer arguments may contain paths relative to the USB root
    Set-Location -LiteralPath $RootFolder
    try {
        #region Remove applications
        foreach ($applicationName in @($Data.Remove | Where-Object { $_ })) {
            try {
                $installed = @(Get-InstalledApplicationsHC | Where-Object { $_.DisplayName -eq $applicationName })
                if (-not $installed.Count) {
                    $messages += "Application '$applicationName' is not installed, nothing to remove"
                    continue
                }
                $command = Get-UninstallCommandHC -Application $installed[0]
                if (-not $command) { throw 'no uninstall command found in the registry' }
                $exitCode = Remove-ApplicationHC -ApplicationName $applicationName -UninstallString $command
                $result = Get-ExitCodeResultHC -ExitCode $exitCode -What 'the uninstall'
                if ($result -ne 'restart' -and @(Get-InstalledApplicationsHC | Where-Object { $_.DisplayName -eq $applicationName }).Count) {
                    throw "the application is still installed after the uninstall (exit code $exitCode)"
                }
                if ($result -eq 'restart') { $messages += "Removed application '$applicationName', a restart is needed to complete the removal" }
                else { $messages += "Removed application '$applicationName'" }
            }
            catch {
                $errors += "Failed to remove application '$applicationName': $($_.Exception.Message)"
            }
        }
        #endregion

        #region Install applications
        foreach ($application in @($Data.Install | Where-Object { $null -ne $_ })) {
            $label = "'$($application.ExecutablePath)'"
            if ($application.Arguments) { $label += " with arguments '$($application.Arguments)'" }
            try {
                if (-not $application.ExecutablePath) { throw "the property 'ExecutablePath' is required" }
                $executablePath = Resolve-RootPathHC -Path $application.ExecutablePath -RootFolder $RootFolder
                if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                    throw "the file '$executablePath' does not exist"
                }
                Write-Verbose "Install executable '$executablePath'"
                $startParams = @{ FilePath = $executablePath; NoNewWindow = $true; Wait = $true; PassThru = $true }
                if ($application.Arguments) { $startParams.ArgumentList = $application.Arguments }
                $process = Start-Process @startParams
                $result = Get-ExitCodeResultHC -ExitCode $process.ExitCode -What 'the installation'
                if ($result -eq 'restart') { $messages += "Installed $label, a restart is needed to complete the installation" }
                else { $messages += "Installed $label" }
            }
            catch {
                $errors += "Failed to install ${label}: $($_.Exception.Message)"
            }
        }
        #endregion
    }
    finally { Set-Location -LiteralPath $workPath.Path }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }