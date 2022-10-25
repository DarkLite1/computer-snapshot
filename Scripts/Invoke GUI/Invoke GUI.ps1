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
    Function Convert-KeyboardKeysToMenuItemsHC {
        [OutputType([String[]])]
        Param(
            [Parameter(Mandatory)]
            [ConsoleKey[]]$KeyboardKeys
        )
        
        foreach ($key in $KeyboardKeys) {
            switch ($key) {
                ([ConsoleKey]::UpArrow) {  
                    '[ARROW_UP] to move up'
                    break
                }
                ([ConsoleKey]::Enter) {  
                    '[ENTER] to confirm'
                    break
                }
                ([ConsoleKey]::SpaceBar) {  
                    '[SPACE_BAR] to select/unselect'
                    break
                }
                ([ConsoleKey]::DownArrow) {  
                    '[ARROW_DOWN] to move down'
                    break
                }
                ([ConsoleKey]::LeftArrow) {  
                    '[ARROW_LEFT] go back'
                    break
                }
                ([ConsoleKey]::RightArrow) {  
                    '[ARROW_RIGHT] go forward'
                    break
                }
                ([ConsoleKey]::Escape) {  
                    '[ESC] to quit'
                    break
                }
                Default {
                    throw "Key '$_' not supported"
                }
            }
        }
    }
    Function Convert-StringsToColumnsHC {
        [OutputType([String])]
        Param(
            [Parameter(Mandatory)]    
            [String[]]$Items,
            [String]$Title,
            [Int]$ColumnCount = 3,
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
            [Parameter(Mandatory)]
            [ConsoleKey[]]$KeyboardShortcuts,
            [Int]$ColumnCount = 3,
            [String]$ColumnSeparator = '    ',
            [String]$Title = "`nKeyboard shortcuts:"
        )
    
        $params = @{
            Items           = Convert-KeyboardKeysToMenuItemsHC -KeyboardKeys $KeyboardShortcuts
            Title           = $Title
            ColumnCount     = $ColumnCount
            ColumnSeparator = $ColumnSeparator
        }
        Convert-StringsToColumnsHC @params
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
                    $nextScreen = $o.nextScreen
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
            ),
            $(
                if ($o.description) {
                    $o.description
                }
                else {
                    $o.option
                }
            )
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
            ([ConsoleKey]::LeftArrow) {
                $params.ScreenName = $screen.PreviousScreen
                $params.HighLightRow = 0
                Show-GuiHC @params
                break 
            }
            ([ConsoleKey]::RightArrow) {
                $params.ScreenName = $nextScreen
                Show-GuiHC @params
                # Return $options
                break
            }
            ([ConsoleKey]::Enter) {
                $params.ScreenName = $nextScreen
                Show-GuiHC @params
                # Return $options
                break
            }
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

        $snapshotItems = @(
            @{
                option      = 'StartCustomScriptsBefore'
                description = 'Start a custom script before the script runs'
                selected    = $false
            }
            @{
                option      = 'RegionalSettings'
                description = 'Regional settings'
                selected    = $false
            }
            @{
                option      = 'UserAccounts'
                description = 'User accounts'
                selected    = $false
            }
            @{
                option      = 'UserGroups'
                description = 'Security groups'
                selected    = $false
            }
            @{
                option      = 'FirewallRules'
                description = 'Firewall rules'
                selected    = $false
            }
            @{
                option      = 'CreateFolders'
                description = 'Create folders'
                selected    = $false
            }
            @{
                option      = 'SmbShares'
                description = 'SMB shares (folders, permissions, ...)'
                selected    = $false
            }
            @{
                option      = 'NetworkCards'
                description = 'Network cards'
                selected    = $false
            }
            @{
                option      = 'NtpTimeServers'
                description = 'NTP time servers'
                selected    = $false
            }
            @{
                option      = 'RegistryKeys'
                description = 'Registry keys'
                selected    = $false
            }
            @{
                option      = 'ScheduledTasks'
                description = 'Scheduled tasks'
                selected    = $false
            }
            @{
                option      = 'CopyFilesFolders'
                description = 'Copy files or folders'
                selected    = $false
            }
            @{
                option      = 'Software'
                description = 'Software'
                selected    = $false
            }
            @{
                option      = 'StartCustomScriptsAfter'
                description = 'Start a custom script after the script ran'
                selected    = $false
            }
        )

        $screens = @{
            Home                = @{
                AddressBarLocation    = @('Home')
                AcceptMultipleAnswers = $false
                Question              = 'What would you like to do?'
                Answers               = @(
                    @{
                        option     = 'Create a backup'
                        selected   = $false
                        nextScreen = 'CreateBackup'
                    }
                    @{
                        option     = 'Restore a backup'
                        selected   = $false
                        nextScreen = 'RestoreBackup'
                    }
                )
                PreviousScreen        = $null
                KeyboardShortcuts     = $keyboardShortcuts.home
            }
            CreateBackup        = @{
                AddressBarLocation    = @('Home', 'Create backup')
                AcceptMultipleAnswers = $true
                Question              = 'Select what to backup?'
                Answers               = $snapshotItems
                Screen                = @{
                    previous = 'Home'
                    next     = 'ConfirmCreateBackup'
                }
                NextScreen            = 'ConfirmCreateBackup'
                KeyboardShortcuts     = $keyboardShortcuts.all
            }
            RestoreBackup       = @{
                AddressBarLocation    = @('Home', 'Restore backup')
                AcceptMultipleAnswers = $true
                Question              = 'Select what to restore:'
                Answers               = $snapshotItems
                PreviousScreen        = 'Home'
                KeyboardShortcuts     = $keyboardShortcuts.all
            }
            ConfirmCreateBackup = @{
                AddressBarLocation    = @(
                    'Home', 'Restore backup', 'Confirm'
                )
                AcceptMultipleAnswers = $true
                Question              = 'Are you sure you want to take a backup?'
                Answers               = @(
                    @{
                        option     = 'Yes'
                        selected   = $false
                        nextScreen = $null
                        Action     = 'CallStartScript'
                    }
                    @{
                        option     = 'No'
                        selected   = $false
                        nextScreen = 'Home'
                    }
                )
                PreviousScreen        = 'RestoreBackup'
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
