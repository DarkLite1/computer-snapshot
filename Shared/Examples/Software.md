# Software

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [Software.json](Software.json).

## Removing software

Each entry in `Software` → `Remove` names an application as it appears in Programs and Features. Removals run before the installers.

```json
"Remove": [
  { "DisplayName": "7-Zip 23.01 (x64)" },
  { "DisplayName": "Vendor Tool*", "UninstallArguments": "/S" },
  { "DisplayName": "Old Agent", "UninstallCommand": "\"C:\\Program Files\\Old Agent\\uninstall.exe\" /quiet", "SuccessExitCodes": [0, 1] }
]
```

- `*` in `DisplayName` matches any text, so `Vendor Tool*` removes every version. Every matching application is removed, also when the same name is installed twice (32 and 64 bit). A name that matches more than 5 applications is refused, so a pattern that is too broad removes nothing; set `"AllowMultiple": true` when that many is intended.
- Without other settings, the application's quiet uninstall command from the registry is used. Windows Installer (MSI) uninstalls are made silent. Other uninstallers without a quiet command may show a window and wait for a click.
- `UninstallArguments` are added to the application's own uninstall command, to make it silent: `/S` for most NSIS uninstallers, `/VERYSILENT /NORESTART` for Inno Setup.
- `UninstallCommand` replaces the uninstall command completely. It runs once, also when several applications match.
- Exit codes work as for installers: `0`, `3010` and `1641` mean success, others can be listed in `SuccessExitCodes`.
- Applications installed for one user only, such as some Zoom or Teams installs, are found for every user who is signed in, and the report names the user. Their uninstaller runs as the account that runs the restore, which not every per-user uninstaller supports. Users who are signed out are not searched.
- Some uninstallers start a second process and end straight away. The tool gives the processes an uninstaller starts 60 seconds to finish (see below), and afterwards gives the application up to 60 seconds to disappear from Programs and Features.

## Exit codes of installers

Installers in `Software` → `Install` work the same way. `0` means success, and `3010` and `1641` always mean "success, a restart is needed". An installer that uses other codes for success, such as `1` for "already installed", lists them in `SuccessExitCodes`:

```json
"Install": [
  {
    "ExecutablePath": "Software\\VendorTool.exe",
    "Arguments": "/silent",
    "SuccessExitCodes": [0, 1]
  }
]
```

## Time limit for installers and uninstallers

Each entry in `Install` and `Remove` gets `TimeoutMinutes` to finish, by default 15, from 1 to 1440. An installer or uninstaller that is still running then, for example because it waits for a click, is stopped with the processes it started and reported as failed; the next entries still run.

```json
{ "ExecutablePath": "Software\\BigSuite.exe", "Arguments": "/quiet", "TimeoutMinutes": 60 }
```

Many installers start the installed application, a tray tool or an updater when they finish. So once the installer or uninstaller itself has ended, the processes it started get 60 more seconds to finish. Those still running then are left running, and the report names them, for example *Installed 'Software\X.exe'; 'XApp.exe' started by the installer is still running and was left alone*. That is not an error.

An installer that does its real work in a child process and ends straight away needs `"WaitForAllProcesses": true`: then every process it starts must also finish within `TimeoutMinutes`, or they are all stopped and the entry fails. The setting works the same for `Remove` entries.

```json
{ "ExecutablePath": "Software\\Bootstrapper.exe", "Arguments": "/quiet", "WaitForAllProcesses": true }
```

The tool follows the processes an installer starts by checking every 50 ms for the first 3 seconds, then every 500 ms. Windows reuses process IDs, so a process is only stopped when both its ID and its start time match the one that was seen; an unrelated process that got the same ID is never stopped. Limit: a process that starts another one and exits within about 50 ms is never seen, so the process it started can't be linked to the installer. That process is not waited for, not named in the report and not stopped when the time limit is reached.
