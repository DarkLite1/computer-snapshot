#Requires -Version 5.1
<#
.SYNOPSIS
    Convert one older configuration to version 3 without deleting its data.
.DESCRIPTION
    Two kinds of files are converted:
    - Version 1, the old StartScript format with a snapshot folder. The
      original is renamed to name.v1.json and the result is written to
      Configurations\<name>.json.
    - Version 2. The original is renamed to name.v2.json and the result is
      written in its place. SmbShares changes from three lists (Shares,
      Access and NTFS, linked by share name) to one entry per share with
      its own Access and NTFS. A shared section file it refers to is
      converted as well, after renaming it to name.v2.json.
.PARAMETER OldConfigurationFile
    Configuration to convert.
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
    if ($Value -is [array]) { 
        foreach ($entry in $Value) { Convert-CommentsHC $entry } 
    }
    elseif (
        $null -ne $Value -and $Value.GetType() -eq 
        [System.Management.Automation.PSCustomObject]
    ) {
        if ($Value.PSObject.Properties['?']) {
            $comment = [string]$Value.'?'
            $Value.PSObject.Properties.Remove('?')
            $Value | Add-Member -NotePropertyName Comment -NotePropertyValue $comment -Force
        }
        foreach ($property in $Value.PSObject.Properties) {
            Convert-CommentsHC $property.Value 
        }
    }
}

function ConvertTo-ShareListHC {
    <#
    .SYNOPSIS
        Turn the version-2 SmbShares lists into one entry per share.
    .DESCRIPTION
        Access and NTFS entries are matched to their share by Name. Entries
        for a share that is not in Shares cannot be applied and are reported
        as problems.
    #>
    param(
        [Parameter(Mandatory)]$OldShares,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Problems
    )

    $shares = @($OldShares.Shares | Where-Object { $null -ne $_ })
    $access = @($OldShares.Access | Where-Object { $null -ne $_ })
    $ntfs = @($OldShares.NTFS | Where-Object { $null -ne $_ })
    $shareNames = @($shares | ForEach-Object { [string]$_.Name })

    foreach ($orphan in @(
            @($access) + @($ntfs) |
            Where-Object { $shareNames -notcontains [string]$_.Name } |
            ForEach-Object { [string]$_.Name } |
            Select-Object -Unique
        )) {
        $Problems.Add(
            "SmbShares: permissions for share '$orphan' were dropped, " +
            'because that share is not in Shares'
        )
    }

    , @(
        foreach ($share in $shares) {
            $entry = [ordered]@{}

            foreach ($property in $share.PSObject.Properties) {
                $entry[$property.Name] = $property.Value
            }

            $shareAccess = @(
                $access | Where-Object { [string]$_.Name -eq [string]$share.Name }
            )

            if ($shareAccess.Count) {
                $entry.Access = @(
                    foreach ($item in $shareAccess) {
                        $copy = [ordered]@{}
                        foreach ($property in $item.PSObject.Properties) {
                            if ($property.Name -ne 'Name') {
                                $copy[$property.Name] = $property.Value
                            }
                        }
                        $copy
                    }
                )
            }

            $shareNtfs = @(
                $ntfs | Where-Object { [string]$_.Name -eq [string]$share.Name }
            ) | Select-Object -First 1

            if ($shareNtfs) {
                $entry.NTFS = [ordered]@{}
                foreach ($property in $shareNtfs.PSObject.Properties) {
                    if ($property.Name -ne 'Name') {
                        $entry.NTFS[$property.Name] = $property.Value
                    }
                }
            }

            [pscustomobject]$entry
        }
    )
}

function Test-OldShareLayoutHC {
    # The version-2 layout: an object, normally with Shares, Access and NTFS
    # lists; an empty object {} is converted to an empty list as well
    param($Data)

    $null -ne $Data -and $Data -isnot [array] -and $Data -isnot [string] -and
    @($Data.PSObject.Properties.Name | Where-Object { $_ -ne 'Comment' }).Count -eq
    @($Data.PSObject.Properties.Name | Where-Object {
            $_ -in @('Shares', 'Access', 'NTFS')
        }).Count
}

function Get-RootRelativePathHC {
    param([string]$Path)
    $prefix = $RootFolder.TrimEnd('\', '/') + '\'
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($prefix.Length) 
    }
    return $Path
}

