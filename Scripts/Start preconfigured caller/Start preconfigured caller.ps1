<#
    .SYNOPSIS
        Execute 'Start-Script.ps1' with the correct arguments.

    .DESCRIPTION
        This script serves as a launcher script for ease of use. 

        Once the shortcut in the parent folder is clicked this script will
        display a list of pre-configured arguments to use for calling 
        'Start-Script.ps1'.
        
        Each .JSON file in the folder 'Preconfigured callers' represents a set
        of pre-configured arguments to call 'Start-Script.ps1'. Many different
        .JSON files can be created for many different occasions of restoring
        snapshots.

        This allows the user to leave with a USB stick full of ready to use
        configurations to go on site and restore a specific snapshot on a 
        machine.

    .PARAMETER StartScript
        Path to the script that will execute the different types of snapshots.

    .PARAMETER PreconfiguredCallersFolder
        Folder where the .JSON files are stored. Each file represents a set of
        arguments to be used with 'Start-Script.ps1'.
#>

Param (
    [String]$StartScript = '.\Start-Script.ps1',
    [String]$PreconfiguredCallersFolder = '.\Preconfigured callers',
    [String]$PreconfiguredCallerFilePath
)

Begin {
    Function ConvertTo-HashtableHC {
        <#
        .SYNOPSIS
            Convert PS Objects to hashtables

        .DESCRIPTION
            Only hashtables can be used for splatting arguments to a function
            or script file. Converting PS objects created by ConvertFrom-Json
            fixed this.
        #>
        Param (
            [Parameter(Mandatory)]
            $InputObject
        )
    
        Process {
            if ($null -eq $InputObject) { return $null }
    
            if (
                ($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isNot [string])
            ) {
                $collection = @(
                    foreach ($object in $InputObject) { 
                        ConvertTo-HashtableHC $object 
                    }
                )
                Write-Output -NoEnumerate $collection
            }
            elseif ($InputObject -is [PSObject]) {
                $hash = [Ordered]@{}
                foreach ($property in $InputObject.PSObject.Properties) {
                    $hash[$property.Name] = ConvertTo-HashtableHC $property.Value
                }
                $hash
            }
            else {
                $InputObject
            }
        }
    }
    Function Invoke-ScriptHC {
        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [HashTable]$Arguments
        )

        Write-Debug "Invoke script '$Path'"
        & $Path @Arguments
    }
    Function Test-IsStartedElevatedHC {
        <#
        .SYNOPSIS
            Check if the script is started in elevated mode
        
        .DESCRIPTION
            Some PowerShell scripts required to be run as administrator 
            and in elevated mode to function property.
        #>
        
        Try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
            $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        Catch {
            throw "Failed to determine if the script is started in elevated mode: $_"
        }
    }

    try {
        $params = @{
            Path        = $StartScript
            ErrorAction = 'Ignore'
        }
        $startScriptPath = Convert-Path @params

        #region Test start script
        If (
            (-not $startScriptPath) -or
            (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf))
        ) {
            throw "Start script '$StartScript' not found"
        }
        #endregion

        if ($PreconfiguredCallerFilePath) {
            #region Test folder and file available
            If (
                -not (Test-Path -LiteralPath $PreconfiguredCallerFilePath -PathType Leaf -ErrorAction Ignore)
            ) {
                throw "Pre-configured caller file '$PreconfiguredCallerFilePath' not found"
            }
            #endregion
        }
        else {
            $params.Path = $PreconfiguredCallersFolder
            $preconfiguredCallersFolderPath = Convert-Path @params

            #region Test pre-configured callers folder
            If (
                (-not $preconfiguredCallersFolderPath) -or
                (-not (Test-Path -LiteralPath $preconfiguredCallersFolderPath -PathType Container))
            ) {
                throw "Preconfigured callers folder '$PreconfiguredCallersFolder' not found"
            }
            If (
                (Get-ChildItem -Path $preconfiguredCallersFolderPath -File -Recurse -Filter '*.json' | Measure-Object).Count -eq 0
            ) {
                throw "No .JSON file found in folder '$preconfiguredCallersFolderPath'. Please create a pre-configuration file first."
            }
            #endregion
        }

        #region Get Start-Script.ps1 parameters
        $psBuildInParameters = 
        ([System.Management.Automation.PSCmdlet]::CommonParameters) +
        ([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        
        $startScriptParameters = 
        (Get-Command $startScriptPath).Parameters.GetEnumerator() | 
        Where-Object { $psBuildInParameters -notContains $_.Key }
        #endregion
    }
    catch {
        Write-Warning 'Failed to start the pre-configured caller script:'
        Write-Warning $_
        Start-Sleep -Seconds 20
        Exit
    }
}

