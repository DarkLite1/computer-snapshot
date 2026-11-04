<#
.SYNOPSIS
    Open the terminal page in Microsoft Edge in kiosk mode.
.NOTES
    Example template for CopyFilesFolders with FillPlaceholders: the restore
    asks for the server address and writes it into the copy of this file.
#>
$ArgumentList = @(
    '--kiosk'
    ('http://{{ipv4:IP address of the terminal server}}' +
        ':1353/terminal/?reference=TRM_AISE_01')
    '--edge-kiosk-type=fullscreen'
    '--disable-pinch'
    '--overscroll-history-navigation=0'
) -join ' '

Write-Verbose "Start Microsoft Edge with arguments '$ArgumentList'"
Start-Process -FilePath 'msedge.exe' -ArgumentList $ArgumentList
