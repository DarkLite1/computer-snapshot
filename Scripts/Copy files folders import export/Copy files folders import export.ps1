<#
    .SYNOPSIS
        Copy files from one location to another.

    .DESCRIPTION
        When action is 'Export' the script will create an example file that can 
        be used with action set to 'Import'.

        When action is 'Import' the import file is read and all files and 
        folder in the file will be copied.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER FileName
        The file containing the paths to the files or folders to copy, with the 
        from and to fields.

    .PARAMETER DataFolder
        Folder where the export or import file can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Create the example file 'C:\copy\copy.json' that can be used later on 
        with action 'Import'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Read the file 'C:\copy\copy.json' and execute all copy actions defined 
        in the file.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'CopyFilesFolders.json'
)

Begin {
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