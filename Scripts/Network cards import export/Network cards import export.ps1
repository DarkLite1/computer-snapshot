<#
    .SYNOPSIS
        Configure network cards: rename, connection profile, ...

    .DESCRIPTION
        When action is 'Export' the script will create an example file that can 
        be used with action set to 'Import'.

        When action is 'Import' the import file is read and the network cards 
        will be renamed and or given the correct connection profile (Public, 
        Private, ...).
        
        Identifying the correct network card to rename is done by using the 
        NetworkCardDescription field. Identifying the correct network card to 
        change the category is done by using the NetworkCardName. 

        Renaming a card is done first, so if you need to rename and change the
        category only the NetworkCardDescription is used to identify the 
        correct network card. 

        The field NetworkCardDescription usually contains the name of the 
        manufacturer. When querying we use wildcards so the complete 
        description is not required.

        [
            {
                "NetworkCardName"        = "LAN FACTORY",
                "NetworkCardDescription" = "Broadcom",
                "NetworkCategory"        = null
            },
            {
                "NetworkCardName"        = "LAN OFFICE",
                "NetworkCardDescription" = "Intel",
                "NetworkCategory"        = "Private"
            }
        ]

        When a field contains the value NULL or is empty it will be ignored. 

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
            DataFolder = 'C:\folder'
            FileName   = 'NetworkCards.json'
        }
        & 'C:\script.ps1' @params

        Create the example file 'C:\folder\NetworkCards.json' that can be used 
        later on with action 'Import'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\folder'
            FileName   = 'NetworkCards.json'
        }
        & 'C:\script.ps1' @params

        Read the file 'C:\folder\NetworkCards.json' and rename the network cards
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
        $dnsClients = Get-DnsClient

        If ($Action -eq 'Export') {
            #region Export example config file
            $cardsToExport = foreach ($adapter in $netAdapters) {
                $NetworkCategory = ($netConnectionProfiles | Where-Object { 
                        $_.InterfaceAlias -eq $adapter.name
                    }).NetworkCategory
                @{
                    NetworkCardName        = $adapter.Name
                    NetworkCardDescription = $adapter.InterfaceDescription
                    NetworkCategory        = [String]$NetworkCategory
                    NetworkCardDnsSuffix   = ($dnsClients | Where-Object {
                            $_.InterfaceIndex -eq $adapter.InterfaceIndex
                        }).ConnectionSpecificSuffix
                }
            }
  
            if (-not $cardsToExport) {
                #region Create example config file
                Write-Verbose 'No network cards found, create template'
                $getParams = @{
                    Path     = Join-Path $PSScriptRoot 'Example.json'
                    Encoding = 'UTF8'
                    Raw      = $true
                }
                $cardsToExport = Get-Content @getParams | 
                ConvertFrom-Json -EA Stop
                #endregion
            } 
            else {
                Write-Output "Found $($cardsToExport.Count) network cards:"
                $cardsToExport | ForEach-Object {
                    $M = "Name '$($_.NetworkCardName)' description '$($_.NetworkCardDescription)' network profile '$($_.NetworkCategory)'"
                    Write-Verbose $M; Write-Output $M
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
            $NetworkCards = (Get-Content -Path $ExportFile -Raw) | 
            ConvertFrom-Json
            
            #region Test required fields
            $NetworkCards | ForEach-Object {
                if ($_.PSobject.Properties.Name -notContains "NetworkCardName") {
                    throw "The field 'NetworkCardName' is required"
                }
                if (-not $_.NetworkCardDescription) {
                    # cannot be blank like the others
                    throw "The field 'NetworkCardDescription' is required"
                }
                if ($_.PSobject.Properties.Name -notContains "NetworkCategory") {
                    throw "The field 'NetworkCategory' is required"
                }
            }
            #endregion

            foreach ($card in $NetworkCards) {
                foreach (
                    $adapter in 
                    $netAdapters | Where-Object { 
                        ($_.InterfaceDescription -like "*$($card.NetworkCardDescription)*")
                    }
                ) {
                    #region Rename network card
                    if (
                        ($card.NetworkCardName) -and
                        ($adapter.Name -ne $card.NetworkCardName)
                    ) {
                        $renameParams = @{
                            Name    = $adapter.Name 
                            NewName = $card.NetworkCardName
                        }
                        Rename-NetAdapter @renameParams

                        Write-Output "Renamed network card with description '$($adapter.InterfaceDescription)' from '$($adapter.Name)' to '$($card.NetworkCardName)'"
                    }
                    #endregion

                    #region Set DNS suffix
                    $dnsClient = $dnsClients | Where-Object {
                        $_.InterfaceIndex -eq $adapter.InterfaceIndex
                    }
                    if (
                        ($card.NetworkCardDnsSuffix) -and
                        ($dnsClient.ConnectionSpecificSuffix -ne $card.NetworkCardDnsSuffix)
                    ) {
                        $setDnsParams = @{
                            InterfaceIndex           = $adapter.InterfaceIndex
                            ConnectionSpecificSuffix = $card.NetworkCardDnsSuffix
                        }
                        Set-DnsClient @setDnsParams

                        Write-Output "Changed DNS suffix for network card with id '$($adapter.InterfaceIndex)' and description '$($adapter.InterfaceDescription)' from '$($dnsClient.ConnectionSpecificSuffix)' to '$($card.NetworkCardDnsSuffix)'"
                    }
                    #endregion
                }
            
                #region Set network category
                foreach (
                    $profile in 
                    $netConnectionProfiles | Where-Object {
                        ($card.NetworkCategory) -and
                        ($_.InterfaceAlias -eq $card.NetworkCardName) -and
                        ($_.NetworkCategory -ne $card.NetworkCategory) 
                    }
                ) {
                    $setNetConnectionParams = @{
                        InterfaceIndex  = $profile.InterfaceIndex 
                        NetworkCategory = $card.NetworkCategory
                    }
                    Set-NetConnectionProfile @setNetConnectionParams

                    $M = "Changed network category on card '$($card.NetworkCardName)' from '$($profile.NetworkCategory)' to '$($card.NetworkCategory)'"
                    Write-Verbose $M; Write-Output $M
                }
                #endregion
            }
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}