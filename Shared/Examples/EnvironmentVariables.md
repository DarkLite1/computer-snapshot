# EnvironmentVariables

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [EnvironmentVariables.json](EnvironmentVariables.json).

## Environment variables

`EnvironmentVariables` changes variables of the computer (`Scope` `Machine`, the default) or of the account running the restore (`User`). Use `AddToList` and `RemoveFromList` for lists such as `Path`, so the rest of the list stays as it is:

```json
"EnvironmentVariables": [
  { "Name": "TOOLS_HOME", "Value": "%ProgramData%\\Tools" },
  { "Name": "Path", "Action": "AddToList", "Values": ["%ProgramData%\\Tools\\bin"] },
  { "Name": "OLD_VENDOR", "Action": "Remove" }
]
```

`%VARIABLE%` in a value is kept as it is and expanded when used, like Windows does for `Path`. Programs started after the restore see the changes, and so do the sections that run after this one, such as `CreateFolders` and `Software`. The export writes the computer variables that are not part of Windows; `Path` is not exported, add `AddToList` entries for it. A variable whose name looks like a secret, such as `SMTP_PASSWORD` or `API_TOKEN`, is exported as a `{{password:...}}` placeholder, so its value is never written to the file and the restore asks for it.
