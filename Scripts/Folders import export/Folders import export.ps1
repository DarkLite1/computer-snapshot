<#
    .SYNOPSIS
        Create folders.

    .DESCRIPTION
        Read the folder paths from an input file and create the required 
        folders. This script will never delete a folder.
        
    .PARAMETER Action
        When action is 'Import' the required folders will be created from 
        the import file. When action is 'Export' a template file is exported
        that can be edited by the user.

    .PARAMETER DataFolder
        Folder where file can be found that contains the folder paths.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$foldersFileName = 'Folders.txt'
)

Begin {    
    Try {
        $foldersFile = Join-Path -Path $DataFolder -ChildPath $foldersFileName

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
            If (-not (Test-Path -LiteralPath $foldersFile -PathType Leaf)) {
                throw "Folders file '$foldersFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action folders failed: $_"
    }
}

Process {
    Try {
        Write-Verbose "Import folders from file '$foldersFile'"
        $folders = Get-Content -LiteralPath $foldersFile -Encoding UTF8
        
        foreach ($folder in $folders) {
            Try {
                Write-Verbose "Folder '$folder'"
          
                If (Test-Path -LiteralPath $folder -PathType Container) {
                    Write-Output "Folder '$folder' exists already"
                }
                else {
                    if (
                        $folder -NotMatch 
                        '^([a-zA-Z]+:)?(\\[a-zA-Z0-9-_.-: :]+)*\\?$'
                    ) {
                        throw "Path not valid"
                    }
                    $null = New-Item -Path $folder -ItemType Directory
                    Write-Output "Folder '$folder' created"
                }
            }
            Catch {
                Write-Error "Failed to create folder '$folder': $_"
                $Error.RemoveAt(1)
            }
        }
    }
    Catch {
        throw "$Action Folders failed: $_"
    }
}