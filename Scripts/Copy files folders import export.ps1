#Requires -Version 5.1

<#
.SYNOPSIS
    Export or import Copy files folders as a configuration section.
.DESCRIPTION
    Import copies each From item, relative to the USB root unless it is a
    full path, to its To path:
    - A file is copied to the To file path; missing folders are created.
    - A folder's contents, including hidden files and subfolders, are copied
      into the To folder.
    Existing files at the destination are overwritten, also when they are
    read-only; other files at the destination are left alone. When some
    files cannot be copied, the other files are still copied and every
    failed file is reported. Each problem is reported in Errors and the
    remaining entries are still copied.

    With FillPlaceholders, a text file is copied with its {{input:...}},
    {{ipv4:...}} and {{prefix:...}} placeholders replaced by the answers
    given at the start of the restore, in PlaceholderValues. The file keeps
    its encoding. When To is an existing folder, the file is written into
    it under its own name.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written
    here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')]
    [string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"

#region Helpers
function Copy-FilledFileHC {
    # Copy a text file with its placeholders filled in, in its own encoding;
    # returns the number of placeholders filled in
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        $Values
    )

    $bytes = [IO.File]::ReadAllBytes($Source)

    $encoding = if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    ) {
        New-Object System.Text.UTF8Encoding $true
    }
    elseif (
        $bytes.Length -ge 2 -and
        $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
    ) {
        [Text.Encoding]::Unicode
    }
    elseif (
        $bytes.Length -ge 2 -and
        $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF
    ) {
        [Text.Encoding]::BigEndianUnicode
    }
    else {
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding $false, $true
            $null = $strictUtf8.GetString($bytes)
            New-Object System.Text.UTF8Encoding $false
        }
        catch {
            # Not UTF-8 without a byte order mark: the Windows code page
            $textInfo = [Globalization.CultureInfo]::CurrentCulture.TextInfo
            [Text.Encoding]::GetEncoding($textInfo.ANSICodePage)
        }
    }
    Write-Verbose "File '$Source': encoding '$($encoding.WebName)'"

    $skip = $encoding.GetPreamble().Length
    $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
    $pattern = '\{\{(?:input|ipv4|prefix):[^{}\r\n]+\}\}'
    $placeholders = @(
        [regex]::Matches($text, $pattern) | ForEach-Object { $_.Value }
    )
    $missing = @(
        $placeholders | Select-Object -Unique |
        Where-Object { -not ($Values -and $Values.ContainsKey($_)) }
    )

    if ($missing.Count) {
        throw "no answer for the placeholder(s) $($missing -join ', ')"
    }

    foreach ($placeholder in @($placeholders | Select-Object -Unique)) {
        $text = $text.Replace($placeholder, [string]$Values[$placeholder])
    }

    if ([IO.File]::Exists($Destination)) {
        $file = Get-Item -LiteralPath $Destination -Force
        $file.IsReadOnly = $false
    }

    [IO.File]::WriteAllText($Destination, $text, $encoding)
    $placeholders.Count
}

function Copy-FolderContentHC {
    # Copy file by file, so every failure is caught and the other files are
    # still copied. Copy-Item -Recurse cannot do this reliably: Windows
    # PowerShell 5.1 turns some copy errors, such as a locked file, into an
    # error that stops the whole copy, whatever -ErrorAction says.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Failures
    )

    try {
        $children = @(Get-ChildItem -LiteralPath $Source -Force)
    }
    catch {
        $Failures.Add("'$Source': $($_.Exception.Message)")
        return
    }

    foreach ($child in $children) {
        $target = Join-Path -Path $Destination -ChildPath $child.Name

        if ($child.PSIsContainer) {
            try {
                $null = New-Item -Path $target -ItemType Directory -Force
            }
            catch {
                $Failures.Add(
                    "'$($child.FullName)': $($_.Exception.Message)"
                )
                continue
            }

            $copyParams = @{
                Source      = $child.FullName
                Destination = $target
                Failures    = $Failures
            }
            Copy-FolderContentHC @copyParams
        }
        else {
            try {
                $copyParams = @{
                    LiteralPath = $child.FullName
                    Destination = $target
                    Force       = $true
                }
                Copy-Item @copyParams
            }
            catch {
                $Failures.Add(
                    "'$($child.FullName)': $($_.Exception.Message)"
                )
            }
        }
    }
}
#endregion

$exportData = $null
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Copy files folders: section is empty, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Copy files folders: use the example configuration'
    $exportData = Read-SectionExampleHC (
        "$PSScriptRoot\..\Examples\CopyFilesFolders.json"
    )
    #endregion

    $messages.Insert(0, 'Exported Copy files folders')
}
else {
    #region Apply section
    Write-Verbose 'Import Copy files folders'
    foreach ($item in @($Data | Where-Object { $null -ne $_ })) {
        try {
            if (-not $item.From) {
                throw "the field 'From' is required"
            }

            if (-not $item.To) {
                throw "the field 'To' is required"
            }

            $from = Resolve-RootPathHC -Path $item.From -RootFolder $RootFolder
            # %ProgramData%\Vendor becomes C:\ProgramData\Vendor
            $to = Expand-PathVariableHC -Path $item.To
            Write-Verbose "Copy '$from' to '$to'"
            $getItemParams = @{
                LiteralPath = $from
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }
            $fromItem = Get-Item @getItemParams

            if (-not $fromItem) {
                throw "file or folder '$from' not found"
            }

            if ($fromItem.PSIsContainer) {
                if ($item.FillPlaceholders -eq $true) {
                    throw (
                        'FillPlaceholders only works for a file, ' +
                        'not for a folder'
                    )
                }

                $null = New-Item -Path $to -ItemType Directory -Force
                $failures = New-Object 'System.Collections.Generic.List[string]'

                Write-Verbose "Copy the contents of folder '$from'"
                $copyParams = @{
                    Source      = $from
                    Destination = $to
                    Failures    = $failures
                }
                Copy-FolderContentHC @copyParams

                if ($failures.Count) {
                    $details = @($failures | Select-Object -First 5)

                    if ($failures.Count -gt 5) {
                        $details += "and $($failures.Count - 5) more"
                    }

                    throw (
                        "$($failures.Count) item(s) could not be copied, " +
                        "the others were copied: $($details -join '; ')"
                    )
                }

                $what = "the contents of folder '$($item.From)'"
            }
            else {
                # Like Copy-Item, an existing folder receives the file
                if (
                    $item.FillPlaceholders -eq $true -and
                    [IO.Directory]::Exists($to)
                ) {
                    $to = [IO.Path]::Combine($to, $fromItem.Name)
                }

                $parent = Split-Path -Path $to -Parent

                if ($parent) {
                    $null = New-Item -Path $parent -ItemType Directory -Force
                }

                if ($item.FillPlaceholders -eq $true) {
                    Write-Verbose "Copy file '$from' with placeholders filled"
                    $copyParams = @{
                        Source      = $from
                        Destination = $to
                        Values      = $item.PlaceholderValues
                    }
                    $count = Copy-FilledFileHC @copyParams

                    $what = (
                        "file '$($item.From)' with $count " +
                        'placeholder(s) filled in'
                    )
                }
                else {
                    Copy-Item -LiteralPath $from -Destination $to -Force
                    $what = "file '$($item.From)'"
                }
            }

            if (-not (Test-Path -LiteralPath $to)) {
                throw "'$to' was not created"
            }

            $messages.Add("Copied $what to '$to'")
        }
        catch {
            $errors.Add(
                "Failed to copy '$($item.From)' to '$($item.To)': " +
                "$($_.Exception.Message)"
            )
        }
    }
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams
