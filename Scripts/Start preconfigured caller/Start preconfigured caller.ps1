Param (
    [String]$StartScript = '.\Start-Script.ps1',
    [String]$PreconfiguredCallersFolder = '.\Preconfigured callers'
)

Begin {
    Function Test-IsStartedElevatedHC {
        <#
        .SYNOPSIS
            Check if the script is started in elevated mode
        
        .DESCRIPTION
            Some PowerShell scripts required to be run as administrator 
            and in elevated mode to function property.
        #>
        
        Try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
            $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        Catch {
            throw "Failed to determine if the script is started in elevated mode: $_"
        }
    }

    try {
        #region Get full paths
        $params = @{
            Path        = $StartScript
            ErrorAction = 'Ignore'
        }
        $startScriptPath = Convert-Path @params

        $params.Path = $PreconfiguredCallersFolder
        $preconfiguredCallersFolderPath = Convert-Path @params
        #endregion
        
        #region Test folder and file available
        If (
            (-not $startScriptPath) -or
            (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf))
        ) {
            throw "Start script '$StartScript' not found"
        }
        If (
            (-not $preconfiguredCallersFolderPath) -or
            (-not (Test-Path -LiteralPath $preconfiguredCallersFolderPath -PathType Container))
        ) {
            throw "Preconfigured callers folder '$PreconfiguredCallersFolder' not found"
        }
        If (
            (Get-ChildItem -Path $preconfiguredCallersFolderPath -File -Recurse -Filter '*.json' | Measure-Object).Count -eq 0
        ) {
            throw "No .JSON file found in folder '$preconfiguredCallersFolderPath'. Please create a pre-configuration file first."
        }
        #endregion
    }
    catch {
        Write-Warning 'Failed to start the preconfigured caller script:'
        Write-Warning $_
        Start-Sleep -Seconds 20
        Exit
    }
}

Process {
    if (Test-IsStartedElevatedHC) {
        $params = @{
            Action                             = 'RestoreSnapshot'
            RestoreSnapshotFolder              = 'Snapshots\AGG SGX Borne NL'
            RebootComputerAfterRestoreSnapshot = $true
            OpenReportInBrowser                = $true
            Snapshot                           = [Ordered]@{
                StartCustomScriptsBefore = $true
                RegionalSettings         = $false # on
                UserAccounts             = $false # on
                UserGroups               = $false
                FirewallRules            = $false
                CreateFolders            = $false
                SmbShares                = $false
                Software                 = $false # on
                NetworkCards             = $false
                NtpTimeServers           = $false # on
                RegistryKeys             = $false # on
                ScheduledTasks           = $false # on
                CopyFilesFolders         = $false # on
                StartCustomScriptsAfter  = $false # on
            }
        }
        # & $StartScript @params
        
        Start-Sleep -Seconds 15
    }
    else {
        # relaunch current script as an elevated process
        Write-Host 'Please accept the prompt to start the script in elevated mode'
      
        Start-Process powershell.exe "-File", ('"{0}"' -f $MyInvocation.MyCommand.Path) -Verb RunAs
        Exit
    }
}