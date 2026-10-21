#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Registry keys as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers

#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}
$scriptBlock = {
        Param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [String]$Name,
            [Parameter(Mandatory)]
            [String]$Value,
            [Parameter(Mandatory)]
            [String]$Type
        )
        try {
            try {
                $idString = "Registry path '$Path' key name '$Name' value '$Value' type '$Type'"
                Write-Verbose $idString
            
                $newParams = @{
                    Path         = $Path
                    Name         = $Name
                    Value        = $Value
                    PropertyType = $Type
                    Force        = $true
                    ErrorAction  = 'Stop'
                }
                $getParams = @{
                    Path        = $Path
                    Name        = $Name
                    ErrorAction = 'Stop'
                }
                $currentValue = (Get-ItemProperty @getParams).($Name)

                if ($currentValue -ne $Value) {
                    Write-Verbose "Update old value '$currentValue' with new value '$Value'"
                    $null = New-ItemProperty @newParams
                    Write-Output "$idString not correct. Updated old value '$currentValue' with new value '$Value'."
                }
                else {
                    Write-Verbose 'Registry key correct'
                    Write-Output "$idString correct. Nothing to update."
                }
            }
            catch [System.Management.Automation.PSArgumentException] {
                $Error.RemoveAt(0)
                Write-Verbose 'Add key name and value on existing path'
                $null = New-ItemProperty @newParams
                Write-Output "$idString. Created key name and value on existing path."
            }
            catch [System.Management.Automation.ItemNotFoundException] {
                $Error.RemoveAt(0)
                Write-Verbose 'Add new registry key'
                $n = New-Item -Path $Path -ErrorAction Stop
                $n.Handle.Close()

                $null = New-ItemProperty @newParams
                Write-Output "$idString did not exist. Created new registry key."
            }
        }
        catch {
            Write-Error "Failed to set registry path '$Path' with key name '$Name' to value '$Value' with type '$Type': $_"
            $Error.RemoveAt(1)
        }
    }
if ($Action -eq 'Export') {
    #region Capture section
$exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\RegistryKeys.json"
    #endregion
    $messages = @('Exported Registry keys')
}
else {
    #region Apply section
    $messages = @(& {

$registryKeys = $Data
foreach ($key in $registryKeys.RunAsCurrentUser.RegistryKeys) {
                & $scriptBlock -Path $key.Path -Name $key.Name -Value $key.Value -Type $key.Type
            }
foreach ($user in $registryKeys.RunAsOtherUser) {
                if (-not $user.UserName) {
                    Throw "Property 'UserName' is mandatory in 'RunAsOtherUser'"
                }

                $ntUserFile = "C:\Users\$($user.UserName)\NTUSER.DAT"
                $tempKey = "HKEY_USERS\$($user.UserName)"

                #region Create other user's profile
                if (-not (Test-Path -LiteralPath $ntUserFile -PathType Leaf)) {
                    if (-not $user.UserPassword) {
                        Throw "Property 'UserPassword' is mandatory in 'RunAsOtherUser' when the user account doesn't exist yet"
                    }

                    $convertParams = @{
                        String      = $user.UserPassword
                        AsPlainText = $true
                        Force       = $true
                    }
                    $securePassword = ConvertTo-SecureString @convertParams
                    $credential = New-Object System.Management.Automation.PSCredential $user.UserName, $securePassword

                    Write-Verbose "Create user profile folders"
                    $params = @{
                        FilePath         = 'powershell.exe'
                        WorkingDirectory = 'C:\Windows\System32'
                        Credential       = $credential
                        ArgumentList     = '-Command', 1
                        WindowStyle      = 'Hidden'
                        LoadUserProfile  = $true
                        Wait             = $true
                    }
                    Start-Process @params
                    "Created user profile folders for '$($user.UserName)'"
                }

                if (-not (Test-Path -LiteralPath $ntUserFile -PathType Leaf)) {
                    throw "File '$ntUserFile' not found for user '$($user.UserName)'"
                }
                #endregion
                
                #region Load other user's profile
                $startParams = @{
                    FilePath     = 'reg.exe'
                    ArgumentList = "load `"$tempKey`" `"$ntUserFile`"" 
                    WindowStyle  = 'Hidden'
                    Wait         = $true
                    PassThru     = $true
                }
                $process = Start-Process @startParams
                
                if ($process.ExitCode) {
                    throw "Failed to load the user profile '$($user.UserName)': exit code $($process.ExitCode)"
                }
                
                if (
                    -not (Test-Path -Path "Registry::HKEY_USERS\$($user.UserName)")
                ) {
                    throw "Failed to load the registry hive '$tempKey' from file '$ntUserFile' for user '$($user.UserName)'"
                }
                #endregion
                
                #region Map user's profile
                $driveParams = @{
                    PSProvider = 'Registry'
                    Name       = 'HKU'
                    Root       = 'HKEY_USERS'
                }
                $null = New-PSDrive @driveParams
                
                if (-not (Test-Path -Path "HKU:\$($user.UserName)")) {
                    throw "Failed to load the registry for user '$($user.UserName)'"
                }
                #endregion
                
                #region apply changes to user's profile
                foreach ($key in $user.RegistryKeys) {
                    $path = if ($key.Path -match '^HKCU:\\') {
                        $key.Path -replace '^HKCU:\\', "HKU:\$($user.UserName)\"
                    }
                    else {
                        $key.Path
                    }

                    & $scriptBlock -Path $path -Name $key.Name -Value $key.Value -Type $key.Type
                }
                #endregion
                
                #region Unload user's profile
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                Remove-PSDrive -Name $driveParams.Name

                $startParams = @{
                    FilePath     = 'reg.exe'
                    ArgumentList = "unload `"$tempKey`""
                    WindowStyle  = 'Hidden'
                    Wait         = $true
                    PassThru     = $true
                }
                $process = Start-Process @startParams
                
                if ($process.ExitCode) {
                    throw "Failed to unload the temporary profile: exit code $($process.ExitCode)"
                }
                #endregion
            }
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
