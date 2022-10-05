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

    .PARAMETER ConfigurationsFolder
        Folder where the .JSON files are stored. Each file represents a set of
        arguments to be used with 'Start-Script.ps1'.

    .PARAMETER NoConfirmQuestion
        When a configuration file is selected a question is asked to make sure
        the user selected the correct file before executing it. When using this
        switch no question is asked.
#>

Param (
    [String]$StartScript = '.\Start-Script.ps1',
    [String]$ConfigurationsFolder = '.\Configurations',
    [String]$ConfigurationFile,
    [Switch]$NoConfirmQuestion
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
        #region ASCI art
        Write-Host  '
        ________        .__        __     .__                             .__                  
        \_____  \  __ __|__| ____ |  | __ |  | _____   __ __  ____   ____ |  |__   ___________ 
         /  / \  \|  |  \  |/ ___\|  |/ / |  | \__  \ |  |  \/    \_/ ___\|  |  \_/ __ \_  __ \
        /   \_/.  \  |  /  \  \___|    <  |  |__/ __ \|  |  /   |  \  \___|   Y  \  ___/|  | \/
        \_____\ \_/____/|__|\___  >__|_ \ |____(____  /____/|___|  /\___  >___|  /\___  >__|   
               \__>             \/     \/           \/           \/     \/     \/     \/       
        ' -ForegroundColor Cyan
        
        
        Write-Host (
            "{0} - {1} - {2}`r`n" -f
            (Get-Date).ToString('dddd dd/MM/yyyy HH:mm'),
            $env:USERNAME, 
            [System.Net.Dns]::GetHostEntry([string]$env:computername).HostName
        ) -ForegroundColor Gray
        #endregion

        #region Get start script path
        $params = @{
            Path        = $StartScript
            ErrorAction = 'Ignore'
        }
        $startScriptPath = Convert-Path @params
        #endregion

        #region Test start script
        If (
            (-not $startScriptPath) -or
            (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf))
        ) {
            throw "Start script '$StartScript' not found"
        }
        #endregion

        if ($ConfigurationFile) {
            #region Get configuration file path
            $params = @{
                Path        = $ConfigurationFile
                ErrorAction = 'Ignore'
            }
            $ConfigurationFilePath = Convert-Path @params
            #endregion

            #region Test start script
            If (
                (-not $ConfigurationFilePath) -or
                (-not (Test-Path -LiteralPath $ConfigurationFilePath -PathType Leaf))
            ) {
                throw "Configuration file '$ConfigurationFile' not found"
            }
            #endregion
        }
        else {
            $params.Path = $ConfigurationsFolder
            $ConfigurationsFolderPath = Convert-Path @params

            #region Test configuration folder
            If (
                (-not $ConfigurationsFolderPath) -or
                (-not (Test-Path -LiteralPath $ConfigurationsFolderPath -PathType Container))
            ) {
                throw "Configurations folder '$ConfigurationsFolder' not found"
            }
            If (
                (Get-ChildItem -Path $ConfigurationsFolderPath -File -Recurse -Filter '*.json' | Measure-Object).Count -eq 0
            ) {
                throw "No .JSON file found in the configurations folder '$ConfigurationsFolderPath'. Please create a configuration file first."
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
        Write-Host 'You can close this window at any time'
        Start-Sleep -Seconds 120
        Exit
    }
}

Process {
    try {
        if (-not $ConfigurationFilePath) {
            #region Get all pre-configured .JSON files
            $getParams = @{
                LiteralPath = $ConfigurationsFolderPath
                File        = $true
                Filter      = '*.json'
            }
            $jsonFiles = Get-ChildItem @getParams

            if (-not $jsonFiles) {
                throw "No pre-configured .JSON caller files found in folder '$ConfigurationsFolderPath'"
            }
            #endregion

            #region Display GUI to select the correct .JSON file
            Write-Host 'Select a configuration file'
            $outParams = @{
                Title      = 'Select the configuration you want to execute:'
                OutputMode = 'Single'
            }
            $selectedJsonFile = $jsonFiles | Select-Object @{
                Name       = 'Configuration file'; 
                Expression = { $_.BaseName } 
            } | 
            Out-GridView @outParams

            if (-not $selectedJsonFile) {
                throw 'No pre-configuration file selected'
            }

            $jsonFilePath = $jsonFiles | Where-Object {
                $_.BaseName -eq $selectedJsonFile.PSObject.Properties.Value
            } | Select-Object -ExpandProperty FullName
            #endregion
        }
        else {
            $jsonFilePath = $ConfigurationFilePath
        }

        #region Import .JSON file
        try {
            $jsonFile = Get-Content -Path $jsonFilePath -Raw | 
            ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "File '$jsonFilePath' is not a valid .JSON configuration file: $_"
        }
        #endregion
   
        #region Test parameters in .JSON file
        if (-not $jsonFile.StartScript) {
            throw "The parameter 'StartScript' is missing in file '$jsonFilePath'."
        }

        $jsonFile.StartScript.PSObject.Properties.Name | Where-Object {
            $startScriptParameters.Key -notContains $_
        } | ForEach-Object {
            $invalidParameter = $_
            throw "The parameter '$invalidParameter' in file '$jsonFilePath' is not accepted by script '$startScriptPath'."
        }
        #endregion
            
        #region Relaunch current script elevated if needed
        if (
            ($jsonFile.RunInElevatedPowerShellSession) -and
            (-not (Test-IsStartedElevatedHC))
        ) {
            # relaunch current script as an elevated process
            Write-Host 'Please accept the prompt to start the script in elevated mode'
      
            $startParams = @{
                FilePath     = 'powershell.exe'
                ArgumentList = '-Command "& ''{0}'' -PreconfiguredCaller ''{1}'' -NoConfirmQuestion"' -f 
                $MyInvocation.MyCommand.Path, 
                $ConfigurationFile
                Verb         = 'RunAs'
            }
            Start-Process @startParams
            Exit
        }
        #endregion

        #region Display settings
        Write-Host "`nFile: " -NoNewline -ForegroundColor Gray
        Write-Host "$($selectedJsonFile.PSObject.Properties.Value).json" -ForegroundColor Green

        $jsonFile.StartScript | Format-List
        Write-Host "`r`n"
        #endregion

        #region Confirm selection before executing
        if (-not $NoConfirmQuestion) {
            $answer = $null

            while ($answer -notMatch '^y$|^n$') {
                $answer = Read-Host 'Are you sure you want to continue (y/n)'
                $answer = $answer.ToLower()
            }

            if ($answer -ne 'y') {
                Exit
            }
        }
        #endregion
    
        #region Execute script
        $invokeParams = @{
            Path      = $startScriptPath
            Arguments = ConvertTo-HashtableHC $jsonFile.StartScript
        }
        Invoke-ScriptHC @invokeParams
        #endregion
    }
    catch {
        Write-Warning 'Failed to start the script:'
        Write-Warning $_
        Write-Host 'You can close this window at any time'
        Start-Sleep -Seconds 120
        Exit
    }
}