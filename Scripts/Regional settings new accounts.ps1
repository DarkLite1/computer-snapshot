#Requires -Version 5.1
<#
.SYNOPSIS
    Apply the current user's regional settings to accounts created later.
.DESCRIPTION
    Uses isolated temporary files and a temporary mount of the default user
    hive. Files and the mounted hive are cleaned up on both success and
    failure.
#>
[CmdletBinding()]
param(
    [string[]]$RegistryKeys = @(
        'HKEY_CURRENT_USER\Control Panel\International',
        'HKEY_CURRENT_USER\Control Panel\Input Method',
        'HKEY_CURRENT_USER\Keyboard Layout'
    )
)

$id = [guid]::NewGuid().ToString('N')
$tempFolder = Join-Path $env:TEMP "ComputerSnapshot-RegionalSettings-$id"
$tempKey = "HKEY_USERS\ComputerSnapshot_$id"
$temporaryFiles = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
$folderCreated = $false
$hiveLoaded = $false
try {
    Write-Verbose "Create temporary folder '$tempFolder'"
    $null = New-Item -Path $tempFolder -ItemType Directory -ErrorAction Stop
    $folderCreated = $true

    #region Export the current user's registry keys
    $registryLines = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $RegistryKeys.Count; $index++) {
        $key = $RegistryKeys[$index]
        $path = Join-Path $tempFolder "export-$index.reg"
        $temporaryFiles.Add($path)
        Write-Verbose "Export registry key '$key'"
        $params = @{
            FilePath     = 'regedit.exe'
            ArgumentList = "/e `"$path`" `"$key`""
            Wait         = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        $process = Start-Process @params
        if ($process.ExitCode -ne 0) {
            throw (
                "Failed to export registry key '$key': " +
                "exit code $($process.ExitCode)"
            )
        }
        $lines = @(
            Get-Content -LiteralPath $path -Encoding Unicode -ErrorAction Stop
        )
        if ($index -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
        foreach ($line in $lines) { $registryLines.Add($line) }
    }
    #endregion

    #region Create one import file per target profile
    $targets = @(
        'HKEY_USERS\.DEFAULT',
        $tempKey,
        'HKEY_USERS\S-1-5-20',
        'HKEY_USERS\S-1-5-19'
    )
    $importFiles = @(for ($index = 0; $index -lt $targets.Count; $index++) {
            $path = Join-Path $tempFolder "target-$index.reg"
            $temporaryFiles.Add($path)
            $registryLines |
            ForEach-Object {
                $_.Replace('HKEY_CURRENT_USER', $targets[$index])
            } |
            Out-File -LiteralPath $path -Encoding Unicode -ErrorAction Stop
            $path
        })
    #endregion

    #region Import the files with the default user hive loaded
    Write-Verbose "Load the default user hive in '$tempKey'"
    $params = @{
        FilePath     = 'reg.exe'
        ArgumentList = (
            "load `"$tempKey`" `"C:\Users\Default\NTUSER.DAT`""
        )
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    $process = Start-Process @params
    if ($process.ExitCode -ne 0) {
        throw (
            "Failed to load the temporary profile '$tempKey': " +
            "exit code $($process.ExitCode)"
        )
    }
    $hiveLoaded = $true
    foreach ($path in $importFiles) {
        Write-Verbose "Import registry key file '$path'"
        $params = @{
            FilePath     = 'regedit.exe'
            ArgumentList = "/s `"$path`""
            Wait         = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        $process = Start-Process @params
        if ($process.ExitCode -ne 0) {
            throw (
                "Failed to import registry key file '$path': " +
                "exit code $($process.ExitCode)"
            )
        }
    }
    #endregion
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    if ($hiveLoaded) {
        try {
            Write-Verbose "Unload the temporary profile '$tempKey'"
            $params = @{
                FilePath     = 'reg.exe'
                ArgumentList = "unload `"$tempKey`""
                Wait         = $true
                PassThru     = $true
                ErrorAction  = 'Stop'
            }
            $process = Start-Process @params
            if ($process.ExitCode -ne 0) {
                throw (
                    "Failed to unload the temporary profile '$tempKey': " +
                    "exit code $($process.ExitCode)"
                )
            }
        }
        catch { $failures.Add($_.Exception.Message) }
    }

    Write-Verbose 'Remove temporary files'
    $filesRemoved = $true
    foreach ($path in $temporaryFiles) {
        try {
            if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
        catch {
            $filesRemoved = $false
            $failures.Add(
                "Failed to remove temporary file '${path}': " +
                "$($_.Exception.Message)"
            )
        }
    }
    if ($folderCreated -and $filesRemoved) {
        try {
            Remove-Item -LiteralPath $tempFolder -Force -ErrorAction Stop
        }
        catch {
            $failures.Add(
                "Failed to remove temporary folder '${tempFolder}': " +
                "$($_.Exception.Message)"
            )
        }
    }
}
if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
'Set regional settings to be applied to newly created accounts too'
