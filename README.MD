# 🖥️ Computer Snapshot

Computer Snapshot is a portable tool that lets you easily backup (export) and set up (restore) Windows computers directly from a USB stick.

The best part? **No installation is required** on the computers you are managing. As long as the PC is running 64-bit Windows (PowerShell 5.1 or newer), you are good to go. Every computer's configuration is neatly saved as a single, easy-to-read text file.

## 🚀 Quick Start: Using the Wizard

The easiest way to use Computer Snapshot is through the built-in graphical wizard.

1. **Plug in** your USB stick.
2. **Open the tool** by double-clicking **`Start wizard.lnk`**.
3. **To set up a PC (Restore):**
   - Select a saved configuration and click **Restore**.
   - Check the boxes next to the settings you want to apply.
   - Click **Restore selected**. _(Note: If you change your mind, click Cancel to leave the computer unchanged)._
4. **To save a PC's setup (Export):**
   - Click **Export**.
   - Choose which sections you want to save (like users, folders, or network settings).
   - Give your file a name. _Tip: The wizard suggests a handy default name like `KIOSK01 2026-10-21 142536.json`_.

**💡 Quick Tips for the Wizard:**

- **Need Admin Rights?** If a task requires it, click the **Restart as administrator** button at the top.
- **Rebooting & Reports:** At the bottom of the restore screen, you can easily check boxes to automatically **Restart computer after successful restore** or **Open report in browser**.
- **Check Your Results:** Once you run a task, look in the `Log` folder on your USB stick for an easy-to-read HTML report showing exactly what succeeded and what failed.

## 🔗 Shortcuts

