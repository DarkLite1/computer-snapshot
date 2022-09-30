<#
    .SYNOPSIS
        Install or remove software packages

    .DESCRIPTION
        The .JSON file contains a list of software packages to install or 
        remove. When a package is requested to be installed and removed, it 
        will first be uninstalled and then installed again.
        
    .PARAMETER Action
        When action is 'Export' a template file is created that can be edited 
        by the user.
        When action is 'Import' the import file is read and the packages in the 
        file will be installed.

    .PARAMETER DataFolder
        Folder containing the import file and the software packages.

    .PARAMETER ImportFileName
        File containing the registry keys.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$ImportFileName = 'Software.json'
)

Begin {    
    Function Get-InstalledApplicationsHC {
        <#
        .SYNOPSIS
            Get all applications installed

        .DESCRIPTION
            Query the registry to find all installed applications. The following code
            does not always return all installed applications:
            Get-WmiObject -Class Win32_Product
        #>
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

    Try {
        $ImportFilePath = Join-Path -Path $DataFolder -ChildPath $ImportFileName
        $packagesFolder = Join-Path -Path $DataFolder -ChildPath 'Packages'

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $ImportFilePath -PathType Leaf)) {
                throw "Input file '$ImportFilePath' not found"
            }
        }
        #endregion
    }
    Catch {
        $errorMessage = $_; $Error.RemoveAt(0)
        throw "$Action software packages failed: $errorMessage"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            #region Create example config file
            Write-Verbose "Create example file '$ImportFilePath'"
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Example.json'
                Destination = $ImportFilePath
            }
            Copy-Item @params
            Write-Output "Created example file '$ImportFilePath'"
            #endregion

            #region Create empty packages folder
            $null = New-Item -Path $packagesFolder -ItemType Directory
            #endregion
        }
        else {
            $workPath = Get-Location
            Set-Location $DataFolder

            #region Import .JSON file
            Write-Verbose "Import from file '$ImportFilePath'"
            $getParams = @{
                LiteralPath = $ImportFilePath
                Encoding    = 'UTF8'
                Raw         = $true
            }
            $import = Get-Content @getParams | 
            ConvertFrom-Json -EA Stop
            #endregion
     
            #region Remove packages
            foreach ($applicationName in $import.SoftwarePackages.Remove) {
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
            #endregion

            #region Install packages
            foreach ($application in $import.SoftwarePackages.Install) {
                try {
                    #region Test executable file
                    if (-not $application.ExecutablePath) {
                        throw "Property 'ExecutablePath' is mandatory"
                    }
                    #endregion

                    #region Get executable path from software folder
                    $params = @{
                        Path        = $application.ExecutablePath
                        ErrorAction = 'Ignore'
                    }
                    $executablePath = Convert-Path @params
                    #endregion

                    #region Test executable file
                    if (-not $executablePath) {
                        throw "Executable file '$($application.ExecutablePath)' not found"
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
                    throw "Failed to install executable '$($application.ExecutablePath)' with arguments '$($application.Arguments)': $errorMessage"
                } 
            }
            #endregion
        }
    }
    Catch {
        $errorMessage = $_; $Error.RemoveAt(0)
        throw "$Action software packages failed: $errorMessage"
    }
    Finally {
        If ($Action -eq 'Import') {
            Set-Location $workPath
        }
    }
}