#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Copy files folders as a configuration section.
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
    $messages = @('Exported Copy files folders')
}
else {
    #region Apply section
    $messages = @(& {
$itemsToCopy = $Data
foreach ($i in $itemsToCopy) {
                try {
                    if (-not ($from = $i.From)) {
                        throw "The field 'From' is required"
                    }
                    if (-not ($to = $i.To)) {
                        throw "The field 'To' is required"
                    }
                    $from = Resolve-RootPathHC -Path $from -RootFolder $RootFolder
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

                    Write-Output "Copied from '$from' to '$to'"
                }
                catch {
                    Write-Error "Failed to copy from '$($i.From)' to '$($i.To)': $_"
                }
            }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
