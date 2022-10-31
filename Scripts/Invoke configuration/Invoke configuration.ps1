<#
    .SYNOPSIS
        Execute the main script with the correct arguments.

    .DESCRIPTION
        This script serves as a launcher script for ease of use. 

        Once the shortcut 'Select configuration.lnk' in the parent folder is 
        clicked, this script will display all the .JSON files in the folder 
        'Configurations'. Each .JSON file represents a set of arguments that 
        can be used to call the main script.

        This allows the user to leave with a USB stick full of ready to use
        configurations to go on site and restore a specific snapshot on a 
        machine.

        The shortcut 'Start wizard.lnk' opens a GUI to ask questions to the
        user. When all questions are answered and the user proceeds to start 
        the restore/backup process a custom configuration file is created by
        the 'Invoke GUI' script. Then this script is called with the argument
        'ConfigurationFile' to call the main script with the correct arguments. 

    .PARAMETER StartScript
        Path to the script that will execute the different types of snapshots.

    .PARAMETER ConfigurationsFolder
        Folder where the .JSON files are stored. Each file represents a set of
        arguments to be used with 'StartScript'.

    .PARAMETER ConfigurationFile
        A single .JSON file containing the required arguments for the main 
        script. The argument 'ConfigurationFile' combined with 'Confirm' can be 
        used to launch a configuration used by the main script without user 
        interaction.

    .PARAMETER Confirm
        When a configuration file is selected a question is asked to make sure
        the user selected the correct file before executing it. When using this
        switch no question is asked.
#>

Param (
    [String]$StartScript = '..\Invoke scripts\Invoke scripts.ps1',
    [String]$ConfigurationsFolder = '..\..\Configurations',
    [String]$ConfigurationFile,
    [Switch]$Confirm
)

Begin {
    Function Convert-StringsToColumnsHC {
        [OutputType([String])]
        Param(
            [Parameter(Mandatory)]    
            [String[]]$Items,
            [String]$Title,
            [Int]$ColumnCount = 5,
            [String]$ColumnSeparator = '    '
        )
    
        #region Calculate minimal column width
        $minimalColumnWidth = @{}
        for ($i = 0; $i -lt $Items.Count; $i = $ColumnCount + $i ) {
            Write-Verbose "i = $i"
            foreach ($columnNr in 0..($ColumnCount - 1)) {
                $index = $columnNr + $i
    
                if ($index -ge $Items.Count) {
                    break
                }
    
                $length = $Items[$index].Length
    
                if ($length -ge $minimalColumnWidth[$columnNr]) {
                    $minimalColumnWidth[$columnNr] = $length
                }
            }
        }
        #endregion
    
        #region Add trailing spaces where needed
        for ($i = 0; $i -lt $Items.Count; $i = $ColumnCount + $i) {
            foreach ($columnNr in 0..($ColumnCount - 1)) {
                $index = $columnNr + $i
                if ($index -ge $Items.Count) {
                    break
                }
    
                $Items[$index] = $Items[$index].PadRight($minimalColumnWidth[$columnNr])
            }
        }
        #endregion
    
        #region Create rows to display
        $rows = for ($i = 0; $i -lt $Items.Count; $i = $ColumnCount + $i) {
            '{0}' -f (
                $Items[$i..(($ColumnCount + $i) - 1 )] -join $ColumnSeparator
            )
        }
    
        $toPrint = $rows -join "`n"
        #endregion
    
        #region Add Title
        if ($Title) {
            $toPrint = $Title + "`n" + $toPrint
        }
        #endregion
    
        $toPrint
    }
    
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
        Set-Location $PSScriptRoot

        #region ASCI art
        Write-Host '  
         _________ __                 __                         _____.__        
        /   _____//  |______ ________/  |_    ____  ____   _____/ ____\__| ____  
        \_____  \\   __\__  \\_  __ \   __\ _/ ___\/  _ \ /    \   __\|  |/ ___\ 
        /        \|  |  / __ \|  | \/|  |   \  \__(  <_> )   |  \  |  |  / /_/  >
       /_______  /|__| (____  /__|   |__|    \___  >____/|___|  /__|  |__\___  / 
               \/           \/                   \/           \/        /_____/ 
        ' -ForegroundColor Cyan
        
        Write-Host (
            '{0} - {1} - {2}' -f
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

            #region Test configuration file
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
                ArgumentList = '-ExecutionPolicy Bypass -NoProfile -Command "& ''{0}'' -ConfigurationFile ''{1}'' -Confirm"' -f 
                $MyInvocation.MyCommand.Path, 
                $ConfigurationFile
                Verb         = 'RunAs'
            }
            Start-Process @startParams
            Exit
        }
        #endregion

        $startScriptArguments = ConvertTo-HashtableHC $jsonFile.StartScript
        
        #region Display settings
        $length = (
            $startScriptArguments.Keys | 
            Measure-Object -Maximum -Property Length
        ).Maximum

        $params = @{
            Object          = "`n$('File'.PadRight($length)) : "
            ForegroundColor = 'Gray'
        }
        Write-Host @params -NoNewline

        $params = @{
            Object          = Split-Path $jsonFilePath -Leaf
            ForegroundColor = 'Green'
        }
        Write-Host @params

        $startScriptArguments.GetEnumerator().where({ $_.Key -ne 'Snapshot' }).foreach(
            {
                Write-Host "$($_.Key.PadRight($length)) : " -NoNewline
                Write-Host $_.Value
            }
        )

        $items = @{
            enabled  = $startScriptArguments.Snapshot.GetEnumerator().where(
                { $_.Value }
            )
            disabled = $startScriptArguments.Snapshot.GetEnumerator().where(
                { -not $_.Value }
            )
        }
        
        if ($items.enabled) {
            Write-Host "`nSelected snapshot items: " -ForegroundColor Gray

            $params = @{
                Object          = Convert-StringsToColumnsHC $items.enabled.Name
                ForegroundColor = 'Cyan'
            }
            Write-Host @params
        }
        else {
            throw "No snapshot items found there are set to 'true'"
        }
        if ($items.disabled) {
            Write-Host "`nDisabled snapshot items: " -ForegroundColor Gray

            $params = @{
                Object          = Convert-StringsToColumnsHC $items.disabled.Name
                ForegroundColor = 'Magenta'
                # ForegroundColor = 'Gray'
            }
            Write-Host @params
        }

        
        Write-Host "`r`n"
        #endregion

        #region Confirm selection before executing
        if (-not $Confirm) {
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
            Arguments = $startScriptArguments
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