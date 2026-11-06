#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Registry keys as a configuration section.
.DESCRIPTION
    Import applies each entry in RunAsCurrentUser, then the entries of each
    user in RunAsOtherUser. An entry's Action decides what happens:
    - Set (default): create or change a value. Missing keys are created,
      including parent keys. A value with the right data but the wrong type
      is corrected; an unchanged value is not rewritten.
    - RemoveValue: remove one value.
    - ClearValues: remove all values of a key, keep its subkeys.
    - ClearKey: remove all values and subkeys of a key, keep the key.
    - RemoveKey: remove a key with everything in it.
    Name '' is the key's (Default) value. Types: String, ExpandString,
    MultiString (a list), Binary (hex such as '01 0A FF' or a list of bytes),
    DWord and QWord (decimal or 0x hexadecimal). Removing something that does
    not exist is reported, not an error. ClearValues, ClearKey and RemoveKey
    are refused for a hive root or a key directly below it.

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
. "$PSScriptRoot\..\Common\Section.ps1"
. "$PSScriptRoot\..\Common\Registry.ps1"

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
        Write-Verbose "Create registry key '$keyPath'"
        $key = New-Item -Path $keyPath
        # Release the handle, a loaded user hive cannot be unloaded while it
        # is open
        if ($key.Handle) { $key.Handle.Close() }
    }
}

function Get-RegistryKeyStateHC {
    <#
    .SYNOPSIS
        Read a key: whether it exists, its value names and subkey names, and
        optionally one value with its type.
    .DESCRIPTION
        ExpandString values are read without expanding %variables%, so they
        compare with the configured text. The key is closed again, because a
        loaded user hive cannot be unloaded while a key is open.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Name
    )

    $state = [pscustomobject]@{
        KeyExists   = $false
        ValueNames  = @()
        SubKeyNames = @()
        ValueExists = $false
        Value       = $null
        Kind        = $null
    }

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) {
        return $state
    }

    try {
        $state.KeyExists = $true
        $state.ValueNames = @($key.GetValueNames())
        $state.SubKeyNames = @($key.GetSubKeyNames())

        if (
            $PSBoundParameters.ContainsKey('Name') -and
            $state.ValueNames -contains $Name
        ) {
            $valueOptions = [Microsoft.Win32.RegistryValueOptions]

            $state.ValueExists = $true
            $state.Value = $key.GetValue(
                $Name, $null,
                $valueOptions::DoNotExpandEnvironmentNames
            )
            $state.Kind = [string]$key.GetValueKind($Name)
        }
    }
    finally {
        if ($key -is [IDisposable]) { $key.Dispose() }
    }

    $state
}

function Get-PropertyNameHC {
    # The registry provider calls the (Default) value '(default)'
    param([AllowEmptyString()][string]$Name)

    if ($Name -eq '') { '(default)' } else { $Name }
}

