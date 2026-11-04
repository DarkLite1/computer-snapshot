#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Hosts file entries as a configuration section.
.DESCRIPTION
    Each entry lists Hostnames for one IPAddress (IPv4 or IPv6). Import makes
    each host name point to that address in the Windows hosts file:
    - a name that already points to it is left alone;
    - a name that points to another address is moved, which is reported;
    - a missing name is added on a new line with the address.
    An entry with Action Remove removes its Hostnames from the hosts file.

    Comments, empty lines and all other entries are kept. The file is only
    written when something changed: the original is kept as hosts.bak and the
    DNS client cache is cleared. Each failed entry is reported in Errors and
    the remaining entries are still applied.

    Export writes every active line of the hosts file, one entry per address.
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
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"

#region Windows helpers
function Get-HostsFilePathHC {
    Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
}
function ConvertFrom-HostsLineHC {
    # An active line as address, names and comment; $null for other lines
    param([string]$Line)
    $text = $Line
    $comment = ''
    $hash = $Line.IndexOf('#')
    if ($hash -ge 0) {
        $text = $Line.Substring(0, $hash)
        $comment = $Line.Substring($hash)
    }
    $parts = @($text.Trim() -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $null }
    [pscustomobject]@{
        IPAddress = $parts[0]
        Hostnames = [System.Collections.Generic.List[string]]@(
            $parts[1..($parts.Count - 1)]
        )
        Comment   = $comment
        Text      = $Line
        Modified  = $false
    }
}
function ConvertTo-HostsLineHC {
    param([Parameter(Mandatory)]$Entry)
    $line = "$($Entry.IPAddress)`t$($Entry.Hostnames -join ' ')"
    if ($Entry.Comment) { $line += " $($Entry.Comment)" }
    $line
}
function Write-HostsFileHC {
    # Write next to the hosts file, then swap it in and keep hosts.bak
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )
    $temporary = "$Path.computer-snapshot.tmp"
    $encoding = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllLines($temporary, $Lines, $encoding)
    if ([IO.File]::Exists($Path)) {
        Write-Verbose "Replace hosts file '$Path' (backup '$Path.bak')"
        [IO.File]::Replace($temporary, $Path, "$Path.bak")
    }
    else {
        Write-Verbose "Create hosts file '$Path'"
        [IO.File]::Move($temporary, $Path)
    }
}
#endregion

$exportData = $null
$messages = @()
$errors = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import hosts file entries: empty section, nothing to do'
    return [pscustomobject]@{
        Data     = $null
        Messages = [string[]]@('Nothing to do')
        Errors   = [string[]]@()
    }
}

$hostsPath = Get-HostsFilePathHC
Write-Verbose "Read hosts file '$hostsPath'"

