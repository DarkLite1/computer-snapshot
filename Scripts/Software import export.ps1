#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Software as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
Function Get-InstalledApplicationsHC {
        
        Try {
            $R1 = Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
            Where-Object { $_.DisplayName } | 
            Select-Object DisplayName, DisplayVersion, Publisher, 
            UninstallString, QuietUninstallString,
            @{Name = 'InstallDate'; Expression = { if ($_.InstallDate) { [DateTime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } } }
            
            
            $R2 = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
            Where-Object { $_.DisplayName } | 
            Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, QuietUninstallString,
            @{Name = 'InstallDate'; Expression = { if ($_.InstallDate) { [DateTime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } } }
            
            $New = $R1 + $R2
            $New | Sort-Object DisplayName -Unique
       
        }
        Catch {
            throw "Failed retrieving installed software: $_"
        }
    }
Function Remove-ApplicationHC {
        Param (
            [Parameter(Mandatory)]
            [String]$ApplicationName,
            [Parameter(Mandatory)]
            [String]$UninstallString
        )

        Write-Verbose "Remove application '$ApplicationName'"

        $global:LASTEXITCODE = 0

        # suppress error messages
        cmd /C $UninstallString 2> $null
    }
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\Software.json"
    #endregion
    $messages = @('Exported Software')
}
else {
    #region Apply section
    $messages = @(& {
try {
$workPath = Get-Location
Set-Location -LiteralPath $RootFolder


$import = $Data
foreach ($applicationName in $import.Remove) {
                if (
                    $installedApplication = Get-InstalledApplicationsHC |
                    Where-Object { $_.DisplayName -eq $applicationName }
                ) {
                    try {
                        Write-Verbose "Application '$applicationName'"
            
                        #region Get removal string
                        $uninstallString = if (
                            $installedApplication.QuietUninstallString
                        ) {
                            $installedApplication.QuietUninstallString
                        }
                        else {
                            $installedApplication.UninstallString
                        }
                
                        Write-Verbose "Removal string '$uninstallString'"
                        #endregion
                
                        if ($uninstallString) {
                            #region Remove application
                            $params = @{
                                ApplicationName = $applicationName
                                UninstallString = $uninstallString
                            }
                            Remove-ApplicationHC @params
                            #endregion

                            #region Test uninstall
                            if (
                                Get-InstalledApplicationsHC | Where-Object { 
                                    $_.DisplayName -eq $applicationName 
                                }
                            ) {
                                throw "Uninstall failed with ExitCode '$LASTEXITCODE'"
                            }
                            else {
                                $M = "Removed application '$ApplicationName'"
                                Write-Verbose $M; Write-Output $M
                            }
                            #endregion
                        }
                        else {
                            throw 'No removal string found in the registry'
                        }       
                    }
                    catch {
                        $errorMessage = $_; $Error.RemoveAt(0)
                        throw "Failed removing application '$applicationName': $errorMessage"
                    }
                }
                else {
                    $M = "Application '$applicationName' was not removed because it was not installed"
                    Write-Verbose $M; Write-Output $M
                }
            }
foreach ($application in $import.Install) {
                try {
                    #region Test executable file
                    if (-not $application.ExecutablePath) {
                        throw "Property 'ExecutablePath' is mandatory"
                    }
                    #endregion

                    #region Get executable path from software folder
                    $params = @{
                        Path        = Resolve-RootPathHC -Path $application.ExecutablePath -RootFolder $RootFolder
                        ErrorAction = 'Ignore'
                    }
                    $executablePath = Convert-Path @params
                    #endregion

                    #region Test executable file
                    if (-not $executablePath) {
                        throw "Executable file '$($application.ExecutablePath)' not found in folder '$PSScriptRoot'"
                    }

                    $testPathParams = @{
                        LiteralPath = $executablePath
                        PathType    = 'Leaf'
                    }
                    if (-not (Test-Path @testPathParams)) {
                        throw "Executable path '$executablePath' is not a file"
                    }
                    #endregion

                    #region Install software package
                    Write-Verbose "Install executable '$executablePath'"

                    $startParams = @{
                        FilePath    = $executablePath
                        NoNewWindow = $true
                        Wait        = $true
                        PassThru    = $true
                        ErrorAction = 'Stop'
                    }
                    if ($application.Arguments) {
                        $startParams.ArgumentList = $application.Arguments
                        Write-Verbose "Arguments '$($application.Arguments)'"
                    }
                    $process = Start-Process @startParams
                    if ($process.ExitCode) {
                        throw "Installation failed with ExitCode '$($process.ExitCode)'"
                    }
                    else {
                        Write-Output "Installed executable '$executablePath' with arguments '$($application.Arguments)'"
                    }
                    #endregion
                }
                catch {
                    $errorMessage = $_; $Error.RemoveAt(0)
                    Write-Error "Failed to install executable '$($application.ExecutablePath)' with arguments '$($application.Arguments)': $errorMessage"
                } 
            }
} finally { Set-Location -LiteralPath $workPath.Path }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