function Invoke-RegistryEntryHC {
    # Apply one entry; returns the message, throws on failure
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Path
    )

    $action = if ($Entry.Action) { [string]$Entry.Action } else { 'Set' }
    $name = [string]$Entry.Name
    $displayName = if ($name -eq '') { '(Default)' } else { $name }
    $label = "Registry value '$displayName' in '$($Entry.Path)'"

    Write-Verbose "${label}: $action"

    switch ($action) {
        'Set' {
            $type = ConvertTo-RegistryTypeHC -Type ([string]$Entry.Type)
            $data = ConvertTo-RegistryDataHC -Value $Entry.Value -Type $type
            $text = Format-RegistryDataHC -Value $data -Type $type
            $state = Get-RegistryKeyStateHC -Path $Path -Name $name
            $newParams = @{
                LiteralPath  = $Path
                Name         = Get-PropertyNameHC $name
                Value        = $data
                PropertyType = $type
                Force        = $true
            }

            if (-not $state.KeyExists) {
                New-RegistryKeyHC -Path $Path
                $null = New-ItemProperty @newParams
                return (
                    "$label created as $type '$text', " +
                    'including its registry key'
                )
            }
            if (-not $state.ValueExists) {
                $null = New-ItemProperty @newParams
                return "$label created as $type '$text'"
            }
            if ($state.Kind -ne $type) {
                $null = New-ItemProperty @newParams
                return (
                    "$label updated from type '$($state.Kind)' " +
                    "to $type '$text'"
                )
            }
            $equalParams = @{
                Current = $state.Value
                Desired = $data
            }
            if (-not (Test-RegistryDataEqualHC @equalParams)) {
                $null = New-ItemProperty @newParams
                $old = Format-RegistryDataHC -Value $state.Value -Type $type
                return "$label updated from '$old' to '$text'"
            }
            return "$label is already correct"
        }
        'RemoveValue' {
            $state = Get-RegistryKeyStateHC -Path $Path -Name $name
            if (-not $state.ValueExists) {
                return "$label does not exist, nothing to remove"
            }
            $params = @{
                LiteralPath = $Path
                Name        = Get-PropertyNameHC $name
            }
            Remove-ItemProperty @params
            return (
                "Removed registry value '$displayName' " +
                "from '$($Entry.Path)'"
            )
        }
        default {
            # ClearValues, ClearKey and RemoveKey work on the whole key
            $registryPath = ConvertTo-RegistryPathHC $Entry.Path
            if (Test-BroadRegistryKeyHC -Path $registryPath) {
                throw (
                    'refused for a hive root or a key directly below it; ' +
                    'use a more specific key'
                )
            }

            $state = Get-RegistryKeyStateHC -Path $Path
            if (-not $state.KeyExists) {
                $verb = if ($action -eq 'RemoveKey') {
                    'remove'
                }
                else {
                    'clear'
                }
                return (
                    "Registry key '$($Entry.Path)' does not exist, " +
                    "nothing to $verb"
                )
            }

            if ($action -eq 'RemoveKey') {
                Write-Verbose "Remove registry key '$Path'"
                Remove-Item -LiteralPath $Path -Recurse -Force
                return (
                    "Removed registry key '$($Entry.Path)' " +
                    'with everything in it'
                )
            }

            if ($action -eq 'ClearKey') {
                foreach ($subKeyName in $state.SubKeyNames) {
                    Remove-Item -LiteralPath "$Path\$subKeyName" -Recurse -Force
                }
            }
            foreach ($valueName in $state.ValueNames) {
                $params = @{
                    LiteralPath = $Path
                    Name        = Get-PropertyNameHC $valueName
                }
                Remove-ItemProperty @params
            }

            if ($action -eq 'ClearKey') {
                return (
                    "Cleared registry key '$($Entry.Path)': " +
                    "removed $($state.ValueNames.Count) value(s) and " +
                    "$($state.SubKeyNames.Count) subkey(s)"
                )
            }
            return (
                "Cleared the values of registry key '$($Entry.Path)': " +
                "removed $($state.ValueNames.Count) value(s), " +
                'kept its subkeys'
            )
        }
    }
}

function Get-RegistryEntryLabelHC {
    # What an entry does, for error messages
    param([Parameter(Mandatory)]$Entry)

    $name = if ([string]$Entry.Name -eq '') {
        '(Default)'
    }
    else {
        $Entry.Name
    }

    switch ([string]$(if ($Entry.Action) { $Entry.Action } else { 'Set' })) {
        'Set' {
            "set registry value '$name' in '$($Entry.Path)' to " +
            "'$(Format-RegistryDataHC -Value $Entry.Value)' " +
            "with type '$($Entry.Type)'"
        }
        'RemoveValue' {
            "remove registry value '$name' from '$($Entry.Path)'"
        }
        'ClearValues' {
            "clear the values of registry key '$($Entry.Path)'"
        }
        'ClearKey' { "clear registry key '$($Entry.Path)'" }
        'RemoveKey' { "remove registry key '$($Entry.Path)'" }
        default { "apply Action '$($Entry.Action)' to '$($Entry.Path)'" }
    }
}

function Set-RegistryValuesHC {
    # Apply each entry independently; HKCU is redirected to $UserRoot when
    # given
    param($RegistryKeys, [string]$UserRoot, [string]$UserLabel)

    $hkcuPattern = '^(HKCU:|Registry::HKEY_CURRENT_USER)(?=\\|$)'

    # A missing section is $null, and @($null) would loop once over nothing
    foreach ($entry in @($RegistryKeys | Where-Object { $null -ne $_ })) {
        $prefix = if ($UserLabel) { "User '$UserLabel': " } else { '' }
        try {
            $problems = @(Get-RegistryEntryProblemHC -Entry $entry)
            if ($problems.Count) { throw ($problems -join '; ') }

            $path = ConvertTo-RegistryPathHC -Path $entry.Path
            if ($UserRoot) {
                $path = $path -replace $hkcuPattern, $UserRoot
            }

            $messages.Add(
                $prefix + (Invoke-RegistryEntryHC -Entry $entry -Path $path)
            )
        }
        catch {
            $errors.Add(
                "${prefix}Failed to " +
                "$(Get-RegistryEntryLabelHC -Entry $entry): " +
                "$($_.Exception.Message)"
            )
        }
    }
}

