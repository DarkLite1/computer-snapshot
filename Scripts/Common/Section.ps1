#Requires -Version 5.1
<#
.SYNOPSIS
    Shared section helpers for standalone snapshot components.
#>
function Resolve-RootPathHC {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RootFolder)
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expandedPath)) { return $expandedPath }
    return [IO.Path]::GetFullPath((Join-Path $RootFolder $expandedPath))
}

function Test-EmptySectionHC {
    param($Data)
    if ($null -eq $Data) { return $true }
    if ($Data -is [System.Collections.IDictionary]) { return @($Data.Keys | Where-Object { $_ -ne 'Comment' }).Count -eq 0 }
    if ($Data -is [array]) { return $Data.Count -eq 0 }
    return @($Data.PSObject.Properties | Where-Object { $_.Name -ne 'Comment' }).Count -eq 0
}

function Read-SectionExampleHC {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    $wrapper = ConvertFrom-Json -InputObject ('{"Data":' + $text + '}') -ErrorAction Stop
    return ,$wrapper.Data
}