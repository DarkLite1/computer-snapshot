# ScheduledTasks

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [ScheduledTasks.json](ScheduledTasks.json).

## Scheduled tasks

An export captures the tasks in the Task Scheduler folder `\HC\` and its subfolders. To export other folders, enter them in the wizard under **Scheduled task folders**, or use `-ExportOptions` on the command line (see [Command-Line Use](../../README.MD#-command-line-use)).

Each task needs its XML definition, in one of two ways:

- `Xml`: the complete XML inline, as an export writes it.
- `XmlFile`: a file exported from Task Scheduler (right-click a task, **Export...**), relative to the USB stick root unless it is a full path. This is easier to edit and review than XML inside JSON.

The account a task runs as:

| Properties                       | The task runs                                                                          |
| -------------------------------- | -------------------------------------------------------------------------------------- |
| `RunAsUser` and `RunAsPassword`  | as that user, whether or not the user is signed in; the password is saved in Task Scheduler |
| `RunAsUser` only                 | as that account: a service account such as `NT AUTHORITY\LOCAL SERVICE`, or a user while signed in |
| neither                          | as SYSTEM                                                                              |

Use a `{{password:...}}` placeholder for `RunAsPassword`, so the password is asked for during the restore and never stored in the configuration. An export does exactly that for each task with a saved password. A task that runs for a group can't be exported with its account and is restored as SYSTEM; the export report says so.

A task with a saved password needs the user right *Log on as a batch job* for its account. When the account doesn't have that right itself, the restore grants it before registering the task and says so in the report. A right that comes through a group, such as Administrators, isn't looked at, so the account then gets it directly as well. On a computer in a domain, a group policy that sets *Log on as a batch job* replaces the local list at the next policy refresh: add the account there instead.

```json
"ScheduledTasks": [
  {
    "TaskName": "Clean up logs",
    "TaskPath": "\\HC\\",
    "Enabled": true,
    "XmlFile": "Files\\Clean up logs.xml",
    "RunAsUser": "svc-cleanup",
    "RunAsPassword": "{{password:Password of svc-cleanup for the clean-up task}}"
  }
]
```
