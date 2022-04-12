<#
    .SYNOPSIS
        Create registry keys.

    .DESCRIPTION
        Read the registry keys from an input file on one machine and set the 
        registry keys from the same file on another machine.
        
    .PARAMETER Action
        When action is 'Export' a template file is created that can be edited 
        by the user to contain the required registry keys. 
        When action is 'Import' the registry keys in the import file will be 
        created or updated on the current machine. 

    .PARAMETER DataFolder
        Folder where the file can be found that contains the registry keys.

    .PARAMETER RegistryKeysFileName
        File containing the registry keys.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$RegistryKeysFileName = 'registryKeys.json'
)

Begin {
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

    Try {
        $RegistryKeysFile = Join-Path -Path $DataFolder -ChildPath $RegistryKeysFileName

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $RegistryKeysFile -PathType Leaf)) {
                throw "Registry keys file '$RegistryKeysFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action registry keys failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            #region Create example config file
            Write-Verbose "Create example config file '$ExportFile'"
            $params = @{
                LiteralPath = Join-Path $PSScriptRoot 'Example.json'
                Destination = $RegistryKeysFile
            }
            Copy-Item @params
            Write-Output "Created example registry keys file '$RegistryKeysFile'"
            #endregion
        }
        else {            
            Write-Verbose "Import registry keys from file '$RegistryKeysFile'"
            $registryKeys = Get-Content -LiteralPath $RegistryKeysFile -Encoding UTF8 -Raw | 
            ConvertFrom-Json -EA Stop
     
            #region Run registry keys for current user
            foreach ($key in $registryKeys.RunAsCurrentUser.RegistryKeys) {
                & $scriptBlock -Path $key.Path -Name $key.Name -Value $key.Value -Type $key.Type
            }
            #endregion

            #region Run registry keys for another user
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
            #endregion
        }
    }
    Catch {
        throw "$Action registry keys failed: $_"
    }
}