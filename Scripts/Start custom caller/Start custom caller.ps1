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
    [String]$StartScript = '.\Start-Script.ps1'
)

Begin {
    Function Get-KeyPressedHC {
        [OutputType([ConsoleKey])]
        Param(
            [ConsoleKey[]]$Key = @(
                [ConsoleKey]::UpArrow,
                [ConsoleKey]::DownArrow,
                [ConsoleKey]::SpaceBar,
                [ConsoleKey]::Enter,
                [ConsoleKey]::Escape
            )
        )
        
        do {
            $keyInfo = [Console]::ReadKey($true)
            if ($Key -notContains $keyInfo.Key) {
                Write-Warning "key '$($keyInfo.Key)' not supported"
            }
        } until ($Key -contains $keyInfo.Key)
    
        Write-Debug "Selected '$($keyInfo.Key)'"
        $keyInfo.Key
    }
    Function Show-HeaderHC {
        Clear-Host
        Show-AsciArtHC
        Show-NavigationBarHC -Location $state.addressBarLocation
    }
    Function Show-FooterHC {
        Write-Host $state.keyboardShortcutsMenu -ForegroundColor DarkGray
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
                Key             = @(
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
            [ConsoleKey[]]$Key = @(
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
    
        $navigationKeys = switch ($Key) {
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
    Function Show-NavigationBarHC {
        Param(
            [Parameter(Mandatory)]
            [String[]]$Location
        )

        Write-Host (' > ' + ($Location -join ' > ') + "`n") -ForegroundColor Green
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
    Function Show-OptionsHC {
        [OutputType([HashTable])]
        Param (
            [Parameter(Mandatory)]
            [HashTable[]]$Options,
            [Parameter(Mandatory)]
            [String]$Question,
            [int]$HighLightRow = 0,
            [Boolean]$Select
        )
        
        Show-HeaderHC

        Write-Host $Question
    
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $o = $Options[$i]
            #region Set color
            if ($i -eq $HighLightRow) { 
                $colorParams = @{
                    ForegroundColor = 'Black'
                    BackgroundColor = 'White'
                }
                if ($Select) {
                    $o.selected = -not $o.selected
                }
            }
            else {
                $colorParams = @{
                    ForegroundColor = 'White'
                    BackgroundColor = 'Black'
                }
            }
            #endregion
    
            #region Set text
            $message = " ({0}) {1} " -f 
            $(
                if ($o.selected) { 'x' } else { ' ' }
            ), $o.question
            #endregion
    
            Write-Host $message @colorParams
        }
    
        Show-FooterHC
        
        #region Handle keyboard input
        $keyPressed = Get-KeyPressedHC
    
        $params = @{
            Options      = $Options
            Question     = $Question
            HighLightRow = $HighLightRow
            Select       = $false
        }
        switch ($keyPressed) {
            ([ConsoleKey]::DownArrow) { $params.HighLightRow++; break }
            ([ConsoleKey]::UpArrow) { $params.HighLightRow-- ; break }
            ([ConsoleKey]::SpaceBar) { $params.Select = $true ; break }
            ([ConsoleKey]::Enter) { Return $Options }
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

    
        Show-OptionsHC @params
    }
    try {
        #region Test
        if ($Host.Name -eq 'Windows PowerShell ISE Host') {
            throw "The host 'Windows PowerShell ISE' is not supported. Please use 'Visual Studio Code' or the PowerShell console to execute this script."
        }
        #endregion

        $params = @{
            Path        = $StartScript
            ErrorAction = 'Ignore'
        }
        $startScriptPath = Convert-Path @params
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
        $state = @{
            addressBarLocation    = @('Home')
            keyboardShortcutsMenu = New-KeyboardShortcutsHC
        }

        $options = @(
            @{
                question = 'Option 1'
                selected = $false
            }
            @{
                question = 'Option 2'
                selected = $false
            }
            @{
                question = 'Option 3'
                selected = $false
            }
        )
        
        $params = @{
            Options  = $Options
            Question = 'What would you like restore?'
        }
        Show-OptionsHC @params
        
        'we done'
    }
    catch {
        Write-Warning 'Failed to start the script:'
        Write-Warning $_
        Write-Host 'You can close this window at any time'
        Start-Sleep -Seconds 20
        Exit
    }
}
