#Requires -Version 5.1
<#
.SYNOPSIS
    Open the single-file configuration wizard from the USB stick.
#>
try {
    $ErrorActionPreference = 'Stop'
    & "$PSScriptRoot\Invoke GUI.ps1"
}
catch {
    $errorText = $_.Exception.Message

    # A zip opened in Explorer runs from a temporary folder such as Temp1_<name>.zip
    $path = $PSScriptRoot
    $isTemporary = $path -like (Join-Path ([IO.Path]::GetTempPath()) '*') -or
        $path -match '\\Temp\d*_[^\\]*\.zip\\' -or
        $path -match '\.zip\\'
    $isBlocked = $false
    try {
        $isBlocked = $null -ne (Get-Item -LiteralPath $PSCommandPath -Stream Zone.Identifier -ErrorAction Stop)
    }
    catch { }

    $message = "The wizard could not start.`r`n`r`n$errorText`r`n`r`nLocation: $path"
    if ($isTemporary -or $isBlocked) {
        $message += "`r`n`r`nThe tool seems to run from a zip file, a temporary folder or a downloaded file. Do this:`r`n" +
            "1. Close this window.`r`n" +
            "2. Right-click the zip file, choose Properties, tick 'Unblock' and click OK.`r`n" +
            "3. Right-click the zip file again and choose 'Extract All'.`r`n" +
            "4. Double-click 'Start wizard' in the extracted folder."
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            $message, 'Computer Snapshot', 'OK', 'Error')
    }
    catch {
        Write-Error $message
    }
    exit 1
}