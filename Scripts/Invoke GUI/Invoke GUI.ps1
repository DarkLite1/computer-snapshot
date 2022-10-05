<#
    .SYNOPSIS
        Helper script to guide the user in creating and/or restoring a snapshot.

    .DESCRIPTION
        This script serves as a launcher script for ease of use. 

        Once the shortcut is clicked a new PowerShell console window is opened
        to ask the user some questions to be able to start the script to create
        or restore a snapshot. 

        The advantage and purpose of this script is to avoid users editing the
        parameters of the 'Start-Script.ps1' script.

    .PARAMETER StartScript
        Path to the script that will execute the different types of snapshots.
#>

Param (
    [String]$StartScript = '..\..\Start-Script.ps1'
)

Begin {
    Function Get-KeyPressedHC {
        [OutputType([ConsoleKey])]
        Param(
            [Parameter(Mandatory)]
            [ConsoleKey[]]$KeyboardShortcuts
        )
        
        do {
            $keyInfo = [Console]::ReadKey($true)
            if ($KeyboardShortcuts -notContains $keyInfo.Key) {
                Write-Warning "key '$($keyInfo.Key)' not supported"
            }
        } until ($KeyboardShortcuts -contains $keyInfo.Key)
    
        Write-Debug "Selected '$($keyInfo.Key)'"
        $keyInfo.Key
    }
    Function Get-DefaultParameterValuesHC {
        <#
        .SYNOPSIS
            Get the default values for parameters set in a script or function.
        
        .DESCRIPTION
            A hash table is returned containing the name and the default value 
            of the parameters used in a script or function. When a parameter is 
            mandatory but still has a default value this value will not be 
            returned.

            Parameters that have no default value are not returned.
        
        .PARAMETER Path
            Function name or path to the script file
        
        .EXAMPLE
            Function Test-Function {
                Param (
                    [Parameter(Mandatory)]
                    [String]$PrinterName,
                    [Parameter(Mandatory)]
                    [String]$PrinterColor,
                    [String]$ScriptName = 'Get printers',
                    [String]$PaperSize = 'A4'
                )
            }
            Get-DefaultParameterValuesHC -Path 'Test-Function'
        
            Get the default values for parameters that are not mandatory.
            @{
                ScriptName = 'Get printers'
                PaperSize = 'A4'
            }
        #>
    
        [CmdletBinding()]
        [OutputType([hashtable])]
        Param (
            [Parameter(Mandatory)]
            [String]$Path
        )
        try {
            $ast = (Get-Command $Path).ScriptBlock.Ast
    
            $selectParams = @{
                Property = @{ 
                    Name       = 'Name'; 
                    Expression = { $_.Name.VariablePath.UserPath } 
                },
                @{ 
                    Name       = 'Value'; 
                    Expression = { $_.DefaultValue.Extent.Text }
                }
            }
    
            $defaultValueParameters = $ast.FindAll( {
                    $args[0] -is 
                    [System.Management.Automation.Language.ParameterAst] 
                } , $true) | 
            Where-Object { 
                ($_.DefaultValue) -and
                (-not ($_.Attributes | 
                    Where-Object { $_.TypeName.Name -eq 'Parameter' } | 
                    ForEach-Object -MemberName NamedArguments | 
                    Where-Object { $_.ArgumentName -eq 'Mandatory' }))
            } | 
            Select-Object @selectParams
                    
            $result = @{ }
    
            foreach ($d in $defaultValueParameters) {
                $result[$d.Name] = foreach ($value in $d.Value) {
                    $ExecutionContext.InvokeCommand.InvokeScript($value, $true)
                }
            }
            $result
        }
        catch {
            throw "Failed retrieving the default parameter values: $_"
        }
    }
    Function Show-HeaderHC {
        Param (
            [Parameter(Mandatory)]
            [String[]]$AddressBarLocation
        )

        Clear-Host
        Show-AsciArtHC
        Write-Host (' > ' + ($AddressBarLocation -join ' > ') + "`n") -ForegroundColor Green
    }
    Function Show-FooterHC {
        Param (
            [Parameter(Mandatory)]
            [String]$KeyboardShortcutsMenu
        )

        Write-Host $KeyboardShortcutsMenu -ForegroundColor DarkGray
    }
    Function New-KeyboardShortcutsHC {
        <#
        .SYNOPSIS
            Create a string with keyboard shortcuts to use with Write-Host.
    
        .DESCRIPTION
            Create a string with columns to display the keyboard shortcuts the user
            can use to navigate the menu. This string, once created, can then be 
            used multiple times by Write-Host to display the same message.
    
        .PARAMETER Key
            Collection of supported keys in the application.
    
        .PARAMETER ColumnCount
            Number of columns to display. Columns are text aligned for greater 
            readability.
    
        .PARAMETER ColumnSeparator
            A spacer used between the different columns. Can be multiple white 
            spaces, a tab, or a custom string.
    
        .PARAMETER Title
            The text displayed above the columns with keyboard shortcuts.
    
        .EXAMPLE
            Generate a basic aligned menu and display the results in the console
            
            $params = @{
                KeyboardShortcuts = @(
                    [ConsoleKey]::UpArrow,
                    [ConsoleKey]::LeftArrow,
                    [ConsoleKey]::SpaceBar,
                    [ConsoleKey]::DownArrow,
                    [ConsoleKey]::RightArrow,
                    [ConsoleKey]::Enter,
                    [ConsoleKey]::Escape
                )
                ColumnCount     = 3
                ColumnSeparator = '  '
            }
            $keyboardShortcuts = New-KeyboardShortcutsHC @params
    
            Write-Host $keyboardShortcuts -ForegroundColor DarkGray
    #>
    
        [OutputType([String])]
        Param(
            [ConsoleKey[]]$KeyboardShortcuts = @(
                [ConsoleKey]::UpArrow,
                [ConsoleKey]::LeftArrow,
                [ConsoleKey]::SpaceBar,
                [ConsoleKey]::DownArrow,
                [ConsoleKey]::RightArrow,
                [ConsoleKey]::Enter,
                [ConsoleKey]::Escape
            ),
            [Int]$ColumnCount = 3,
            [String]$ColumnSeparator = '    ',
            [String]$Title = "`nKeyboard shortcuts:"
        )
    
        $navigationKeys = switch ($KeyboardShortcuts) {
            { $_ -contains [ConsoleKey]::UpArrow } {  
                '[ARROW_UP] to move up'
            }
            { $_ -contains [ConsoleKey]::Enter } {  
                '[ENTER] to confirm'
            }
            { $_ -contains [ConsoleKey]::SpaceBar } {  
                '[SPACE_BAR] to select/unselect'
            }
            { $_ -contains [ConsoleKey]::DownArrow } {  
                '[ARROW_DOWN] to move down'
            }
            { $_ -contains [ConsoleKey]::LeftArrow } {  
                '[ARROW_LEFT] go back'
            }
            { $_ -contains [ConsoleKey]::RightArrow } {  
                '[ARROW_RIGHT] go forward'
            }
            { $_ -contains [ConsoleKey]::Escape } {  
                '[ESC] to quit'
            }
        }
    
        #region Calculate minimal column width
        $minimalColumnWidth = @{}
        for ($i = 0; $i -lt $navigationKeys.Count; $i = $i + $ColumnCount) {
            foreach ($columnNr in 0..($ColumnCount - 1)) {
                $index = $i + $columnNr
                if ($index -ge $navigationKeys.Count) {
                    break
                }
    
                $length = $navigationKeys[$index].Length
    
                if ($length -ge $minimalColumnWidth[$columnNr]) {
                    $minimalColumnWidth[$columnNr] = $length
                }
            }
        }
        #endregion
    
        #region Add trailing spaces where needed
        for ($i = 0; $i -lt $navigationKeys.Count; $i = $i + $ColumnCount) {
            foreach ($columnNr in 0..($ColumnCount - 1)) {
                $index = $i + $columnNr
                if ($index -ge $navigationKeys.Count) {
                    break
                }
    
                $navigationKeys[$index] = $navigationKeys[$index].PadRight($minimalColumnWidth[$columnNr])
            }
        }
        #endregion
    
        #region Create rows to display
        $rows = for ($i = 0; $i -lt $navigationKeys.Count; $i = $i + 3) {
            '{0}' -f (
                $navigationKeys[$i..($i + 2)] -join $ColumnSeparator
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
    Function Show-AsciArtHC {
        Write-Host  '
_________                               __                                                   .__            __   
\_   ___ \  ____   _____ ______  __ ___/  |_  ___________    ______ ____ _____  ______  _____|  |__   _____/  |_ 
/    \  \/ /  _ \ /     \\____ \|  |  \   __\/ __ \_  __ \  /  ___//    \\__  \ \____ \/  ___/  |  \ /  _ \   __\
\     \___(  <_> )  Y Y  \  |_> >  |  /|  | \  ___/|  | \/  \___ \|   |  \/ __ \|  |_> >___ \|   Y  (  <_> )  |  
 \______  /\____/|__|_|  /   __/|____/ |__|  \___  >__|    /____  >___|  (____  /   __/____  >___|  /\____/|__|  
        \/             \/|__|                    \/             \/     \/     \/|__|       \/     \/           
        ' -ForegroundColor Cyan
    }
    Function Show-IdHC {
        Write-Host (
            "{0} - {1} - {2}`r`n" -f
            (Get-Date).ToString('dddd dd/MM/yyyy HH:mm'),
            $env:USERNAME, 
            [System.Net.Dns]::GetHostEntry([string]$env:computername).HostName
        ) -ForegroundColor Gray
    }
    Function Show-GuiHC {
        [OutputType()]
        Param (
            [Parameter(Mandatory)]
            [HashTable]$Screens,
            [Parameter(Mandatory)]
            [String]$ScreenName,
            [int]$HighLightRow = 0,
            [Boolean]$Select
        )
        
        $screen = $Screens[$ScreenName]

        Show-HeaderHC -AddressBarLocation $screen.AddressBarLocation

        Write-Host $screen.Question
    
        $options = $screen.Answers

        for ($i = 0; $i -lt $options.Count; $i++) {
            $o = $options[$i]

            #region Set color
            $colorParams = @{
                ForegroundColor = 'White'
                BackgroundColor = 'Black'
            }

            if ($i -eq $HighLightRow) { 
                $colorParams = @{
                    ForegroundColor = 'Black'
                    BackgroundColor = 'White'
                }
                if (-not $screen.AcceptMultipleAnswers) {
                    $o.selected = $true
                }
                elseif ($Select) {
                    $o.selected = -not $o.selected
                }
            }
            elseif (-not $screen.AcceptMultipleAnswers) {
                $o.selected = $false
            }
            #endregion
    
            #region Set text
            $message = " {0} {1} " -f 
            $(
                if ($screen.AcceptMultipleAnswers) {
                    if ($o.selected) { '(x)' } else { '( )' }
                }
                else {
                    '>'
                }
            ), $o.option
            #endregion
    
            Write-Host $message @colorParams
        }
    
        Show-FooterHC -KeyboardShortcutsMenu $screen.KeyboardShortcuts.Menu 
        
        #region Capture and wait for valid keyboard input
        $keyParams = @{
            KeyboardShortcuts = $screen.KeyboardShortcuts.Keys
        }
        $keyPressed = Get-KeyPressedHC @keyParams
        #endregion
        
        #region Handle keyboard input
        $params = @{
            Screens      = $Screens
            ScreenName   = $ScreenName
            HighLightRow = $HighLightRow
            Select       = $false
        }
        switch ($keyPressed) {
            ([ConsoleKey]::DownArrow) { $params.HighLightRow++; break }
            ([ConsoleKey]::UpArrow) { $params.HighLightRow-- ; break }
            ([ConsoleKey]::SpaceBar) { $params.Select = $true ; break }
            ([ConsoleKey]::Enter) { Return $options }
            ([ConsoleKey]::Escape) { 
                Write-Warning 'Quit script'
                Exit
            }
            Default { throw "key '$_' not implemented" }
        }
        #endregion
        
        #region Highlight only visible rows
        switch ($params.HighLightRow) {
            { $_ -lt 0 } {
                $params.HighLightRow = 0
                break 
            }
            { $_ -ge $Options.Count } { 
                $params.HighLightRow = $Options.Count - 1
                break 
            }
        }
        #endregion

        Show-GuiHC @params
    }
    try {
        #region Test host
        if ($Host.Name -eq 'Windows PowerShell ISE Host') {
            throw "The host 'Windows PowerShell ISE' is not supported. Please use 'Visual Studio Code' or the PowerShell console to execute this script."
        }
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
    }
    catch {
        Write-Warning 'Failed to run the script:'
        Write-Warning $_
        Write-Host 'You can close this window at any time'
        Start-Sleep -Seconds 20
        Exit   
    }
}
Process {
    try {
        #region Create keyboard shortcuts menu and keys
        $keyboardShortcuts = @{
            all  = @{
                keys = @(
                    [ConsoleKey]::UpArrow,
                    [ConsoleKey]::LeftArrow,
                    [ConsoleKey]::SpaceBar,
                    [ConsoleKey]::DownArrow,
                    [ConsoleKey]::RightArrow,
                    [ConsoleKey]::Enter,
                    [ConsoleKey]::Escape
                )
            }
            home = @{
                keys = @(
                    [ConsoleKey]::UpArrow,
                    [ConsoleKey]::DownArrow,
                    [ConsoleKey]::Enter,
                    [ConsoleKey]::Escape
                )
            }
        }

        $keyboardShortcuts.GetEnumerator() | ForEach-Object {
            $_.Value['menu'] = New-KeyboardShortcutsHC -KeyboardShortcuts $_.Value.Keys
        }
        #endregion

        #region Get Start-Script.ps1 parameters
        $defaultValues = Get-DefaultParameterValuesHC -Path $startScriptPath
        $snapshotItems = $defaultValues.Snapshot.GetEnumerator() | 
        ForEach-Object {
            @{
                option   = $_.Key
                selected = $_.Value
            }
        }
        #endregion

        $screens = @{
            Home            = @{
                AddressBarLocation    = @('Home')
                AcceptMultipleAnswers = $false
                Question              = 'What would you like to do?'
                Answers               = @(
                    @{
                        option     = 'Create a new snapshot'
                        selected   = $false
                        nextScreen = 'CreateSnapshot'
                    }
                    @{
                        option     = 'Restore a snapshot'
                        selected   = $false
                        nextScreen = 'RestoreSnapshot'
                    }
                )
                KeyboardShortcuts     = $keyboardShortcuts.home
            }
            CreateSnapshot  = @{
                AddressBarLocation    = @('Home', 'CreateSnapshot')
                AcceptMultipleAnswers = $true
                Question              = 'For what items would you like to take a snapshot?'
                Answers               = $snapshotItems
                KeyboardShortcuts     = $keyboardShortcuts.all
            }
            RestoreSnapshot = @{
                AddressBarLocation    = @('Home', 'RestoreSnapshot')
                AcceptMultipleAnswers = $true
                Question              = 'Which items would you like to restore?'
                Answers               = $snapshotItems
                KeyboardShortcuts     = $keyboardShortcuts.all
            }
        }
        
        Show-GuiHC -Screens $screens -ScreenName 'Home'
    }
    catch {
        Write-Warning 'Failed to start the script:'
        Write-Warning $_
        Write-Host 'You can close this window at any time'
        Start-Sleep -Seconds 20
        Exit
    }
}
