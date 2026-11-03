#Requires -Version 5.1

<#
.SYNOPSIS
    Export or import Scheduled tasks as a configuration section.
.DESCRIPTION
    Export captures the tasks in one or more task folders and their
    subfolders, each with its complete XML and enabled state. The folders
    come from Data.TaskPath (export options), by default '\HC\'.

    Import registers each task from its XML: inline in Xml, or from XmlFile,
    a file exported from Task Scheduler (right-click a task, Export...). A
    task with the same name and path is replaced; Windows only replaces it
    when the new definition is valid, so a failed registration keeps the
    existing task. Afterwards each task is enabled or disabled as
    configured. Each failed task is reported in Errors and the remaining
    tasks are still processed.

    The account a task runs as:
    - RunAsUser and RunAsPassword: that user, whether or not the user is
      signed in, with the password saved in Task Scheduler.
    - RunAsUser only: that account, for example a service account such as
      LOCAL SERVICE, or a user when the task only runs while signed in.
    - Neither: SYSTEM.
    Export writes RunAsUser for each task, and a {{password:...}}
    placeholder in RunAsPassword for a task that has a saved password.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Import: resolved section data. An empty section performs no operations.
    Export: optional export options, @{ TaskPath = '\HC\', '\Vendor\' }.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')]
    [string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common\Section.ps1"

#region Helpers
function Get-TaskRunAsHC {
    # RunAsUser and RunAsPassword to export for a task's principal
    param(
        [Parameter(Mandatory)]$Task
    )

    $principal = $Task.Principal
    $result = [ordered]@{}

    if (-not $principal -or -not $principal.UserId) {
        # A group principal cannot be expressed; the task runs as SYSTEM
        return $result
    }

    $result.RunAsUser = ConvertTo-PortableAccountNameHC -Name $principal.UserId

    if ([string]$principal.LogonType -eq 'Password') {
        $result.RunAsPassword = (
            "{{password:Password of '$($principal.UserId)' for scheduled " +
            "task '$($Task.TaskPath)$($Task.TaskName)'}}"
        )
    }

    $result
}

function Get-TaskXmlHC {
    # The task XML, inline or from an exported Task Scheduler file
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$RootFolder
    )

    $hasXml = -not [string]::IsNullOrWhiteSpace($Task.Xml)
    $hasXmlFile = -not [string]::IsNullOrWhiteSpace($Task.XmlFile)

    if ($hasXml -and $hasXmlFile) {
        throw 'use either Xml or XmlFile, not both'
    }

    if ($hasXml) {
        return [string]$Task.Xml
    }

    if (-not $hasXmlFile) {
        throw 'the task needs Xml or XmlFile'
    }

    $path = Resolve-RootPathHC -Path $Task.XmlFile -RootFolder $RootFolder

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "the file '$path' does not exist"
    }

    # Task Scheduler writes UTF-16 with a byte order mark, which Get-Content
    # detects; other encodings with a byte order mark work as well
    Get-Content -LiteralPath $path -Raw
}
#endregion

$exportData = $null
$messages = @()
$errors = @()

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{
        Data     = $null
        Messages = [string[]]@('Nothing to do')
        Errors   = [string[]]@()
    }
}

if ($Action -eq 'Export') {
    #region Capture section
    $folders = @(Get-ExportTaskFolderHC -Options $Data)

    # A folder that does not exist has no tasks to export; nested folders
    # can return the same task twice
    $tasks = @(
        foreach ($folder in $folders) {
            Get-ScheduledTask `
                -TaskPath "$folder*" -ErrorAction SilentlyContinue
        }
    ) | Sort-Object -Property TaskPath, TaskName -Unique

    $exportData = @(
        foreach ($task in @($tasks)) {
            try {
                $xml = Export-ScheduledTask `
                    -TaskName $task.TaskName -TaskPath $task.TaskPath

                $exportTask = [ordered]@{
                    TaskName = $task.TaskName
                    TaskPath = $task.TaskPath
                    Enabled  = [bool]$task.Settings.Enabled
                    Xml      = [string]$xml
                }

                $runAs = Get-TaskRunAsHC -Task $task

                foreach ($key in $runAs.Keys) {
                    $exportTask[$key] = $runAs[$key]
                }

                if (
                    -not $runAs.Contains('RunAsUser') -and
                    $task.Principal.GroupId
                ) {
                    $messages += (
                        "Task '$($task.TaskPath)$($task.TaskName)' runs " +
                        "for group '$($task.Principal.GroupId)', which " +
                        'cannot be exported; it is restored to run as ' +
                        'SYSTEM unless you set RunAsUser'
                    )
                }

                [pscustomobject]$exportTask
            }
            catch {
                $errors += (
                    "Failed to export scheduled task " +
                    "'$($task.TaskPath)$($task.TaskName)': " +
                    $_.Exception.Message
                )
            }
        }
    )
    #endregion

    $messages = @(
        "Exported $($exportData.Count) scheduled task(s) from the task " +
        "folder(s) '$($folders -join "', '")'"
    ) + @($messages)
}
else {
    #region Apply section
    foreach ($task in @($Data | Where-Object { $null -ne $_ })) {
        $fullName = "$($task.TaskPath)$($task.TaskName)"

        try {
            $xml = Get-TaskXmlHC -Task $task -RootFolder $RootFolder

            $exists = [bool](
                Get-ScheduledTask `
                    -TaskName $task.TaskName -TaskPath $task.TaskPath `
                    -ErrorAction SilentlyContinue
            )

            $registerParams = @{
                Xml      = $xml
                TaskPath = $task.TaskPath
                TaskName = $task.TaskName
                User     = 'NT AUTHORITY\SYSTEM'
                Force    = $true
            }
            $runAs = 'SYSTEM'

            if ($task.RunAsPassword -and -not $task.RunAsUser) {
                throw (
                    'RunAsPassword needs RunAsUser, ' +
                    'the account the password is for'
                )
            }

            if ($task.RunAsUser) {
                # SIDs and the exported computer's accounts get local names
                $registerParams.User = Convert-AccountNameHC `
                    -Name $task.RunAsUser
                $runAs = "'$($registerParams.User)'"

                if ($task.RunAsPassword) {
                    $registerParams.Password = [string]$task.RunAsPassword
                    $runAs += ' with saved password'
                }
            }

            $null = Register-ScheduledTask @registerParams

            if ($task.Enabled) {
                $state = 'enabled'
                $null = Enable-ScheduledTask `
                    -TaskPath $task.TaskPath -TaskName $task.TaskName
            }
            else {
                $state = 'disabled'
                $null = Disable-ScheduledTask `
                    -TaskPath $task.TaskPath -TaskName $task.TaskName
            }

            $source = if ($task.XmlFile) {
                " from '$($task.XmlFile)'"
            }
            else {
                ''
            }

            $verb = if ($exists) {
                'Replaced'
            }
            else {
                'Created'
            }

            $messages += (
                "$verb scheduled task '$fullName'$source " +
                "($state, runs as $runAs)"
            )
        }
        catch {
            $errors += (
                "Failed to register scheduled task '$fullName': " +
                $_.Exception.Message
            )
        }
    }
    #endregion
}

[pscustomobject]@{
    Data     = $exportData
    Messages = [string[]]$messages
    Errors   = [string[]]$errors
}