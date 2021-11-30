<#
    .SYNOPSIS
        Execute custom PowerShell scripts.

    .DESCRIPTION
        This script will execute custom PowerShell scripts that are found in the import folder.

    .PARAMETER Action
        When action is 'Export' example .ps1 files will be saved in the data 
        folder. When action is 'Import' the .ps1 scripts in the data folder 
        are simply executed.

    .PARAMETER DataFolder
        Folder where the PowerShell scripts can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\scripts'
        }
        & 'C:\script.ps1' @params

        Add .ps1 example files in the folder 'C:\scripts'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\scripts'
        }
        & 'C:\script.ps1' @params

        The .ps1 files found in the folder 'C:\scripts' will be executed.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder
)

Begin {
    Function Get-FullPathHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )

        if ($Path -like '*:*') {
            $Path
        }
        else {
            Join-Path -Path $DataFolder -ChildPath $Path
        }
    }

    Try {
        $ExportFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            If (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
                throw "Import file '$ExportFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            #region Create example config file
            Write-Verbose "Create example config file '$ExportFile'"
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Examples\CopyFilesFolders.json'
                Destination = $ExportFile
            }
            Copy-Item @params
            Write-Output "Created example config file '$ExportFile'"
            #endregion

            #region Create example copy file
            Write-Verbose 'Create example copy file'
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Examples\Monitor SSD.ps1'
                Destination = Join-Path $DataFolder 'Monitor SSD.ps1'
            }
            Copy-Item @params
            Write-Output "Created example copy file '$($params.Destination)'"
            #endregion
        }
        else {
            $itemsToCopy = Get-Content -Path $ExportFile -Raw | ConvertFrom-Json

            foreach ($i in $itemsToCopy) {
                try {
                    if (-not ($from = $i.From)) {
                        throw "The field 'From' is required"
                    }
                    if (-not ($to = $i.To)) {
                        throw "The field 'To' is required"
                    }
                    $from = Get-FullPathHC -Path $from
                    if (-not 
                        ($fromItem = Get-Item -LiteralPath $from -EA Ignore)
                    ) {
                        throw "File or folder '$from' not found"
                    }
                    if (-not $fromItem.PSIsContainer) {
                        # when the source is a file 
                        # create the destination folder manually 
                        $newItemParams = @{
                            Path     = (Split-Path -Path $to) 
                            ItemType = 'Directory'
                            Force    = $true
                        }
                        $null = New-Item @newItemParams
                    }
                    else {
                        $from = "$from\*"
                        $null = New-Item -Path $to -ItemType Directory -Force
                    }

                    $copyParams = @{
                        Path        = $from
                        Destination = $to
                        Recurse     = $true 
                        ErrorAction = 'Stop'
                    }
                    Copy-Item @copyParams

                    if (-not (Test-Path -LiteralPath $to)) {
                        throw "Path '$to' not created"
                    }

                    Write-Output "Copied from '$from' to '$to'"
                }
                catch {
                    Write-Error "Failed to copy from '$($i.From)' to '$($i.To)': $_"
                }
            }
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}