function Copy-LegacyAssetHC {
    param([string]$Source, [string]$DestinationFolder)
    
    if (-not (Test-Path -LiteralPath $Source)) { 
        throw "Legacy asset '$Source' not found" 
    }
    
    $destination = Join-Path $DestinationFolder (Split-Path $Source -Leaf)
    
    if ([string]::Equals($Source, $destination, [StringComparison]::OrdinalIgnoreCase)) { 
        return Get-RootRelativePathHC $destination 
    }
    
    if (Test-Path -LiteralPath $destination) {
        if (
            (Test-Path -LiteralPath $Source -PathType Leaf) -and 
            (Test-Path -LiteralPath $destination -PathType Leaf) -and
            (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $destination).Hash
        ) {
            return Get-RootRelativePathHC $destination
        }
        throw "Asset destination '$destination' already exists with different contents; nothing overwritten"
    }

    $null = New-Item -Path $DestinationFolder -ItemType Directory -Force
    
    Copy-Item `
        -LiteralPath $Source `
        -Destination $destination `
        -Recurse -ErrorAction Stop
    
    return Get-RootRelativePathHC $destination
}

$RootFolder = [IO.Path]::GetFullPath($RootFolder)
$oldPath = Resolve-RootPathHC $OldConfigurationFile $RootFolder
$oldFile = Get-Item -LiteralPath $oldPath -ErrorAction Stop
$old = Read-SectionExampleHC $oldPath

#region Version 2: convert in place
if ($old.SchemaVersion -eq 3) {
    throw "'$oldPath' is already a version-3 configuration"
}

if ($old.SchemaVersion -eq 2) {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $backupPath = Join-Path $oldFile.DirectoryName ($oldFile.BaseName + '.v2.json')

    if (Test-Path -LiteralPath $backupPath) {
        throw "Backup '$backupPath' already exists"
    }

    $sharesData = $old.Items.SmbShares

    if ($sharesData -is [string]) {
        # A shared section file, converted once for every configuration
        $sharedPath = Resolve-RootPathHC $sharesData $RootFolder
        $sharedData = Read-SectionExampleHC $sharedPath

        if (Test-OldShareLayoutHC $sharedData) {
            $sharedFile = Get-Item -LiteralPath $sharedPath
            $sharedBackup = Join-Path $sharedFile.DirectoryName ($sharedFile.BaseName + '.v2.json')

            if (Test-Path -LiteralPath $sharedBackup) {
                throw "Backup '$sharedBackup' already exists"
            }

            $converted = ConvertTo-ShareListHC -OldShares $sharedData -Problems $problems
            Rename-Item -LiteralPath $sharedPath -NewName (Split-Path $sharedBackup -Leaf) -ErrorAction Stop
            [IO.File]::WriteAllText(
                $sharedPath,
                (ConvertTo-Json -InputObject $converted -Depth 20) + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding $false)
            )
            Write-Host "Converted shared section '$sharedPath'. Original: '$sharedBackup'."
        }
    }
    elseif (Test-OldShareLayoutHC $sharesData) {
        $old.Items.SmbShares = ConvertTo-ShareListHC -OldShares $sharesData -Problems $problems
    }

    Rename-Item -LiteralPath $oldPath -NewName (Split-Path $backupPath -Leaf) -ErrorAction Stop
    Write-ConfigurationHC -Configuration $old -Path $oldPath

    foreach ($problem in @(Test-ConfigurationHC (Read-ConfigurationHC $oldPath $RootFolder) $RootFolder)) {
        $problems.Add($problem)
    }

    foreach ($problem in $problems) {
        Write-Warning $problem
    }

    Write-Host "Converted to '$oldPath'. Validation problems: $($problems.Count). Original: '$backupPath'."

    return [pscustomobject]@{
        Path     = $oldPath
        Original = $backupPath
        Problems = $problems.ToArray()
    }
}
#endregion

if (-not $old.StartScript) {
    throw 'Expected a version-2 configuration or an old StartScript-format configuration.'
}
$outputFolder = Join-Path $RootFolder 'Configurations'
$outputPath = Join-Path $outputFolder $oldFile.Name
$backupPath = Join-Path $oldFile.DirectoryName ($oldFile.BaseName + '.v1.json')

if (Test-Path -LiteralPath $backupPath) {
    throw "Backup '$backupPath' already exists" 
}

if (
    (Test-Path -LiteralPath $outputPath) -and 
    -not [string]::Equals($outputPath, $oldPath, [StringComparison]::OrdinalIgnoreCase)
) {
    throw "Output '$outputPath' already exists"
}

$legacyRoot = Resolve-RootPathHC `
    $old.StartScript.SnapshotFolder `
(Join-Path $RootFolder 'Scripts\Invoke scripts')

$itemFiles = @{
    RegionalSettings = 'RegionalSettings.json' 
    UserAccounts     = 'UserAccounts.json' 
    UserGroups       = 'Groups.json'
    FirewallRules    = 'FirewallRules.json' 
    CreateFolders    = 'CreateFolders.json' 
    NetworkCards     = 'NetworkCards.json'
    NtpTimeServers   = 'ntpServers.json'
    RegistryKeys     = 'registryKeys.json' 
    CopyFilesFolders = 'CopyFilesFolders.json' 
    Software         = 'Software.json'
}

$order = @((Get-SnapshotScriptsHC).Keys)
foreach ($property in $old.StartScript.Snapshot.PSObject.Properties) {
    if ($property.Value -and $property.Name -notin $order) { 
        throw "Unknown old snapshot item '$($property.Name)'" 
    }
}

$items = [ordered]@{}
foreach ($name in $order) {
    if (-not $old.StartScript.Snapshot.$name) { continue }

    $folder = Join-Path $legacyRoot $name
    $data = $null
    
    if ($itemFiles.ContainsKey($name)) { 
        $data = Read-SectionExampleHC (Join-Path $folder $itemFiles[$name]) 
    }

    switch ($name) {
        'Software' {
            $data = $data.SoftwarePackages
            foreach ($package in $data.Install) {
                $source = Resolve-RootPathHC $package.ExecutablePath $folder
                
                if (
                    $source.StartsWith(($folder.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
                ) {
                    $package.ExecutablePath = Copy-LegacyAssetHC $source (Join-Path $RootFolder 'Software')
                }
                else { 
                    $package.ExecutablePath = Get-RootRelativePathHC $source 
                }
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
            $data = @(
                foreach (
                    $file in 
                    Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File | Sort-Object Name
                ) {
                    [pscustomobject]@{ 
                        Path = Copy-LegacyAssetHC $file.FullName (Join-Path $RootFolder "Files\$($oldFile.BaseName)") 
                    }
                }
            )
        }
        'ScheduledTasks' {
            $data = @(
                foreach (
                    $file in
                    Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File | Where-Object { $_.Name -notlike '* - Definition.xml' }
                ) {
                    $task = Import-Clixml -LiteralPath $file.FullName
                    $enabled = if ($null -ne $task.Settings.Enabled) { 
                        [bool]$task.Settings.Enabled 
                    }
                    else { 
                        $task.State -ne 'Disabled' 
                    }

                    [pscustomobject]@{
                        TaskName = $task.TaskName 
                        TaskPath = $task.TaskPath 
                        Enabled  = $enabled
                        Xml      = [IO.File]::ReadAllText((Join-Path $folder ($file.BaseName + ' - Definition.xml')))
                    }
                }
            )
        }
        'SmbShares' {
            $shareData = Read-SectionExampleHC (Join-Path $folder 'SmbShares.json')
            $accessData = Read-SectionExampleHC (Join-Path $folder 'SmbSharesAccess.json')

            $oldShares = [pscustomobject]@{
                Shares = @($shareData)
                Access = @($accessData)
                NTFS   = @()
            }

            if (Test-Path -LiteralPath (Join-Path $folder 'NTFS')) {
                $oldShares.NTFS = @(
                    foreach (
                        $file in 
                        Get-ChildItem -LiteralPath (Join-Path $folder 'NTFS') -Filter '*.json' -File
                    ) {
                        $permissions = Read-SectionExampleHC $file.FullName
                        $permissions | Add-Member `
                            -NotePropertyName Name `
                            -NotePropertyValue $file.BaseName `
                            -Force
                        $permissions
                    }
                )
            }

            $shareProblems = New-Object 'System.Collections.Generic.List[string]'
            $data = ConvertTo-ShareListHC -OldShares $oldShares -Problems $shareProblems
            foreach ($problem in $shareProblems) {
                Write-Warning $problem
            }
        }
        { $_ -in @(
                'UserAccounts', 'UserGroups', 'FirewallRules', 'NetworkCards')
        } {
            $data = @($data) 
        }
    }
    Convert-CommentsHC $data
    $items[$name] = $data
}

