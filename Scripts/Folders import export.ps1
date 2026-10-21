#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Folders as a configuration section.
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

#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\CreateFolders.json"
    #endregion
    $messages = @('Exported Folders')
}
else {
    #region Apply section
    $messages = @(& {
$folders = $Data
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
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