| Shortcut                           | What it does                                                                                               |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Start wizard.lnk`                 | Opens the graphical wizard for exporting and restoring.                                                    |
| `_Start example confirm first.lnk` | Restores `Configurations\Example PC1.json` after asking you to confirm with `y`.                           |
| `_Start example immediately.lnk`   | Restores `Configurations\Example PC1.json` straight away, without asking.                                  |

Copy one of the `_Start example` shortcuts and change the `-ConfigurationFile` path to make a one-click restore for your own configuration.

## 📂 Know Your Folders

Your USB stick has a specific layout to keep everything organized. Here are the main folders you will use:

- **`Configurations/`**: This is where your saved PC setups live (one file per computer).
- **`Software/`**: Place any app installers (like `.exe` files) in here.
- **`Files/`**: Put any standard files or custom scripts you want copied to the new PC here.
- **`Shared/`**: A great place to keep standard, reusable settings (like a standard "Guest" user account) that you want to apply to multiple computers.
- **`Log/`**: Check here for your execution reports.
- **`Examples/`**: Ready-made sample data for every section. Copy what you need into your own configuration.
- **`Scripts/`**: The tool itself. You normally don't need to touch anything here.
- **`Tests/`**: Automated Pester tests for developers (see [Running the Tests](#-running-the-tests)).
- **`Snapshots/`**: Legacy version-1 sample data, kept only for testing the configuration converter.

## ✍️ Customizing Your Setups

All configurations are saved as standard JSON files. You can open and edit them in any code editor, like Visual Studio Code.

- **Smart Automation:** You don't need to worry about the order of operations. The script automatically handles things in a safe sequence (for example, creating user accounts before trying to copy files into their folders).
- **Skipping Items:** If an item or section is missing from your file, the script simply skips it and moves on.
- **Safety First:** If a specific setting fails to apply, the tool won't crash. It will continue setting up the rest of the computer and log the error for you to review later.

### What can be exported and restored?

Each configuration has an `Items` object with one entry per section. Sections always run in this order, regardless of the order in your file:

| Order | Section                    | What it covers                                                          |
| ----- | -------------------------- | ----------------------------------------------------------------------- |
| 1     | `StartCustomScriptsBefore` | Your own PowerShell scripts (from `Files/`) to run before everything else. |
| 2     | `RegionalSettings`         | System locale, time zone, home location and culture.                    |
| 3     | `UserAccounts`             | Local user accounts.                                                    |
| 4     | `UserGroups`               | Local groups and their members.                                         |
| 5     | `FirewallRules`            | Windows Defender Firewall rules.                                        |
| 6     | `CreateFolders`            | Folders to create.                                                      |
| 7     | `SmbShares`                | SMB shares with their share and NTFS permissions.                       |
| 8     | `NetworkCards`             | Network adapter names, network profile (category) and DNS suffix.       |
| 9     | `NtpTimeServers`           | Time synchronization (domain or specific NTP servers).                  |
| 10    | `RegistryKeys`             | Registry values to set.                                                 |
| 11    | `ScheduledTasks`           | Scheduled tasks, stored as their full XML plus enabled state.           |
| 12    | `CopyFilesFolders`         | Files or folders to copy from the USB stick to the computer.            |
| 13    | `Software`                 | Software to uninstall and installers (from `Software/`) to run.          |
| 14    | `StartCustomScriptsAfter`  | Your own PowerShell scripts to run after everything else.               |

An empty section (like `[]` or `{}`) is reported as *Skipped – Nothing to do*. See the `Examples/` folder for the exact format of each section.

Some sections can't be fully captured automatically, so exporting them only gives you a starting example to edit: `StartCustomScriptsBefore`/`After`, `CreateFolders`, `CopyFilesFolders`, `RegistryKeys` and `Software`.

### Reusing sections across computers

Instead of writing a section inline, you can point to a file. The path is relative to the USB stick root:

```json
"Items": {
  "UserAccounts": "Shared\\UserAccounts kiosk.json"
}
```

The referenced file contains only that section's data (for example, a JSON array of user accounts). Referenced files can't point to other files.

### Paths

All paths in a configuration (installers, files to copy, custom scripts, shared sections) are relative to the root of the USB stick, unless you give a full path like `C:\Temp\file.txt`. Environment variables such as `%SystemRoot%` are expanded.

### Settings

| Setting               | Default | Meaning                                                                   |
| --------------------- | ------- | ------------------------------------------------------------------------- |
| `RebootComputer`      | `false` | Restart the computer after a restore in which nothing failed, after a 60-second countdown (`shutdown /a` cancels it). The report shows whether it restarts. |
| `OpenReportInBrowser` | `true`  | Open the HTML report when the run is finished.                            |
| `RunElevated`         | `false` | When restoring from a shortcut or the command line, restart as administrator first (UAC prompt). |

### Custom scripts and exit codes

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

### Editing with autocomplete

Every configuration starts with `"$schema": "../Scripts/config.schema.json"`. Editors like Visual Studio Code use this to offer autocomplete and flag mistakes while you type. Keep this line, and keep your configurations in the `Configurations/` folder so the relative path works.

> **🔒 Important Security Warning:**
> When you save settings that include passwords (like user accounts or certain registry keys), **they are saved in plain text**. Please keep your USB stick physically secure, and never upload files containing sensitive passwords to public spaces.

## Restore-Time Input

Use a placeholder instead of a fixed string when a value changes between restores:

| Placeholder                                     | Popup behavior                                                                      |
| ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| `{{input:Enter the local account name}}`        | Required text input.                                                                |
| `{{password:Enter the local account password}}` | Required, masked input. Use this form for passwords and other secrets.              |
| `{{ipv4:Enter the time-server IPv4 address}}`   | Required IPv4 address, such as `192.0.2.10`; invalid addresses cannot be submitted. |

The text after the colon is the field description shown in the popup. The configuration field path is also displayed. For example, a user-account entry can contain:

```json
{
  "Name": "{{input:Enter the local account name}}",
  "Password": "{{password:Enter the local account password}}",
  "TimeServerNames": ["{{ipv4:Enter the IPv4 address of your NTP time server}}"]
}
```

Select the configuration, click **Restore**, review the section checklist, and click **Restore selected**. After any required UAC elevation, a popup requests each value. **Continue** accepts a valid answer; **Cancel**, Escape, or closing any input popup cancels the entire restore before any sections run. All answers are collected and the resolved configuration is validated before applying settings. Windows may still reject an otherwise valid answer, for example because of password policy.

Placeholders work in string values inside `Items`, including nested objects, arrays, and referenced shared sections. Only selected sections prompt. An identical placeholder (including its type and description) asks once and reuses the answer within that restore; use different descriptions to request independent values. Comments, metadata, settings, property names and section-reference filenames are not input fields. Do not use placeholders for numbers or booleans, or embed them within larger strings. Answers are used literally, not evaluated as PowerShell or expanded as further placeholders.

Command-line restores use the same popups and require an interactive Windows desktop. Browsing configurations and exporting do not prompt. For unattended restores, provide ordinary configuration values instead.

See [Configurations/Example prompted setup.json](Configurations/Example%20prompted%20setup.json) for a complete example. It prompts for a local account name, its password, and an NTP time-server IPv4 address. Restoring it creates or updates the named account and changes time synchronization; uncheck either section to skip it. This example does not set a network adapter's static IP address, which the current `NetworkCards` section does not support.

**Password handling:** Answers are kept in memory for the current run. The original configuration and shared files are not rewritten, and answers are not included in the wizard's process-launch arguments or a resolved temporary JSON file. Password placeholders mask typing and redact exact matches from the tool's generated results, HTML reports and captured PowerShell child output. This is not encrypted storage: the restore scripts receive plain strings in memory, and custom scripts or external programs can independently log, persist or transform them. Only run trusted scripts and use `password` placeholders for sensitive values. Ordinary `input` answers are not redacted.

## 💻 Command-Line Use

For scripting or one-off runs, open PowerShell in the root of the USB stick.

Restore a configuration (asks for confirmation; add `-Confirm` to skip the question, or leave out `-ConfigurationFile` to pick from a list):

```powershell
& '.\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Example PC1.json'
```

Restore only some sections, and override saved settings for this run:

```powershell
& '.\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Example PC1.json' -Items UserAccounts, Software -RebootComputer $false
```

Export this computer to a new configuration file (add `-Force` to overwrite an existing file):

```powershell
& '.\Scripts\Invoke scripts.ps1' -Action CreateSnapshot -ConfigurationFile 'Configurations\KIOSK01.json' -Items RegionalSettings, UserAccounts, FirewallRules
```

`Invoke scripts.ps1` is the engine behind everything else. It returns an object with `Success`, `ReportFile` and per-section `Results`, so you can check the outcome from your own scripts.

## 🧩 Writing a Child Script

Each section is handled by one script in `Scripts/` (for example `User accounts import export.ps1`). The main script calls it with three parameters, `-Action` (`Export` or `Import`), `-Data` (the section's data on import) and `-RootFolder` (the USB stick root), and expects exactly **one** object back:

```powershell
[pscustomobject]@{
    Data     = $exportData          # the captured section on Export, $null on Import
    Messages = [string[]]$messages  # what was done, shown in the report
    Errors   = [string[]]$errors    # one line per failed entry; empty when all went well
}
```

- All three properties are required. `Messages` and `Errors` must be string arrays, also when they are empty (`[string[]]@()`); a result without them is reported as **Failed**.
- Set `$ErrorActionPreference = 'Stop'` at the top, handle each entry in its own `try`/`catch` and add a line to `$errors` in the `catch`. A failed step then skips the rest of that entry only, and the other entries still run.
- A section with any `Errors` is reported as **Failed**, and on export its data is not saved.
- Don't let commands write stray output: capture it or discard it with `$null =`, because anything extra breaks the "exactly one object" rule.
- Errors written with `Write-Error` or a `throw` that escape the script are still caught and reported as a safety net, but report expected problems in `Errors`.

## 🧪 Running the Tests

The tests use Pester 6 and mock all Windows changes, so they are safe to run on your own computer:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser
Invoke-Pester -Path .\Tests
```

They run on Windows PowerShell 5.1. On PowerShell 7 the JSON schema is also checked with `Test-Json`.

## 🔄 Upgrading from an Older Version?

If you have old configuration files from a previous version of this tool, they won't work right away. But don't worry—there's an automatic converter!

Just open PowerShell from your USB stick and run:

```powershell
& '.\Scripts\Convert configuration.ps1' -OldConfigurationFile 'Configurations\Old PC.json' -RootFolder $PWD.Path
```

This will automatically update your old file to the new format and safely back up your original setup as a `.v1.json` file just in case.
