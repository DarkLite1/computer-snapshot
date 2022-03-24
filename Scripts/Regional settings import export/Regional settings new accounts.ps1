<#
    .SYNOPSIS
        Apply the regional settings of the current user account to accounts 
        that will be created after this script runs.

    .DESCRIPTION
        Only accounts that are created after this script runs will receive the 
        same regional settings as the current account.
#>
Param (
    [String[]]$RegistryKeys = @(
        'HKEY_CURRENT_USER\Control Panel\International',
        'HKEY_CURRENT_USER\Control Panel\Input Method',
        'HKEY_CURRENT_USER\Keyboard Layout'
    )
)

$tempFileComplete = New-TemporaryFile

$encoding = @{
    Encoding = 'unicode'
}

#region Export registry keys
$firstRun = $true

foreach ($key in $RegistryKeys) {
    Write-Verbose "Export registry key '$key'"

    $tempFile = New-TemporaryFile

    $startParams = @{
        FilePath     = 'regedit.exe' 
        ArgumentList = "/e `"$($tempFile.FullName)`" `"$key`"" 
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @startParams

    if ($process.ExitCode) {
        throw "Failed to export registry key '$key': exit code $($process.ExitCode)"
    }

    if ($firstRun) {
        $tempFile | Get-Content @encoding | 
        Out-File @encoding -FilePath $tempFileComplete.FullName
    }
    else {
        $tempFile | Get-Content @encoding | Select-Object -Skip 1 | 
        Out-File @encoding -FilePath $tempFileComplete.FullName -Append 
    }

    $firstRun = $false
}
#endregion

#region Create profile registry keys
$exportedRegistryFiles = @(
    'HKEY_USERS\.DEFAULT',
    'HKEY_USERS\TEMP', 
    'HKEY_USERS\S-1-5-20',
    'HKEY_USERS\S-1-5-19'
) | ForEach-Object {
    $outParams = @{
        FilePath = "$($ENV:Temp)\RegionalSettings_{0}.reg" -f ($_.Split('\')[1])
        Encoding = 'utf8'
    }
    Write-Verbose "Create registry key file '$($outParams.FilePath)'"

    $fileContent = $tempFileComplete | Get-Content @encoding
    $fileContent.Replace('HKEY_CURRENT_USER', $_) |
    Out-File @outParams

    $outParams.FilePath
}
#endregion

#region Set default settings for new accounts
$TempKey = 'HKEY_USERS\TEMP'
$DefaultRegPath = 'C:\Users\Default\NTUSER.DAT'

$startParams = @{
    FilePath     = 'reg.exe'
    ArgumentList = "load `"$TempKey`" `"$DefaultRegPath`"" 
    Wait         = $true
    PassThru     = $true
}
$process = Start-Process @startParams

if ($process.ExitCode) {
    throw "Failed to load the temporary profile: exit code $($process.ExitCode)"
}

$exportedRegistryFiles | ForEach-Object {
    Write-Verbose "Import registry key file '$_'"

    $startParams = @{
        FilePath     = 'regedit.exe'
        ArgumentList = "/s `"$_`""
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @startParams

    if ($process.ExitCode) {
        throw "Failed to import registry key '$_': exit code $($process.ExitCode)"
    }
}

$startParams = @{
    FilePath     = 'reg.exe'
    ArgumentList = "unload `"$TempKey`""
    Wait         = $true
    PassThru     = $true
}
$process = Start-Process @startParams

if ($process.ExitCode) {
    throw "Failed to unload the temporary profile: exit code $($process.ExitCode)"
}
#endregion