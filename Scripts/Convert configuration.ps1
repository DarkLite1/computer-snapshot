#Requires -Version 5.1
<#
.SYNOPSIS
    Convert one legacy configuration without deleting its snapshot data.
.PARAMETER OldConfigurationFile
    Old StartScript-format configuration. Renamed to name.v1.json after conversion.
.PARAMETER RootFolder
    Absolute USB root. Output is Configurations\<original name>.json.
.OUTPUTS
    The output configuration path and all validation problems.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OldConfigurationFile,
    [Parameter(Mandatory)][string]$RootFolder
)
Import-Module "$PSScriptRoot\Common\Configuration.psm1" -Force
. "$PSScriptRoot\Common\Section.ps1"

function Convert-CommentsHC {
    param($Value)
    if ($Value -is [array]) { foreach ($entry in $Value) { Convert-CommentsHC $entry } }
    elseif ($null -ne $Value -and $Value.GetType() -eq [System.Management.Automation.PSCustomObject]) {
        if ($Value.PSObject.Properties['?']) {
            $comment = [string]$Value.'?'
            $Value.PSObject.Properties.Remove('?')
            $Value | Add-Member -NotePropertyName Comment -NotePropertyValue $comment -Force
        }
        foreach ($property in $Value.PSObject.Properties) { Convert-CommentsHC $property.Value }
    }
}

function Get-RootRelativePathHC {
    param([string]$Path)
    $prefix = $RootFolder.TrimEnd('\', '/') + '\'
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($prefix.Length) }
    return $Path
}

function Copy-LegacyAssetHC {
    param([string]$Source, [string]$DestinationFolder)
    if (-not (Test-Path -LiteralPath $Source)) { throw "Legacy asset '$Source' not found" }
    $destination = Join-Path $DestinationFolder (Split-Path $Source -Leaf)
    if ([string]::Equals($Source, $destination, [StringComparison]::OrdinalIgnoreCase)) { return Get-RootRelativePathHC $destination }
    if (Test-Path -LiteralPath $destination) {
        if ((Test-Path -LiteralPath $Source -PathType Leaf) -and (Test-Path -LiteralPath $destination -PathType Leaf) -and
            (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $destination).Hash) {
            return Get-RootRelativePathHC $destination
        }
        throw "Asset destination '$destination' already exists with different contents; nothing overwritten"
    }
    $null = New-Item -Path $DestinationFolder -ItemType Directory -Force
    Copy-Item -LiteralPath $Source -Destination $destination -Recurse -ErrorAction Stop
    return Get-RootRelativePathHC $destination
}