function Get-UserSidHC {
    param([Parameter(Mandatory)][string]$UserName)

    try {
        ([System.Security.Principal.NTAccount]$UserName).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {
        throw "user account '$UserName' does not exist"
    }
}

function Get-UserProfilePathHC {
    param([Parameter(Mandatory)][string]$Sid)

    $profileKey = (
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' +
        "ProfileList\$Sid"
    )
    if (Test-Path -LiteralPath $profileKey) {
        [Environment]::ExpandEnvironmentVariables(
            (Get-ItemProperty -LiteralPath $profileKey).ProfileImagePath
        )
    }
}

function New-UserProfileHC {
    # Starting a process with the user's profile makes Windows create it
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )

    $params = @{
        String      = $Password
        AsPlainText = $true
        Force       = $true
    }
    $securePassword = ConvertTo-SecureString @params

    $credential = New-Object System.Management.Automation.PSCredential (
        $UserName, $securePassword
    )

    Write-Verbose "Create the user profile of '$UserName'"

    $params = @{
        FilePath         = 'powershell.exe'
        WorkingDirectory = "$env:SystemRoot\System32"
        Credential       = $credential
        ArgumentList     = '-Command', 1
        WindowStyle      = 'Hidden'
        LoadUserProfile  = $true
        Wait             = $true
    }
    Start-Process @params
}

function Invoke-RegExeHC {
    param([Parameter(Mandatory)][string]$Arguments)

    Write-Verbose "reg.exe $Arguments"

    $params = @{
        FilePath     = 'reg.exe'
        ArgumentList = $Arguments
        WindowStyle  = 'Hidden'
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @params

    if ($process.ExitCode) {
        throw (
            "reg.exe $Arguments failed with exit code " +
            "$($process.ExitCode)"
        )
    }
}
#endregion

$exportData = $null

# Lists, so the helper functions can add to them from their own scope
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Registry keys: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    # Which values were set on purpose can not be read from the registry
    Write-Verbose 'Export Registry keys: an empty section to fill in'
    $exportData = [ordered]@{}
    #endregion

    $messages.Add(
        'Nothing to export: add the registry values to set, see ' +
        'Examples\RegistryKeys.json'
    )
}
else {
    #region Apply section
    Write-Verbose 'Import Registry keys for the current user'
    Set-RegistryValuesHC -RegistryKeys $Data.RunAsCurrentUser.RegistryKeys

    foreach ($user in @($Data.RunAsOtherUser | Where-Object { $null -ne $_ })) {
        Write-Verbose "Import Registry keys for user '$($user.UserName)'"

        $tempKey = $null
        try {
            if (-not $user.UserName) {
                throw (
                    "the property 'UserName' is required in " +
                    "'RunAsOtherUser'"
                )
            }
            $sid = Get-UserSidHC -UserName $user.UserName

            if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") {
                # Signed in: the user's registry is already loaded
                Write-Verbose "User '$($user.UserName)': registry is loaded"
                $userRoot = "Registry::HKEY_USERS\$sid"
            }
            else {
                #region Create the profile when needed
                $profilePath = Get-UserProfilePathHC -Sid $sid
                $ntUserFile = "$profilePath\NTUSER.DAT"
                if (
                    -not $profilePath -or
                    -not (Test-Path -LiteralPath $ntUserFile -PathType Leaf)
                ) {
                    if (-not $user.UserPassword) {
                        throw (
                            'the user has no profile yet; ' +
                            "'UserPassword' is required to create it"
                        )
                    }
                    $params = @{
                        UserName = $user.UserName
                        Password = $user.UserPassword
                    }
                    New-UserProfileHC @params
                    $profilePath = Get-UserProfilePathHC -Sid $sid
                    $ntUserFile = "$profilePath\NTUSER.DAT"
                    if (
                        -not $profilePath -or
                        -not (Test-Path -LiteralPath $ntUserFile -PathType Leaf)
                    ) {
                        throw 'the user profile could not be created'
                    }
                    $messages.Add(
                        "Created the user profile of '$($user.UserName)'"
                    )
                }
                #endregion

                #region Load the user's registry under a temporary name
                $name = 'ComputerSnapshot_{0}' -f (
                    [guid]::NewGuid().ToString('N')
                )
                Invoke-RegExeHC -Arguments (
                    'load "HKEY_USERS\{0}" "{1}"' -f
                    $name, "$profilePath\NTUSER.DAT"
                )
                $tempKey = "HKEY_USERS\$name"
                $userRoot = "Registry::$tempKey"
                #endregion
            }

            $params = @{
                RegistryKeys = $user.RegistryKeys
                UserRoot     = $userRoot
                UserLabel    = $user.UserName
            }
            Set-RegistryValuesHC @params
        }
        catch {
            $errors.Add(
                'Failed to set the registry values of user ' +
                "'$($user.UserName)': $($_.Exception.Message)"
            )
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
                    $errors.Add(
                        'Failed to unload the registry of user ' +
                        "'$($user.UserName)' from '$tempKey'; " +
                        'it unloads at the next restart: ' +
                        "$($_.Exception.Message)"
                    )
                }
                #endregion
            }
        }
    }
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams