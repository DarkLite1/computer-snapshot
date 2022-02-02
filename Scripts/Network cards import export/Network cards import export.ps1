<#
    .SYNOPSIS
        Configure network cards: rename, connection profile, ...

    .DESCRIPTION
        When action is 'Export' the script will create an example file that can 
        be used with action set to 'Import'.

        When action is 'Import' the import file is read and the network cards 
        will be renamed and or given the correct connection profile (Public, 
        Private, ...)
        
        The import file needs to be explicit and contain the a part of the 
        description to identify the correct network card. Usually the 
        description is the name of the manufacturer:

        [
            {
                "NetworkCardName"        = "LAN FABRIEK",
                "NetworkCardDescription" = "Broadcom",
                "NetworkCategory"        = $null
            },
            {
                "NetworkCardName"        = "LAN KANTOOR",
                "NetworkCardDescription" = "Intel",
                "NetworkCategory"        = "Private"
            }
        ]

        When a field contains the value NULL it is simply ignored and nothing is
        changed.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER FileName
        The file containing the network card's configuration

    .PARAMETER DataFolder
        Folder where the export or import file can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\copy'
            FileName   = 'NetworkCards.json'
        }
        & 'C:\script.ps1' @params

        Create the example file 'C:\copy\NetworkCards.json' that can be used 
        later on with action 'Import'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\copy'
            FileName   = 'NetworkCards.json'
        }
        & 'C:\script.ps1' @params

        Read the file 'C:\copy\NetworkCards.json' and rename the network cards
        matching the description and set the connection profile.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'NetworkCards.json'
)

Begin {
    Function Get-FullPathHC {
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )

        if ($Path -like '*:*') {
            $Path
        }
        else {
            Join-Path -Path $DataFolder -ChildPath $Path
        }
    }

    Try {
        $ExportFile = Join-Path -Path $DataFolder -ChildPath $FileName

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
                throw "Import file '$ExportFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action failed: $_"
    }
}

Process {
    Try {
        $netAdapters = Get-NetAdapter
        $netConnectionProfiles = Get-NetConnectionProfile

        If ($Action -eq 'Export') {
            #region Export example config file
            $cardsToExport = foreach ($card in $netAdapters) {
                $NetworkCategory = ($netConnectionProfiles | Where-Object { 
                    $_.InterfaceAlias -eq $card.name
                }).NetworkCategory
                @{
                    NetworkCardName        = $card.Name
                    NetworkCardDescription = $card.InterfaceDescription
                    NetworkCategory        = [String]$NetworkCategory
                }
            }
  
            if (-not $cardsToExport) {
                Write-Verbose 'No network cards found, create template'
                $cardsToExport = @(
                    @{
                        NetworkCardName        = 'LAN FACTORY'
                        NetworkCardDescription = 'Broadcom'
                        NetworkCategory        = $null
                    },
                    @{
                        NetworkCardName        = 'LAN OFFICE'
                        NetworkCardDescription = 'Intel'
                        NetworkCategory        = 'Private'
                    }
                )
                Write-Output 'No network cards found, template created'
            } 
            else {
                Write-Output "Found $($cardsToExport.Count) network cards:"
                $cardsToExport | ForEach-Object {
                    Write-Output "Name '$($_.NetworkCardName)' description '$($_.NetworkCardDescription)' profile '$($_.NetworkCategory)'"
                }
            }
            
            Write-Verbose "Create example config file '$ExportFile'"

            $outParams = @{
                LiteralPath = $ExportFile 
                Encoding    = 'UTF8'
            }
            $cardsToExport | ConvertTo-Json | Out-File @outParams
 
            Write-Output "Created example config file '$ExportFile'"
            #endregion

        }
        else {
            $itemsToCopy = Get-Content -Path $ExportFile -Raw | ConvertFrom-Json

            foreach ($i in $itemsToCopy) {
                try {
                    if (-not ($from = $i.From)) {
                        throw "The field 'From' is required"
                    }
                    if (-not ($to = $i.To)) {
                        throw "The field 'To' is required"
                    }
                    $from = Get-FullPathHC -Path $from
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
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}