$RootFolder = [IO.Path]::GetFullPath($RootFolder)
$oldPath = Resolve-RootPathHC $OldConfigurationFile $RootFolder
$oldFile = Get-Item -LiteralPath $oldPath -ErrorAction Stop
$old = Read-SectionExampleHC $oldPath
if (-not $old.StartScript -or $old.SchemaVersion -eq 2) { throw 'Expected an old StartScript-format configuration.' }
$outputFolder = Join-Path $RootFolder 'Configurations'
$outputPath = Join-Path $outputFolder $oldFile.Name
$backupPath = Join-Path $oldFile.DirectoryName ($oldFile.BaseName + '.v1.json')
if (Test-Path -LiteralPath $backupPath) { throw "Backup '$backupPath' already exists" }
if ((Test-Path -LiteralPath $outputPath) -and -not [string]::Equals($outputPath, $oldPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Output '$outputPath' already exists"
}
$legacyRoot = Resolve-RootPathHC $old.StartScript.SnapshotFolder (Join-Path $RootFolder 'Scripts\Invoke scripts')
$itemFiles = @{
    RegionalSettings = 'RegionalSettings.json'; UserAccounts = 'UserAccounts.json'; UserGroups = 'Groups.json'
    FirewallRules = 'FirewallRules.json'; CreateFolders = 'CreateFolders.json'; NetworkCards = 'NetworkCards.json'
    NtpTimeServers = 'ntpServers.json'; RegistryKeys = 'registryKeys.json'; CopyFilesFolders = 'CopyFilesFolders.json'; Software = 'Software.json'
}
$order = @('StartCustomScriptsBefore','RegionalSettings','UserAccounts','UserGroups','FirewallRules','CreateFolders','SmbShares','NetworkCards','NtpTimeServers','RegistryKeys','ScheduledTasks','CopyFilesFolders','Software','StartCustomScriptsAfter')
foreach ($property in $old.StartScript.Snapshot.PSObject.Properties) {
    if ($property.Value -and $property.Name -notin $order) { throw "Unknown old snapshot item '$($property.Name)'" }
}
$items = [ordered]@{}
foreach ($name in $order) {
    if (-not $old.StartScript.Snapshot.$name) { continue }
    $folder = Join-Path $legacyRoot $name
    $data = $null
    if ($itemFiles.ContainsKey($name)) { $data = Read-SectionExampleHC (Join-Path $folder $itemFiles[$name]) }
    switch ($name) {
        'Software' {
            $data = $data.SoftwarePackages
            foreach ($package in $data.Install) {
                $source = Resolve-RootPathHC $package.ExecutablePath $folder
                if ($source.StartsWith(($folder.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                    $package.ExecutablePath = Copy-LegacyAssetHC $source (Join-Path $RootFolder 'Software')
                }
                else { $package.ExecutablePath = Get-RootRelativePathHC $source }
            }
        }
        'CopyFilesFolders' {
            $data = @($data)
            foreach ($entry in $data) {
                $source = Resolve-RootPathHC $entry.From $folder
                $entry.From = Copy-LegacyAssetHC $source (Join-Path $RootFolder "Files\$($oldFile.BaseName)")
            }
        }
        { $_ -in @('StartCustomScriptsBefore', 'StartCustomScriptsAfter') } {
            $data = @(foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File | Sort-Object Name) {
                [pscustomobject]@{ Path = Copy-LegacyAssetHC $file.FullName (Join-Path $RootFolder "Files\$($oldFile.BaseName)") }
            })
        }
        'ScheduledTasks' {
            $data = @(foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File | Where-Object { $_.Name -notlike '* - Definition.xml' }) {
                $task = Import-Clixml -LiteralPath $file.FullName
                $enabled = if ($null -ne $task.Settings.Enabled) { [bool]$task.Settings.Enabled } else { $task.State -ne 'Disabled' }
                [pscustomobject]@{
                    TaskName = $task.TaskName; TaskPath = $task.TaskPath; Enabled = $enabled
                    Xml = [IO.File]::ReadAllText((Join-Path $folder ($file.BaseName + ' - Definition.xml')))
                }
            })
        }
        'SmbShares' {
            $shareData = Read-SectionExampleHC (Join-Path $folder 'SmbShares.json')
            $accessData = Read-SectionExampleHC (Join-Path $folder 'SmbSharesAccess.json')
            $data = [pscustomobject]@{
                Shares = @($shareData)
                Access = @($accessData)
                NTFS = @()
            }
            if (Test-Path -LiteralPath (Join-Path $folder 'NTFS')) {
                $data.NTFS = @(foreach ($file in Get-ChildItem -LiteralPath (Join-Path $folder 'NTFS') -Filter '*.json' -File) {
                    $permissions = Read-SectionExampleHC $file.FullName
                    $permissions | Add-Member -NotePropertyName Name -NotePropertyValue $file.BaseName -Force
                    $permissions
                })
            }
        }
        { $_ -in @('UserAccounts', 'UserGroups', 'FirewallRules', 'NetworkCards') } { $data = @($data) }
    }
    Convert-CommentsHC $data
    $items[$name] = $data
}
if ($items.Count -eq 0) { throw 'The old configuration has no enabled items.' }
$document = [ordered]@{
    SchemaVersion = 2
    Description = 'Converted from ' + $oldFile.Name
    Settings = [ordered]@{
        RebootComputer = [bool]$old.StartScript.RebootComputer
        OpenReportInBrowser = if ($null -ne $old.StartScript.OpenReportInBrowser) { [bool]$old.StartScript.OpenReportInBrowser } else { $true }
        RunElevated = [bool]$old.RunInElevatedPowerShellSession
    }
    Items = $items
}
$null = New-Item -Path $outputFolder -ItemType Directory -Force
Rename-Item -LiteralPath $oldPath -NewName (Split-Path $backupPath -Leaf) -ErrorAction Stop
Write-ConfigurationHC -Configuration $document -Path $outputPath
$problems = @(Test-ConfigurationHC (Read-ConfigurationHC $outputPath $RootFolder) $RootFolder)
foreach ($problem in $problems) { Write-Warning $problem }
Write-Host "Converted to '$outputPath'. Validation problems: $($problems.Count). Original: '$backupPath'."
[pscustomobject]@{ Path = $outputPath; Original = $backupPath; Problems = $problems }