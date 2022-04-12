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
        Folder where the file can be found that contains the folder paths.

    .PARAMETER FoldersFileName
        File containing strings representing the full path of the folders
        that need to be created.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FoldersFileName = 'CreateFolders.json'
)

Begin {    
    Try {
        $foldersFile = Join-Path -Path $DataFolder -ChildPath $FoldersFileName

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
        If ($Action -eq 'Export') {
            #region Create example file
            Write-Verbose "Create example file '$foldersFile'"
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Example.json'
                Destination = $foldersFile
            }
            Copy-Item @params
            Write-Output "Created example file '$foldersFile'"
            #endregion
        }
        else {
            #region Import .JSON file
            Write-Verbose "Import folders from file '$foldersFile'"
            $getParams = @{
                LiteralPath = $foldersFile 
                Encoding    = 'UTF8'
                Raw         = $true
            }
            $folders = Get-Content @getParams | ConvertFrom-Json -EA Stop
            #endregion

            #region Test .JSON file
            if (-not $folders.FolderPaths) {
                throw "Property 'FolderPaths' is empty, no folder to create. Please update the input file '$foldersFile'"
            }
            #endregion

            foreach ($path in $folders.FolderPaths) {
                Try {
                    Write-Verbose "Folder '$path'"
          
                    If (Test-Path -LiteralPath $path -PathType Container) {
                        Write-Output "Folder '$path' exists already"
                    }
                    else {
                        if (
                            $path -NotMatch 
                            '^([a-zA-Z]+:)?(\\[a-zA-Z0-9-_.-: :]+)*\\?$'
                        ) {
                            throw 'Path not valid'
                        }
                        $null = New-Item -Path $path -ItemType Directory
                        Write-Output "Folder '$path' created"
                    }
                }
                Catch {
                    Write-Error "Failed to create folder '$path': $_"
                    $Error.RemoveAt(1)
                }
            }
        }
    }
    Catch {
        throw "$Action Folders failed: $_"
    }
}