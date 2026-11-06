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
      signed in, with the password saved in Task Scheduler. Such a task
      needs the user right 'Log on as a batch job' (SeBatchLogonRight);
      an account without it gets it before the task is registered. A
      domain group policy that sets this right overrides the local one.
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
. "$PSScriptRoot\..\Common\Section.ps1"

#region Windows helpers
function Initialize-LsaRightsHC {
    if ('ComputerSnapshot.LsaRights' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace ComputerSnapshot {
    public static class LsaRights {
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_UNICODE_STRING {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_OBJECT_ATTRIBUTES {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }
        [DllImport("advapi32.dll")]
        static extern uint LsaOpenPolicy(IntPtr systemName,
            ref LSA_OBJECT_ATTRIBUTES attributes, uint access,
            out IntPtr policy);
        [DllImport("advapi32.dll")]
        static extern uint LsaEnumerateAccountRights(IntPtr policy,
            byte[] sid, out IntPtr rights, out uint count);
        [DllImport("advapi32.dll")]
        static extern uint LsaAddAccountRights(IntPtr policy, byte[] sid,
            LSA_UNICODE_STRING[] rights, uint count);
        [DllImport("advapi32.dll")]
        static extern uint LsaClose(IntPtr handle);
        [DllImport("advapi32.dll")]
        static extern uint LsaFreeMemory(IntPtr buffer);
        [DllImport("advapi32.dll")]
        static extern int LsaNtStatusToWinError(uint status);

        // POLICY_LOOKUP_NAMES | POLICY_CREATE_ACCOUNT
        const uint Access = 0x00000810;
        const uint ObjectNameNotFound = 0xC0000034;

        static IntPtr Open() {
            var attributes = new LSA_OBJECT_ATTRIBUTES();
            IntPtr policy;
            Check(LsaOpenPolicy(IntPtr.Zero, ref attributes, Access,
                out policy));
            return policy;
        }
        static void Check(uint status) {
            if (status != 0) {
                throw new Win32Exception(LsaNtStatusToWinError(status));
            }
        }
        static byte[] Binary(string sid) {
            var identifier = new SecurityIdentifier(sid);
            var binary = new byte[identifier.BinaryLength];
            identifier.GetBinaryForm(binary, 0);
            return binary;
        }

        public static string[] Get(string sid) {
            IntPtr policy = Open();
            try {
                IntPtr rights;
                uint count;
                uint status = LsaEnumerateAccountRights(policy, Binary(sid),
                    out rights, out count);
                if (status == ObjectNameNotFound) { return new string[0]; }
                Check(status);
                try {
                    var result = new string[count];
                    int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
                    for (int i = 0; i < count; i++) {
                        var right = (LSA_UNICODE_STRING)Marshal.PtrToStructure(
                            new IntPtr(rights.ToInt64() + i * size),
                            typeof(LSA_UNICODE_STRING));
                        result[i] = Marshal.PtrToStringUni(
                            right.Buffer, right.Length / 2);
                    }
                    return result;
                }
                finally { LsaFreeMemory(rights); }
            }
            finally { LsaClose(policy); }
        }

        public static void Add(string sid, string name) {
            IntPtr policy = Open();
            IntPtr buffer = Marshal.StringToHGlobalUni(name);
            try {
                var right = new LSA_UNICODE_STRING();
                right.Buffer = buffer;
                right.Length = (ushort)(name.Length * 2);
                right.MaximumLength = (ushort)((name.Length + 1) * 2);
                Check(LsaAddAccountRights(policy, Binary(sid),
                    new LSA_UNICODE_STRING[] { right }, 1));
            }
            finally {
                Marshal.FreeHGlobal(buffer);
                LsaClose(policy);
            }
        }
    }
}
'@
}

function Get-AccountSidHC {
    param([Parameter(Mandatory)][string]$Name)
    ([Security.Principal.NTAccount]$Name).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
}

function Get-AccountRightsHC {
    # The rights given to the account itself, not through its groups
    param([Parameter(Mandatory)][string]$Sid)
    Initialize-LsaRightsHC
    [ComputerSnapshot.LsaRights]::Get($Sid)
}

function Add-AccountRightHC {
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Right
    )
    Initialize-LsaRightsHC
    [ComputerSnapshot.LsaRights]::Add($Sid, $Right)
}
#endregion

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
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import scheduled tasks: section is empty, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    $folders = @(Get-ExportTaskFolderHC -Options $Data)
    Write-Verbose "Export scheduled tasks in '$($folders -join "', '")'"

    # A folder that does not exist has no tasks to export; nested folders
    # can return the same task twice
    $tasks = @(
        foreach ($folder in $folders) {
            $getTaskParams = @{
                TaskPath    = "$folder*"
                ErrorAction = 'SilentlyContinue'
            }
            Get-ScheduledTask @getTaskParams
        }
    ) | Sort-Object -Property TaskPath, TaskName -Unique
    Write-Verbose "Found $(@($tasks).Count) scheduled task(s)"

    $exportData = @(
        foreach ($task in @($tasks)) {
            try {
                Write-Verbose (
                    "Task '$($task.TaskPath)$($task.TaskName)': export"
                )
                $exportTaskParams = @{
                    TaskName = $task.TaskName
                    TaskPath = $task.TaskPath
                }
                $xml = Export-ScheduledTask @exportTaskParams

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
                    $messages.Add(
                        "Task '$($task.TaskPath)$($task.TaskName)' runs " +
                        "for group '$($task.Principal.GroupId)', which " +
                        'cannot be exported; it is restored to run as ' +
                        'SYSTEM unless you set RunAsUser'
                    )
                }

                [pscustomobject]$exportTask
            }
            catch {
                $errors.Add(
                    "Failed to export scheduled task " +
                    "'$($task.TaskPath)$($task.TaskName)': " +
                    $_.Exception.Message
                )
            }
        }
    )
    #endregion

    $messages.Insert(
        0,
        "Exported $($exportData.Count) scheduled task(s) from the task " +
        "folder(s) '$($folders -join "', '")'"
    )
}
else {
    #region Apply section
    Write-Verbose 'Import scheduled tasks'
    foreach ($task in @($Data | Where-Object { $null -ne $_ })) {
        $fullName = "$($task.TaskPath)$($task.TaskName)"
        Write-Verbose "Task '$fullName': register"

        try {
            $xml = Get-TaskXmlHC -Task $task -RootFolder $RootFolder

            $getTaskParams = @{
                TaskName    = $task.TaskName
                TaskPath    = $task.TaskPath
                ErrorAction = 'SilentlyContinue'
            }
            $exists = [bool](Get-ScheduledTask @getTaskParams)

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
                $registerParams.User = Convert-AccountNameHC -Name (
                    $task.RunAsUser
                )
                $runAs = "'$($registerParams.User)'"

                if ($task.RunAsPassword) {
                    $registerParams.Password = [string]$task.RunAsPassword
                    $runAs += ' with saved password'

                    # Task Scheduler refuses the account without this right
                    $sid = Get-AccountSidHC -Name $registerParams.User
                    $right = 'SeBatchLogonRight'
                    if (@(Get-AccountRightsHC -Sid $sid) -notcontains $right) {
                        Write-Verbose (
                            "Task '$fullName': grant '$right' to " +
                            "'$($registerParams.User)'"
                        )
                        Add-AccountRightHC -Sid $sid -Right $right
                        $messages.Add(
                            "Granted 'Log on as a batch job' to " +
                            "'$($registerParams.User)', needed for " +
                            "scheduled task '$fullName'"
                        )
                    }
                }
            }

            Write-Verbose "Task '$fullName': exists '$exists', runs as $runAs"
            $null = Register-ScheduledTask @registerParams

            $taskParams = @{
                TaskPath = $task.TaskPath
                TaskName = $task.TaskName
            }
            if ($task.Enabled) {
                $state = 'enabled'
                $null = Enable-ScheduledTask @taskParams
            }
            else {
                $state = 'disabled'
                $null = Disable-ScheduledTask @taskParams
            }
            Write-Verbose "Task '$fullName': $state"

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

            $messages.Add(
                "$verb scheduled task '$fullName'$source " +
                "($state, runs as $runAs)"
            )
        }
        catch {
            $errors.Add(
                "Failed to register scheduled task '$fullName': " +
                $_.Exception.Message
            )
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