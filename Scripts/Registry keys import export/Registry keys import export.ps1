<#
    .SYNOPSIS
        Create registry keys.

    .DESCRIPTION
        Read the registry keys from an input file on one machine and set the 
        registry keys from the same file on another machine.
        
    .PARAMETER Action
        When action is 'Export' a template file is created that can be edited 
        by the user to contain the required registry keys. 
        When action is 'Import' the registry keys in the import file will be 
        created or updated on the current machine. 

    .PARAMETER DataFolder
        Folder where the file can be found that contains the registry keys.

    .PARAMETER RegistryKeysFileName
        File containing the registry keys.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$RegistryKeysFileName = 'registryKeys.json'
)

Begin {
    $scriptBlock = {
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [String]$Name,
            [Parameter(Mandatory)]
            [String]$Value,
            [Parameter(Mandatory)]
            [String]$Type
        )
        try {
            try {
                $idString = "Registry path '$Path' key name '$Name' value '$Value' type '$Type'"
                Write-Verbose $idString
            
                $newParams = @{
                    Path         = $Path
                    Name         = $Name
                    Value        = $Value
                    PropertyType = $Type
                    Force        = $true
                    ErrorAction  = 'Stop'
                }
                $getParams = @{
                    Path        = $Path
                    Name        = $Name
                    ErrorAction = 'Stop'
                }
                $currentValue = (Get-ItemProperty @getParams).($Name)

                if ($currentValue -ne $Value) {
                    Write-Verbose "Update old value '$currentValue' with new value '$Value'"
                    $null = New-ItemProperty @newParams
                    Write-Output "$idString not correct. Updated old value '$currentValue' with new value '$Value'."
                }
                else {
                    Write-Verbose 'Registry key correct'
                    Write-Output "$idString correct. Nothing to update."
                }
            }
            catch [System.Management.Automation.PSArgumentException] {
                Write-Verbose 'Add key name and value on existing path'
                $null = New-ItemProperty @newParams
                Write-Output "$idString. Created key name and value on existing path."
            }
            catch [System.Management.Automation.ItemNotFoundException] {
                Write-Verbose 'Add new registry key'
                $null = New-Item -Path $Path -ErrorAction Stop
                $null = New-ItemProperty @newParams
                Write-Output "$idString did not exist. Created new registry key."
            }
        }
        catch {
            Write-Error "Failed to set registry path '$Path' with key name '$Name' to value '$Value' with type '$Type': $_"
            $Error.RemoveAt(1)
        }
    }

    Try {
        $RegistryKeysFile = Join-Path -Path $DataFolder -ChildPath $RegistryKeysFileName

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
            If (-not (Test-Path -LiteralPath $RegistryKeysFile -PathType Leaf)) {
                throw "Registry keys file '$RegistryKeysFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action registry keys failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            #region Create example config file
            Write-Verbose "Create example config file '$ExportFile'"
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Example.json'
                Destination = $RegistryKeysFile
            }
            Copy-Item @params
            Write-Output "Created example registry keys file '$RegistryKeysFile'"
            #endregion
        }
        else {            
            Write-Verbose "Import registry keys from file '$RegistryKeysFile'"
            $registryKeys = Get-Content -LiteralPath $RegistryKeysFile -Encoding UTF8 -Raw | 
            ConvertFrom-Json -EA Stop
     
            foreach ($key in $registryKeys.RunAsCurrentUser.RegistryKeys) {
                & $scriptBlock -Path $key.Path -Name $key.Name -Value $key.Value -Type $key.Type
            }
        }
    }
    Catch {
        throw "$Action registry keys failed: $_"
    }
}