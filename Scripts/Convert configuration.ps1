#Requires -Version 5.1
<#
.SYNOPSIS
    Convert one older configuration to version 3 without deleting its data.
.DESCRIPTION
    Convert a version 1 configuration, the old StartScript format with a
    snapshot folder, to version 3. The original is renamed to name.v1.json
    and the result is written to Configurations\<name>.json.

    SmbShares become one entry per share with its own Access and NTFS,
    Software.Remove becomes a list of objects, { "DisplayName": "name" },
    and each network card becomes
    { "FindBy": { "Description": ... }, "Change": { ... } }.
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
    # Rename the version 1 '?' comment property to Comment, recursively
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

            $params = @{
                NotePropertyName  = 'Comment'
                NotePropertyValue = $comment
                Force             = $true
            }
            $Value | Add-Member @params
        }
        foreach ($property in $Value.PSObject.Properties) {
            Convert-CommentsHC $property.Value
        }
    }
}

function ConvertTo-ShareListHC {
    <#
    .SYNOPSIS
        Turn the version 1 share, access and NTFS lists into one entry per
        share.
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
                $access | Where-Object {
                    [string]$_.Name -eq [string]$share.Name
                }
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
                $ntfs | Where-Object {
                    [string]$_.Name -eq [string]$share.Name
                }
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

function Test-OldSoftwareLayoutHC {
    # Software with application names in Remove instead of objects
    param($Data)

    $null -ne $Data -and $Data -isnot [array] -and $Data -isnot [string] -and
    @($Data.Remove | Where-Object { $_ -is [string] }).Count -gt 0
}

function ConvertTo-SoftwareHC {
    # Each name in Remove becomes { "DisplayName": "name" }
    param($Data)

    $Data.Remove = @(
        foreach ($entry in @($Data.Remove | Where-Object { $null -ne $_ })) {
            if ($entry -is [string]) {
                [pscustomobject]@{ DisplayName = $entry }
            }
            else {
                $entry
            }
        }
    )

    $Data
}

function ConvertTo-NetworkCardHC {
    # Version 1 card settings become FindBy (by description) and Change
    param($Card)

    $change = [ordered]@{}

    foreach ($names in @(
            @('NetworkCardName', 'NewName'),
            @('NetworkCategory', 'NetworkCategory'),
            @('NetworkCardDnsSuffix', 'DnsSuffix')
        )) {
        if ($Card.PSObject.Properties[$names[0]]) {
            $change[$names[1]] = $Card.($names[0])
        }
    }

    $entry = [ordered]@{
        FindBy = [ordered]@{ Description = $Card.NetworkCardDescription }
        Change = $change
    }

    if ($Card.PSObject.Properties['?']) {
        $entry.Comment = [string]$Card.'?'
    }

    [pscustomobject]$entry
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
    # Copy a file or folder from the old snapshot folder to its new place
    # and return the path relative to the root folder
    param([string]$Source, [string]$DestinationFolder)

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Legacy asset '$Source' not found"
    }

    $destination = Join-Path $DestinationFolder (Split-Path $Source -Leaf)

    if (
        [string]::Equals(
            $Source, $destination, [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Write-Verbose "Asset '$Source' already in place"
        return Get-RootRelativePathHC $destination
    }

    if (Test-Path -LiteralPath $destination) {
        if (
            (Test-Path -LiteralPath $Source -PathType Leaf) -and
            (Test-Path -LiteralPath $destination -PathType Leaf) -and
            (Get-FileHash -LiteralPath $Source).Hash -eq
            (Get-FileHash -LiteralPath $destination).Hash
        ) {
            Write-Verbose "Asset '$destination' exists with same contents"
            return Get-RootRelativePathHC $destination
        }
        throw (
            "Asset destination '$destination' already exists with " +
            'different contents; nothing overwritten'
        )
    }

    $null = New-Item -Path $DestinationFolder -ItemType Directory -Force

    Write-Verbose "Copy asset '$Source' to '$destination'"

    $params = @{
        LiteralPath = $Source
        Destination = $destination
        Recurse     = $true
        ErrorAction = 'Stop'
    }
    Copy-Item @params

    return Get-RootRelativePathHC $destination
}

$RootFolder = [IO.Path]::GetFullPath($RootFolder)
$oldPath = Resolve-RootPathHC $OldConfigurationFile $RootFolder
$oldFile = Get-Item -LiteralPath $oldPath -ErrorAction Stop

Write-Verbose "Convert configuration '$oldPath'"

$old = Read-SectionExampleHC $oldPath

if ($old.SchemaVersion -eq 3) {
    throw "'$oldPath' is already a version-3 configuration"
}

if (-not $old.StartScript) {
    throw 'Expected an old StartScript-format (version 1) configuration.'
}

$outputFolder = Join-Path $RootFolder 'Configurations'
$outputPath = Join-Path $outputFolder $oldFile.Name
$backupPath = Join-Path $oldFile.DirectoryName (
    $oldFile.BaseName + '.v1.json'
)

if (Test-Path -LiteralPath $backupPath) {
    throw "Backup '$backupPath' already exists"
}

if (
    (Test-Path -LiteralPath $outputPath) -and
    -not [string]::Equals(
        $outputPath, $oldPath, [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "Output '$outputPath' already exists"
}

$legacyRoot = Resolve-RootPathHC $old.StartScript.SnapshotFolder (
    Join-Path $RootFolder 'Scripts\Invoke scripts'
)

Write-Verbose "Old snapshot folder '$legacyRoot'"

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
    if (-not $old.StartScript.Snapshot.$name) {
        Write-Verbose "Item '$name': not enabled, skip"
        continue
    }

    Write-Verbose "Item '$name': convert"

    $folder = Join-Path $legacyRoot $name
    $data = $null

    if ($itemFiles.ContainsKey($name)) {
        $data = Read-SectionExampleHC (Join-Path $folder $itemFiles[$name])
    }

    switch ($name) {
        'Software' {
            $data = $data.SoftwarePackages
            if (Test-OldSoftwareLayoutHC $data) {
                Write-Verbose 'Software: convert old Remove list'
                $data = ConvertTo-SoftwareHC $data
            }
            foreach ($package in $data.Install) {
                $source = Resolve-RootPathHC $package.ExecutablePath $folder

                if (
                    $source.StartsWith(
                        ($folder.TrimEnd('\') + '\'),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $package.ExecutablePath = Copy-LegacyAssetHC $source (
                        Join-Path $RootFolder 'Software'
                    )
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

                $entry.From = Copy-LegacyAssetHC $source (
                    Join-Path $RootFolder "Files\$($oldFile.BaseName)"
                )
            }
        }
        { $_ -in @('StartCustomScriptsBefore', 'StartCustomScriptsAfter') } {
            $data = @(
                foreach (
                    $file in
                    Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File |
                    Sort-Object Name
                ) {
                    [pscustomobject]@{
                        Path = Copy-LegacyAssetHC $file.FullName (
                            Join-Path $RootFolder "Files\$($oldFile.BaseName)"
                        )
                    }
                }
            )
        }
        'ScheduledTasks' {
            $data = @(
                foreach (
                    $file in
                    Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File |
                    Where-Object { $_.Name -notlike '* - Definition.xml' }
                ) {
                    $task = Import-Clixml -LiteralPath $file.FullName
                    $enabled = if ($null -ne $task.Settings.Enabled) {
                        [bool]$task.Settings.Enabled
                    }
                    else {
                        $task.State -ne 'Disabled'
                    }

                    $xmlPath = Join-Path $folder (
                        $file.BaseName + ' - Definition.xml'
                    )

                    [pscustomobject]@{
                        TaskName = $task.TaskName
                        TaskPath = $task.TaskPath
                        Enabled  = $enabled
                        Xml      = [IO.File]::ReadAllText($xmlPath)
                    }
                }
            )
        }
        'SmbShares' {
            $shareData = Read-SectionExampleHC (
                Join-Path $folder 'SmbShares.json'
            )
            $accessData = Read-SectionExampleHC (
                Join-Path $folder 'SmbSharesAccess.json'
            )

            $oldShares = [pscustomobject]@{
                Shares = @($shareData)
                Access = @($accessData)
                NTFS   = @()
            }

            $ntfsFolder = Join-Path $folder 'NTFS'

            if (Test-Path -LiteralPath $ntfsFolder) {
                $childParams = @{
                    LiteralPath = $ntfsFolder
                    Filter      = '*.json'
                    File        = $true
                }
                $oldShares.NTFS = @(
                    foreach ($file in Get-ChildItem @childParams) {
                        $permissions = Read-SectionExampleHC $file.FullName

                        $params = @{
                            NotePropertyName  = 'Name'
                            NotePropertyValue = $file.BaseName
                            Force             = $true
                        }
                        $permissions | Add-Member @params
                        $permissions
                    }
                )
            }

            $shareProblems = New-Object (
                'System.Collections.Generic.List[string]'
            )
            $params = @{
                OldShares = $oldShares
                Problems  = $shareProblems
            }
            $data = ConvertTo-ShareListHC @params
            foreach ($problem in $shareProblems) {
                Write-Warning $problem
            }
        }
        { $_ -in @(
                'UserAccounts', 'UserGroups', 'FirewallRules')
        } {
            $data = @($data)
        }
        'NetworkCards' {
            $data = @(
                foreach ($card in @($data | Where-Object { $null -ne $_ })) {
                    ConvertTo-NetworkCardHC $card
                }
            )
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

Write-Verbose "Rename original to '$backupPath'"

$params = @{
    LiteralPath = $oldPath
    NewName     = Split-Path $backupPath -Leaf
    ErrorAction = 'Stop'
}
Rename-Item @params

Write-Verbose "Write configuration '$outputPath'"

Write-ConfigurationHC -Configuration $document -Path $outputPath
$problems = @(
    Test-ConfigurationHC (
        Read-ConfigurationHC $outputPath $RootFolder
    ) $RootFolder
)

foreach ($problem in $problems) {
    Write-Warning $problem
}

Write-Host (
    "Converted to '$outputPath'. " +
    "Validation problems: $($problems.Count). Original: '$backupPath'."
)

[pscustomobject]@{
    Path     = $outputPath
    Original = $backupPath
    Problems = $problems
}