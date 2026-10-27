#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Folders as a configuration section.
.DESCRIPTION
    Import creates each folder in FolderPaths, including missing parent
    folders. Each path must be a full path such as 'C:\Data\Logs' or
    '\\server\share\Logs'. Each failed folder is reported in Errors and
    the remaining folders are still created.
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
function Assert-FolderPathHC {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'the path is empty'
    }
    if ($Path -notmatch '^(?<root>[a-zA-Z]:\\|\\\\[^\\:*?"<>|]+\\[^\\:*?"<>|]+)(?<rest>.*)$') {
        throw "not a full path; use a path such as 'C:\Data\Logs' or '\\server\share\Logs'"
    }
    if ($Matches['rest'] -match '[:*?"<>|\x00-\x1F]') {
        throw 'a folder name cannot contain any of these characters: : * ? " < > |'
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
    $exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\CreateFolders.json"
    #endregion
    $messages = @('Exported Folders')
}
else {
    #region Apply section
    foreach ($path in @($Data.FolderPaths)) {
        try {
            Write-Verbose "Folder '$path'"
            Assert-FolderPathHC $path
            if (Test-Path -LiteralPath $path -PathType Container) {
                $messages += "Folder '$path' already exists"
            }
            else {
                $null = New-Item -Path $path -ItemType Directory
                $messages += "Created folder '$path'"
            }
        }
        catch {
            $errors += "Failed to create folder '$path': $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }