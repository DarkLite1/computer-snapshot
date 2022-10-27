<#
    .SYNOPSIS
        Start the script in this folder with the correct arguments.

    .DESCRIPTION
        The sole purpose of this script is to launch the other script located 
        in the same folder with the correct arguments. Because the shortcut file
        'Launcher.lnk' has a limit in string length for the arguments to the 
        script, a caller script like this one is required.
#>

Set-Location $PSScriptRoot

$startParams = @{
    FilePath     = 'powershell.exe'
    ArgumentList = '-ExecutionPolicy Bypass -NoProfile -Command "& ''{0}'' -StartScript ''{1}'' -ConfigurationsFolder ''{2}''"' -f 
    '.\Invoke configuration.ps1', 
    '..\Invoke scripts\Invoke scripts.ps1',
    '..\..\Configurations'
}
Start-Process @startParams