Process {
    try {
        if (-not $PreconfiguredCallerFilePath) {
            #region Get all pre-configured .JSON files
            $getParams = @{
                LiteralPath = $preconfiguredCallersFolderPath
                File        = $true
                Filter      = '*.json'
            }
            $jsonFiles = Get-ChildItem @getParams

            if (-not $jsonFiles) {
                throw "No pre-configured .JSON caller files found in folder '$preconfiguredCallersFolderPath'"
            }
            #endregion

            #region Display GUI to select the correct .JSON file
            $outParams = @{
                Title      = 'Select the configuration you want to execute:'
                OutputMode = 'Single'
            }
            $titleBarName = 'Pre-configuration file name'
            $selectedJsonFile = $jsonFiles | Select-Object @{
                Name       = $titleBarName; 
                Expression = { $_.BaseName } 
            } | 
            Out-GridView @outParams

            if (-not $selectedJsonFile) {
                throw 'No pre-configuration file selected'
            }

            $jsonFilePath = $jsonFiles | Where-Object {
                $_.BaseName -eq $selectedJsonFile.$titleBarName 
            } | Select-Object -ExpandProperty FullName
            #endregion
        }
        else {
            $jsonFilePath = $PreconfiguredCallerFilePath
        }

        #region Import .JSON file
        try {
            $jsonFile = Get-Content -Path $jsonFilePath -Raw | 
            ConvertFrom-Json -ErrorAction Stop
            Write-Verbose "User parameters '$jsonFile'"
        }
        catch {
            throw "Parameter file '$jsonFilePath' is invalid: $_"
        }
        #endregion
   
        #region Test Start-Script arguments
        if (-not $jsonFile.StartScript) {
            "The parameter 'StartScript' is missing in file '$jsonFilePath'."
        }

        $jsonFile.StartScript.PSObject.Properties.Name | Where-Object {
            $startScriptParameters.Key -notContains $_
        } | ForEach-Object {
            $invalidParameter = $_
            throw "The parameter '$invalidParameter' in file '$jsonFilePath' is not accepted by script '$startScriptPath'."
        }
        #endregion
            
        if (
            ($jsonFile.RunInElevatedPowerShellSession) -and
            (-not (Test-IsStartedElevatedHC))
        ) {
            # relaunch current script as an elevated process
            Write-Host 'Please accept the prompt to start the script in elevated mode'
      
            $startParams = @{
                FilePath     = 'powershell.exe'
                ArgumentList = '-Command "& ''{0}'' -PreconfiguredCaller ''{1}''"' -f 
                $MyInvocation.MyCommand.Path, 
                $PreconfiguredCallerFilePath
                Verb         = 'RunAs'
            }
            Start-Process @startParams
            Exit
        }
    
        $invokeParams = @{
            Path      = $startScriptPath
            Arguments = ConvertTo-HashtableHC $jsonFile.StartScript
        }
        Invoke-ScriptHC @invokeParams
        #endregion
    }
    catch {
        Write-Warning 'Failed to start the pre-configured caller script:'
        Write-Warning $_
        Start-Sleep -Seconds 20
        Exit
    }
}