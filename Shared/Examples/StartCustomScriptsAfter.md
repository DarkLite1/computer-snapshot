# StartCustomScriptsBefore and StartCustomScriptsAfter

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [StartCustomScriptsAfter.json](StartCustomScriptsAfter.json).

## Exit codes of custom scripts

`StartCustomScriptsBefore` and `StartCustomScriptsAfter` run your own
PowerShell scripts. A script fails when it writes an error, throws, or ends
with an exit code other than `0`. The exit code is the one from `exit <code>`,
or from the program the script ran last.

Some programs use other codes for success. `robocopy`, for example, returns
`1` to `7` when it copied files, and only `8` and higher mean failure. List
those codes in `SuccessExitCodes` for a script that ends with robocopy:

```json
"StartCustomScriptsAfter": [
  {
    "Path": "Files\\Copy logs.ps1",
    "SuccessExitCodes": [0, 1, 2, 3, 4, 5, 6, 7]
  }
]
```

## Example: Dell driver updates after a restore

[Shared/Examples/StartCustomScriptsAfter.json](StartCustomScriptsAfter.json)
runs [Files/Update Dell drivers.ps1](../../Files/Update%20Dell%20drivers.ps1) after the
other restore sections. This example is opt-in; it is not enabled in the
shipped configurations. Add this entry inside your configuration's `Items`:

```json
"StartCustomScriptsAfter": "Shared\\Examples\\StartCustomScriptsAfter.json"
```

- Install Dell Command Update first, either beforehand or through
  `Software.Install` using your reviewed installer and its silent arguments.
  The wrapper does not download or install Command Update itself.
- Run the restore as administrator on a supported Dell computer, with access
  to Command Update's configured update source.
- Only drivers are selected (`-updateType=driver`); BIOS and firmware updates
  are deliberately excluded.
- The script waits for Command Update and disables its automatic restart.
  Also leave **Restart computer after successful restore** unchecked
  (`Settings.RebootComputer: false`) if you want to restart manually.
- Each run writes a separate log under
  `%ProgramData%\ComputerSnapshot\Logs` and includes its path in the restore
  report.
- Dell exit codes `0` (success), `1` (restart required) and `500` (no applicable
  updates) become successful script outcomes. Code `1` adds a warning to the
  report; it does not schedule a restart. Code `5` (a restart is already
  pending) and all other codes fail the action instead of pretending updates
  were installed. After a pending restart, reboot and rerun the action.

Review the CLI options and exit codes for the Dell Command Update version
you deploy. Driver installation can temporarily interrupt network access, so
prefer running this locally rather than relying on a remote connection.