# One item per line: an active entry object, or the line as text
$lines = [System.Collections.Generic.List[object]]::new()
if ([IO.File]::Exists($hostsPath)) {
    foreach ($line in [IO.File]::ReadAllLines($hostsPath)) {
        $entry = ConvertFrom-HostsLineHC -Line $line
        if ($entry) { $lines.Add($entry) } else { $lines.Add($line) }
    }
}
else {
    Write-Verbose 'Hosts file not found, start with an empty file'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export hosts file entries'
    $byAddress = [ordered]@{}
    foreach ($entry in @($lines | Where-Object { $_ -isnot [string] })) {
        if (-not $byAddress.Contains($entry.IPAddress)) {
            $byAddress[$entry.IPAddress] =
            [System.Collections.Generic.List[string]]::new()
        }
        foreach ($name in $entry.Hostnames) {
            if ($byAddress[$entry.IPAddress] -notcontains $name) {
                $byAddress[$entry.IPAddress].Add($name)
            }
        }
    }
    $exportData = @(
        foreach ($address in $byAddress.Keys) {
            [ordered]@{
                IPAddress = $address
                Hostnames = @($byAddress[$address])
            }
        }
    )
    #endregion

    $messages = @("Exported $($exportData.Count) hosts file address(es)")
}
else {
    #region Apply section
    Write-Verbose 'Import hosts file entries'
    $changed = $false
    foreach ($item in @($Data | Where-Object { $null -ne $_ })) {
        $names = @($item.Hostnames | Where-Object { $_ })
        $isRemove = $item.Action -eq 'Remove'
        $label = if ($isRemove) {
            "host name(s) '$($names -join "', '")'"
        }
        else {
            "'$($item.IPAddress)'"
        }
        Write-Verbose "Hosts file entry ${label}"
        try {
            if (-not $names.Count) { throw 'Hostnames is empty' }
            foreach ($name in $names) {
                if (-not (Test-HostNameHC $name)) {
                    throw "'$name' is not a valid host name"
                }
            }
            if (
                -not $isRemove -and
                -not (Test-HostsIPAddressHC $item.IPAddress)
            ) {
                throw ("'$($item.IPAddress)' is not an IPv4 or IPv6 " +
                    'address')
            }
            $missing = [System.Collections.Generic.List[string]]::new()
            foreach ($name in $names) {
                $found = $false
                $entries = @($lines | Where-Object { $_ -isnot [string] })
                foreach ($entry in $entries) {
                    $match = @(
                        $entry.Hostnames | Where-Object { $_ -eq $name }
                    )
                    if (-not $match.Count) { continue }
                    if (
                        -not $isRemove -and
                        $entry.IPAddress -eq $item.IPAddress
                    ) {
                        $found = $true
                        continue
                    }
                    foreach ($existing in $match) {
                        $null = $entry.Hostnames.Remove($existing)
                    }
                    $entry.Modified = $true
                    $changed = $true
                    if ($isRemove) {
                        $messages += (
                            "Removed host name '$name' (pointed to " +
                            "$($entry.IPAddress)) from the hosts file"
                        )
                        $found = $true
                    }
                    else {
                        $messages += (
                            "Host name '$name' pointed to " +
                            "$($entry.IPAddress); it now points to " +
                            "$($item.IPAddress)"
                        )
                    }
                }
                if ($isRemove -and -not $found) {
                    $messages += (
                        "Host name '$name' is not in the hosts file, " +
                        'nothing to remove'
                    )
                }
                elseif (-not $isRemove -and -not $found) {
                    $missing.Add($name)
                }
                elseif (-not $isRemove) {
                    $messages += (
                        "Host name '$name' already points to " +
                        "$($item.IPAddress)"
                    )
                }
            }
            if ($missing.Count) {
                Write-Verbose "Add $($missing.Count) missing host name(s)"
                $lines.Add([pscustomobject]@{
                        IPAddress = [string]$item.IPAddress
                        Hostnames = $missing
                        Comment   = ''
                        Text      = ''
                        Modified  = $true
                    })
                $changed = $true
                foreach ($name in $missing) {
                    $moved = "Host name '$name' pointed to *"
                    if (-not ($messages -like $moved)) {
                        $messages += (
                            "Added host name '$name' for $($item.IPAddress)"
                        )
                    }
                }
            }
        }
        catch {
            $errors += (
                "Failed to apply hosts file entry ${label}: " +
                "$($_.Exception.Message)"
            )
        }
    }

    if ($changed) {
        try {
            # Unchanged lines are kept as they were; a line whose names were
            # all moved or removed is dropped
            $text = @(
                foreach ($line in $lines) {
                    if ($line -is [string]) { $line }
                    elseif (-not $line.Modified) { $line.Text }
                    elseif ($line.Hostnames.Count) {
                        ConvertTo-HostsLineHC -Entry $line
                    }
                }
            )
            Write-HostsFileHC -Path $hostsPath -Lines $text
            Write-Verbose 'Clear DNS client cache'
            Clear-DnsClientCache
        }
        catch {
            $errors += (
                "Failed to write the hosts file '$hostsPath': " +
                "$($_.Exception.Message)"
            )
        }
    }
    else {
        Write-Verbose 'Hosts file unchanged, not written'
    }
    #endregion
}

[pscustomobject]@{
    Data     = $exportData
    Messages = [string[]]$messages
    Errors   = [string[]]$errors
}
