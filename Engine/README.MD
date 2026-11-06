# 🛠️ Computer Snapshot for developers

This is the developer documentation for the folder that holds the tool itself. The [README](../README.MD) at the root explains how to use the tool.

## 📂 Layout

| Folder              | What it holds                                                                                              |
| ------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Engine/Scripts/`   | Every script: the entry points (`Invoke GUI.ps1`, `Invoke configuration.ps1`, `Invoke scripts.ps1`, `New answer file.ps1`, `Convert configuration.ps1`, `Caller.ps1`) and one `<section> import export.ps1` per section. |
| `Engine/Common/`    | Code shared by the scripts: reading, checking and writing configurations, running the sections, restore-time input. |
| `Engine/Schemas/`   | `config.schema.json`, the schema of a whole configuration, and one `<Section>.schema.json` per section for the files in `Shared/`. |
| `Engine/Tests/`     | The Pester tests, their helpers in `Common/` and test data in `Fixtures/`.                                  |

The scripts find the USB stick root two folders up from `Engine/Scripts/`; paths in configurations are relative to that root.

### Adding a section

A new section touches these places:

- `Engine/Common/Section.ps1`: the script and its place in the run order in `Get-SnapshotScriptsHC`, the wizard name and description in `Get-SnapshotSectionLabelsHC`, and `Get-EmptySectionValueHC` when the section is an object instead of a list.
- `Engine/Common/Configuration.psm1`: `$script:ArrayItems` when the section is a list, and checks the schema can't express in `Test-ConfigurationHC`.
- `Engine/Schemas/config.schema.json`: the section under `Items`, in the `anyOf` list of `Items` and in `$defs`; plus `Engine/Schemas/<Section>.schema.json` and its entry in `.vscode/settings.json`.
- `Shared/Examples/<Section>.json` and the section in the root [README](../README.MD).
- Tests: the run order in `Configuration.Tests.ps1`, `$mapping` in `Schema.Tests.ps1`, the child contract in `Engine/Tests/Common/Child contract.ps1` and a test file for the script itself.

## 🧩 Writing a Child Script

Each section is handled by one script in `Engine/Scripts/` (for example `User accounts import export.ps1`). The main script calls it with three parameters, `-Action` (`Export` or `Import`), `-Data` (the section's data on import) and `-RootFolder` (the USB stick root), and expects exactly **one** object back:

```powershell
[pscustomobject]@{
    Data     = $exportData          # the captured section on Export, $null on Import
    Messages = [string[]]$messages  # what was done, shown in the report
    Errors   = [string[]]$errors    # one line per failed entry; empty when all went well
}
```

- On export, `-Data` holds the section's export options from `-ExportOptions`, or `$null`.
- All three properties are required. `Messages` and `Errors` must be string arrays, also when they are empty (`[string[]]@()`); a result without them is reported as **Failed**.
- Set `$ErrorActionPreference = 'Stop'` at the top, handle each entry in its own `try`/`catch` and add a line to `$errors` in the `catch`. A failed step then skips the rest of that entry only, and the other entries still run.
- A section with any `Errors` is reported as **Failed**, and on export its data is not saved.
- Don't let commands write stray output: capture it or discard it with `$null =`, because anything extra breaks the "exactly one object" rule.
- Errors written with `Write-Error` or a `throw` that escape the script are still caught and reported as a safety net, but report expected problems in `Errors`.

## 🧪 Running the Tests

The tests use Pester 6. They mock all Windows changes and only create files in a temporary folder, so they are safe to run on your own computer. Run them on both Windows PowerShell 5.1 and PowerShell 7; on PowerShell 7 the JSON schema is also checked with `Test-Json`. Run them from the USB stick root.

**PowerShell 7:**

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser
Invoke-Pester -Path .\Engine\Tests
```

**Windows PowerShell 5.1:** Windows ships with the old Pester 3.4.0, and PowerShell 7 keeps its modules in a separate folder, so install Pester 6 again from a Windows PowerShell window. `-SkipPublisherCheck` is needed because the built-in Pester is signed by a different publisher:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Pester -MinimumVersion 6.0.0 -Force
Invoke-Pester -Path .\Engine\Tests
```

Always import Pester 6 explicitly in Windows PowerShell; otherwise `Invoke-Pester` can load 3.4.0, and every test file fails with *the following modules that are specified by the "#requires" statements of the script are missing: Pester*.

Start a new PowerShell session after moving or renaming files in `Engine/Common/`: a session that already loaded a module keeps the old copy, and the tests then fail with *Multiple script or manifest modules named ... are currently loaded*.

If installing fails with a download or NuGet error, run this first and try again:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
```

## 🔄 Upgrading from an Older Version

Configuration files from a previous version of this tool don't work right away, but there's an automatic converter. Open PowerShell in the USB stick root and run:

```powershell
& '.\Engine\Scripts\Convert configuration.ps1' -OldConfigurationFile 'Configurations\Old PC.json' -RootFolder $PWD.Path
```

This converts an old configuration (version 1, the `StartScript` format) to the current format (version 3). The result is written to `Configurations\<name>.json` and the original is kept as `<name>.v1.json`.

Run the converter once per configuration file; a file that is already version 3 is left alone. Share permissions that belong to a share that isn't in the old share list can't be applied, and are reported.

See [VERSION.MD](VERSION.MD) for what changed in each version, breaking changes first.
