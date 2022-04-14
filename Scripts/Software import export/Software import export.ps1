<#
    .SYNOPSIS
        Install software packages

    .DESCRIPTION
        Read which software packages to install from an input file and
        install the required packages on the current machine.
        
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

        cmd /C $UninstallString

        if ($LASTEXITCODE) {
            throw "ExitCode '$LASTEXITCODE'"
        }
        else {
            $M = "Removed application '$ApplicationName'"
            Write-Verbose $M; Write-Output $M
        }
    }

    Try {
        $ImportFilePath = Join-Path -Path $DataFolder -ChildPath $ImportFileName
        $softwareFolder = Join-Path -Path $DataFolder -ChildPath 'Software'

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
            If (
                (-not (Test-Path -LiteralPath $softwareFolder -PathType Container)) -or
                ((Get-ChildItem -Path $softwareFolder | Measure-Object).Count -eq 0)
            ) {
                throw "Software folder '$softwareFolder' empty"
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

            #region Create empty software folder
            $null = New-Item -Path $softwareFolder -ItemType Directory
            #endregion
        }
        else {
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
     
            $allApplications = Get-InstalledApplicationsHC

            #region Remove packages
            foreach ($applicationName in $import.SoftwarePackages.Remove) {
                if (
                    $installedApp = $allApplications |
                    Where-Object { $_.DisplayName -eq $applicationName }
                ) {
                    try {
                        Write-Verbose "Application '$applicationName'"
            
                        #region Get removal string
                        $uninstallString = if (
                            $installedApp.QuietUninstallString
                        ) {
                            $installedApp.QuietUninstallString
                        }
                        else {
                            $installedApp.UninstallString
                        }
                
                        Write-Verbose "Removal string '$uninstallString'"
                        #endregion
                
                        #region Remove application
                        if ($uninstallString) {
                            $params = @{
                                ApplicationName = $applicationName
                                UninstallString = $uninstallString
                            }
                            Remove-ApplicationHC @params
                        }
                        else {
                            throw 'No removal string found in the registry'
                        }       
                        #endregion
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
                    if (-not $application.ExecutableName) {
                        throw "Property 'ExecutableName' is mandatory"
                    }
    
                    $joinParams = @{
                        Path      = $softwareFolder
                        ChildPath = $application.ExecutableName
                    }
                    $executablePath = Join-Path @joinParams

                    if (-not (Test-Path -LiteralPath $executablePath -PathType leaf)) {
                        throw "Executable file '$executablePath' not found"
                    }

                    Write-Verbose "Install executable '$($application.ExecutableName)'"

                    $startParams = @{
                        FilePath    = $executablePath
                        NoNewWindow = $true
                        Wait        = $true
                        PassThru    = $true
                        ErrorAction = 'Stop'
                    }
                    if ($application.Arguments) {
                        $startParams.ArgumentList = $application.Arguments
                    }
                    $process = Start-Process @startParams
                    if ($process.ExitCode) {
                        throw "Installation failed with ExitCode '$($process.ExitCode)'"
                    }
                    else {
                        Write-Output "Executable '$($application.ExecutableName)' installed"
                    }
                }
                catch {
                    $errorMessage = $_; $Error.RemoveAt(0)
                    throw "Failed to install executable '$($application.ExecutableName)' with arguments '$($application.Arguments)': $errorMessage"
                } 
            }
            #endregion
        }
    }
    Catch {
        $errorMessage = $_; $Error.RemoveAt(0)
        throw "$Action software packages failed: $errorMessage"
    }
}