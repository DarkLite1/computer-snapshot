<#
    .SYNOPSIS
        Copy files from one location to another.

    .DESCRIPTION
        When action is 'Export' the script will create an example file that can 
        be used with action set to 'Import'.

        When action is 'Import' the import file is read and all files and 
        folder in the file will be copied.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DataFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER FileName
        The file containing the paths to the files or folders to copy, with the 
        from and to fields.

    .PARAMETER DataFolder
        Folder where the export or import file can be found.

    .EXAMPLE
        $params = @{
            Action     = 'Export'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Create the example file 'C:\copy\copy.json' that can be used later on 
        with action 'Import'.

    .EXAMPLE
        $params = @{
            Action     = 'Import'
            DataFolder = 'C:\copy'
            FileName   = 'copy.json'
        }
        & 'C:\script' @params

        Read the file 'C:\copy\copy.json' and execute all copy actions defined 
        in the file.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'CopyFilesFolders.json',
    [String]$ScheduledTaskFileName = 'Monitor SSD scheduled task.json',
    [String]$ScriptFolder = 'C:\PowerShell'
)

Begin {
    Try {
        $ExportFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            If (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
                throw "Import file '$ExportFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose "Create example file '$ExportFile'"
            ConvertTo-Json @(
                @{
                    From = 'Monitor SSD.ps1'
                    To   = 'C:\HC'
                }
            ) | Out-File -FilePath $ExportFile -Encoding utf8
            Write-Output "Created example file '$ExportFile'"
        }
        else {
            if (-not (Test-Path -Path $ScriptFolder -PathType Container)) {
                New-Item $ScriptFolder -ItemType Directory -EA Stop
            }
            Write-Verbose "Copy PowerShell script '$ExportScriptFile' to ''"
            Write-Verbose "Create scheduled task"
        }
    }
    Catch {
        throw "$Action failed: $_"
    }
}