if ($items.Count -eq 0) { 
    throw 'The old configuration has no enabled items.' 
}

$document = [ordered]@{
    SchemaVersion = 3
    Description   = 'Converted from ' + $oldFile.Name
    Settings      = [ordered]@{
        RebootComputer      = [bool]$old.StartScript.RebootComputer
        OpenReportInBrowser = if (
            $null -ne $old.StartScript.OpenReportInBrowser
        ) {
            [bool]$old.StartScript.OpenReportInBrowser 
        }
        else { 
            $true 
        }
        RunElevated         = [bool]$old.RunInElevatedPowerShellSession
    }
    Items         = $items
}

$null = New-Item -Path $outputFolder -ItemType Directory -Force

Rename-Item -LiteralPath $oldPath -NewName (Split-Path $backupPath -Leaf) -ErrorAction Stop

Write-ConfigurationHC -Configuration $document -Path $outputPath
$problems = @(Test-ConfigurationHC (Read-ConfigurationHC $outputPath $RootFolder) $RootFolder)

foreach ($problem in $problems) { 
    Write-Warning $problem 
}

Write-Host "Converted to '$outputPath'. Validation problems: $($problems.Count). Original: '$backupPath'."

[pscustomobject]@{ 
    Path     = $outputPath
    Original = $backupPath
    Problems = $problems 
}