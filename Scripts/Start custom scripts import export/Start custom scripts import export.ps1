#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Start custom scripts as a configuration section.
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
. "$PSScriptRoot\..\Common\Section.ps1"
#region Windows helpers
function Invoke-CustomScriptHC {
    param([string]$Path, [hashtable]$Arguments)
    & $Path @Arguments
}
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$exportData = Read-SectionExampleHC "$PSScriptRoot\Example.json"
    #endregion
    $messages = @('Exported Start custom scripts')
}
else {
    #region Apply section
    $messages = @(& {
foreach ($script in $Data) {
    $path = Resolve-RootPathHC -Path $script.Path -RootFolder $RootFolder
    $arguments = @{}
    if ($script.Arguments) {
        foreach ($property in $script.Arguments.PSObject.Properties) {
            if ($property.Name -ne 'Comment') { $arguments[$property.Name] = $property.Value }
        }
    }
    try {
        Write-Output "Execute script '$path'"
        Invoke-CustomScriptHC -Path $path -Arguments $arguments | ForEach-Object { [string]$_ }
    }
    catch { Write-Error "Failed to execute script '$path': $_" }
}
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
