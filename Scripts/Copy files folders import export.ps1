#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Copy files folders as a configuration section.
.DESCRIPTION
    Import copies each From item, relative to the USB root unless it is a full
    path, to its To path:
    - A file is copied to the To file path; missing folders are created.
    - A folder's contents, including hidden files and subfolders, are copied
      into the To folder.
    Existing files at the destination are overwritten, also when they are
    read-only; other files at the destination are left alone. When some files
    cannot be copied, the other files are still copied and every failed file
    is reported. Each problem is reported in Errors and the remaining entries
    are still copied.
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
#region Helpers
function Copy-FolderContentHC {
    # Copy file by file, so every failure is caught and the other files are
    # still copied. Copy-Item -Recurse cannot do this reliably: Windows
    # PowerShell 5.1 turns some copy errors, such as a locked file, into an
    # error that stops the whole copy, whatever -ErrorAction says.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Failures
    )
    try { $children = @(Get-ChildItem -LiteralPath $Source -Force) }
    catch {
        $Failures.Add("'$Source': $($_.Exception.Message)")
        return
    }
    foreach ($child in $children) {
        $target = Join-Path -Path $Destination -ChildPath $child.Name
        if ($child.PSIsContainer) {
            try { $null = New-Item -Path $target -ItemType Directory -Force }
            catch {
                $Failures.Add("'$($child.FullName)': $($_.Exception.Message)")
                continue
            }
            Copy-FolderContentHC -Source $child.FullName -Destination $target -Failures $Failures
        }
        else {
            try { Copy-Item -LiteralPath $child.FullName -Destination $target -Force }
            catch { $Failures.Add("'$($child.FullName)': $($_.Exception.Message)") }
        }
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
    $exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\CopyFilesFolders.json"
    #endregion
    $messages = @('Exported Copy files folders')
}
else {
    #region Apply section
    foreach ($item in @($Data | Where-Object { $null -ne $_ })) {
        try {
            if (-not $item.From) { throw "the field 'From' is required" }
            if (-not $item.To) { throw "the field 'To' is required" }
            $from = Resolve-RootPathHC -Path $item.From -RootFolder $RootFolder
            $to = $item.To
            $fromItem = Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue
            if (-not $fromItem) { throw "file or folder '$from' not found" }

            if ($fromItem.PSIsContainer) {
                $null = New-Item -Path $to -ItemType Directory -Force
                $failures = New-Object 'System.Collections.Generic.List[string]'
                Copy-FolderContentHC -Source $from -Destination $to -Failures $failures
                if ($failures.Count) {
                    $details = @($failures | Select-Object -First 5)
                    if ($failures.Count -gt 5) { $details += "and $($failures.Count - 5) more" }
                    throw "$($failures.Count) item(s) could not be copied, the others were copied: $($details -join '; ')"
                }
                $what = "the contents of folder '$($item.From)'"
            }
            else {
                $parent = Split-Path -Path $to -Parent
                if ($parent) { $null = New-Item -Path $parent -ItemType Directory -Force }
                Copy-Item -LiteralPath $from -Destination $to -Force
                $what = "file '$($item.From)'"
            }

            if (-not (Test-Path -LiteralPath $to)) { throw "'$to' was not created" }
            $messages += "Copied $what to '$to'"
        }
        catch {
            $errors += "Failed to copy '$($item.From)' to '$($item.To)': $($_.Exception.Message)"
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }