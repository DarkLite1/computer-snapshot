#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Registry keys as a configuration section.
.DESCRIPTION
    Import sets each registry value in RunAsCurrentUser, then the values of
    each user in RunAsOtherUser. Missing registry keys are created, including
    missing parent keys. A value that has the right data but the wrong type
    is updated as well.

    For another user, HKCU:\ paths point to that user's registry:
    - When the user is signed in, their loaded registry is used directly.
    - Otherwise their NTUSER.DAT is loaded under a temporary name and always
      unloaded again, also when setting a value fails.
    - When the user has no profile yet, it is created first, which requires
      UserPassword.

    Each failed value or user is reported in Errors and the remaining values
    and users are still processed.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
function New-RegistryKeyHC {
    # Create the key and any missing parent keys, one level at a time.
    # New-Item -Force is not used: on an existing key it removes all values.
    param([Parameter(Mandatory)][string]$Path)
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $current = $Path.TrimEnd('\')
    while ($current -and -not (Test-Path -LiteralPath $current)) {
        $missing.Insert(0, $current)
        $index = $current.LastIndexOf('\')
        if ($index -le 0) { break }
        $current = $current.Substring(0, $index)
    }
    foreach ($keyPath in $missing) {
        $key = New-Item -Path $keyPath
        # Release the handle, a loaded user hive cannot be unloaded while it is open
        if ($key.Handle) { $key.Handle.Close() }
    }
}
function Set-RegistryValueHC {
    # Returns the message for a value that was set or already correct
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Type
    )
    $label = "Registry value '$Name' in '$Path'"
    $newParams = @{ Path = $Path; Name = $Name; Value = $Value; PropertyType = $Type; Force = $true }
    try {
        $currentValue = (Get-ItemProperty -Path $Path -Name $Name).($Name)
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        New-RegistryKeyHC -Path $Path
        $null = New-ItemProperty @newParams
        return "$label created, including its registry key"
    }
    catch [System.Management.Automation.PSArgumentException] {
        # The key exists, the value does not
        $null = New-ItemProperty @newParams
        return "$label created"
    }
    if ($currentValue -ne $Value) {
        $null = New-ItemProperty @newParams
        return "$label updated from '$currentValue' to '$Value'"
    }
    $currentType = [string](Get-Item -Path $Path).GetValueKind($Name)
    if ($currentType -ne $Type) {
        $null = New-ItemProperty @newParams
        return "$label updated from type '$currentType' to '$Type'"
    }
    "$label is already correct"
}
function Set-RegistryValuesHC {
    # Set each value independently; HKCU:\ is redirected to $UserRoot when given
    param($RegistryKeys, [string]$UserRoot, [string]$UserLabel)
    foreach ($key in @($RegistryKeys)) {
        $path = $key.Path
        if ($UserRoot -and $path -match '^HKCU:\\?') {
            $path = $path -replace '^HKCU:\\?', "$UserRoot\"
        }
        try {
            $message = Set-RegistryValueHC -Path $path -Name $key.Name -Value $key.Value -Type $key.Type
            if ($UserLabel) { $message = "User '$UserLabel': $message" }
            $messages.Add($message)
        }
        catch {
            $prefix = if ($UserLabel) { "User '$UserLabel': " } else { '' }
            $errors.Add("${prefix}Failed to set registry value '$($key.Name)' in '$($key.Path)' to '$($key.Value)' with type '$($key.Type)': $($_.Exception.Message)")
        }
    }
}
function Get-UserSidHC {
    param([Parameter(Mandatory)][string]$UserName)
    try {
        ([System.Security.Principal.NTAccount]$UserName).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch { throw "user account '$UserName' does not exist" }
}
function Get-UserProfilePathHC {
    param([Parameter(Mandatory)][string]$Sid)
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path -LiteralPath $profileKey) {
        [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileKey).ProfileImagePath)
    }
}
function New-UserProfileHC {
    # Starting a process with the user's profile makes Windows create it
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$Password)
    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential $UserName, $securePassword
    Start-Process -FilePath 'powershell.exe' -WorkingDirectory "$env:SystemRoot\System32" -Credential $credential -ArgumentList '-Command', 1 -WindowStyle Hidden -LoadUserProfile -Wait
}
function Invoke-RegExeHC {
    param([Parameter(Mandatory)][string]$Arguments)
    $process = Start-Process -FilePath 'reg.exe' -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode) { throw "reg.exe $Arguments failed with exit code $($process.ExitCode)" }
}
#endregion
$exportData = $null
# Lists, so the helper functions can add to them from their own scope
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do'); Errors = [string[]]@() }
}
if ($Action -eq 'Export') {
    #region Capture section
    $exportData = Read-SectionExampleHC "$PSScriptRoot\..\Examples\RegistryKeys.json"
    #endregion
    $messages.Add('Exported Registry keys')
}
else {
    #region Apply section
    Set-RegistryValuesHC -RegistryKeys $Data.RunAsCurrentUser.RegistryKeys

    foreach ($user in @($Data.RunAsOtherUser)) {
        if (-not $user) { continue }
        $tempKey = $null
        try {
            if (-not $user.UserName) { throw "the property 'UserName' is required in 'RunAsOtherUser'" }
            $sid = Get-UserSidHC -UserName $user.UserName

            if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") {
                # Signed in: the user's registry is already loaded
                $userRoot = "Registry::HKEY_USERS\$sid"
            }
            else {
                #region Create the profile when needed
                $profilePath = Get-UserProfilePathHC -Sid $sid
                if (-not $profilePath -or -not (Test-Path -LiteralPath "$profilePath\NTUSER.DAT" -PathType Leaf)) {
                    if (-not $user.UserPassword) {
                        throw "the user has no profile yet; 'UserPassword' is required to create it"
                    }
                    New-UserProfileHC -UserName $user.UserName -Password $user.UserPassword
                    $profilePath = Get-UserProfilePathHC -Sid $sid
                    if (-not $profilePath -or -not (Test-Path -LiteralPath "$profilePath\NTUSER.DAT" -PathType Leaf)) {
                        throw 'the user profile could not be created'
                    }
                    $messages.Add("Created the user profile of '$($user.UserName)'")
                }
                #endregion

                #region Load the user's registry under a temporary name
                $name = 'ComputerSnapshot_{0}' -f [guid]::NewGuid().ToString('N')
                Invoke-RegExeHC -Arguments ('load "HKEY_USERS\{0}" "{1}"' -f $name, "$profilePath\NTUSER.DAT")
                $tempKey = "HKEY_USERS\$name"
                $userRoot = "Registry::$tempKey"
                #endregion
            }

            Set-RegistryValuesHC -RegistryKeys $user.RegistryKeys -UserRoot $userRoot -UserLabel $user.UserName
        }
        catch {
            $errors.Add("Failed to set the registry values of user '$($user.UserName)': $($_.Exception.Message)")
        }
        finally {
            if ($tempKey) {
                #region Always unload the user's registry
                try {
                    [gc]::Collect()
                    [gc]::WaitForPendingFinalizers()
                    Invoke-RegExeHC -Arguments "unload `"$tempKey`""
                }
                catch {
                    $errors.Add("Failed to unload the registry of user '$($user.UserName)' from '$tempKey'; it unloads at the next restart: $($_.Exception.Message)")
                }
                #endregion
            }
        }
    }
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages; Errors = [string[]]$errors }