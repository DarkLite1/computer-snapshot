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
   - Optionally choose an **Answer file**, or click **Create template...** to
     generate one for the checked sections. **Unattended** fails on missing
     answers instead of showing input popups; see [Answer files](#answer-files-and-unattended-restores).
   - Click **Restore selected**. _(Note: If you change your mind, click Cancel to leave the computer unchanged)._
4. **To save a PC's setup (Export):**
   - Click **Export**.
   - Choose which sections you want to save (like users, folders, or network settings).
   - For **Scheduled tasks**, check the Task Scheduler folders to export under **Scheduled task folders** (default `\HC\`, subfolders included, several separated by commas). Entering `\` exports every task on the computer, including the Windows ones; the wizard asks you to confirm that.
   - Give your file a name. _Tip: The wizard suggests a handy default name like `KIOSK01 2026-10-21 142536.json`_.

**💡 Quick Tips for the Wizard:**

- **Need Admin Rights?** If a task requires it, click the **Restart as administrator** button at the top.
- **Rebooting & Reports:** At the bottom of the restore screen, you can easily check boxes to automatically **Restart computer after successful restore** (with a countdown in seconds you can change) or **Open report in browser**.
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
- **`Answers/`**: Optional local answer files for individual PCs. Create this
  folder when needed; Git ignores it because answers can contain passwords.
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
| 3     | `UserAccounts`             | Local user accounts to create, update or remove.                         |
| 4     | `UserGroups`               | Local groups and their members.                                         |
| 5     | `FirewallRules`            | Windows Defender Firewall rules.                                        |
| 6     | `CreateFolders`            | Folders to create.                                                      |
| 7     | `SmbShares`                | SMB shares, each with its share and NTFS permissions.                   |
| 8     | `NetworkCards`             | Network adapter names, network profile (category), DNS suffix and IPv4 settings. |
| 9     | `HostsFileEntries`         | Host names in the Windows hosts file and the IP addresses they point to. |
| 10    | `NtpTimeServers`           | Time synchronization (domain or specific NTP servers).                  |
| 11    | `RegistryKeys`             | Registry values to set.                                                 |
| 12    | `ScheduledTasks`           | Scheduled tasks from the `\HC\` folder, as XML or an exported XML file, with the account they run as. |
| 13    | `CopyFilesFolders`         | Files or folders to copy from the USB stick to the computer.            |
| 14    | `Software`                 | Software to uninstall and installers (from `Software/`) to run.          |
| 15    | `StartCustomScriptsAfter`  | Your own PowerShell scripts to run after everything else.               |

An empty section (like `[]` or `{}`) is reported as *Skipped – Nothing to do*. See the `Examples/` folder for the exact format of each section.

Some sections can't be fully captured automatically, so exporting them only gives you a starting example to edit: `CreateFolders`, `CopyFilesFolders`, `RegistryKeys` and `Software`. `StartCustomScriptsBefore` and `StartCustomScriptsAfter` export an empty list, so no example script can run by accident; see `Examples\StartCustomScriptsBefore.json` for the format.

### Reusing sections across computers

Instead of writing a section inline, you can point to a file. The path is relative to the USB stick root:

```json
"Items": {
  "UserAccounts": "Shared\\UserAccounts kiosk.json"
}
```

The referenced file contains only that section's data (for example, a JSON array of user accounts). Referenced files can't point to other files.

A section can also be built from **several files**, so you can combine reusable building blocks, for example the shares every PC has plus the shares of one kind of PC:

```json
"Items": {
  "SmbShares": [ "Shared\\SmbShares common.json", "Shared\\SmbShares scanner.json" ],
  "RegistryKeys": [ "Shared\\Registry office.json", "Shared\\Registry kiosk.json" ]
}
```

The files are combined in the order you list them:

- Lists are joined: the shares, users, registry entries or installers of all files.
- Objects are combined property by property, so the lists inside them are joined too, such as `RunAsCurrentUser.RegistryKeys`, `Software.Install` or `CreateFolders.FolderPaths`.
- A single setting may appear in several files only with the same value. Two different values, such as two time zones in `RegionalSettings`, are reported as an error naming both files, instead of one silently winning.
- The combined section is checked as a whole, so the same share or user in two files is reported as well.

See [Configurations/Example combined sections.json](Configurations/Example%20combined%20sections.json) for a complete example: an office PC base plus kiosk extras, with `CreateFolders` and `RegistryKeys` each built from a common and a kiosk file in `Shared\`. It is safe to restore as it is; it only adds example registry values under `HKCU\Software\ComputerSnapshot\Example` and folders under `%ProgramData%\ComputerSnapshot example`. Shares work the same way, for example `Shared\SmbShares common.json` with the shares of every PC and `Shared\SmbShares kiosk.json` with the extra kiosk shares.

### Removing local user accounts

Use `Action: "Remove"` in `UserAccounts` instead of a custom removal script:

```json
"UserAccounts": [
  { "Name": "bob", "Action": "Remove" }
]
```

- Without `Action`, or with `Action: "Set"`, the existing create/update
  behavior is unchanged.
- Removal accepts only `Name`, `Action` and an optional `Comment`. Do not
  include a password or other account settings.
- Use an exact local account name (case-insensitive), not a wildcard,
  domain-qualified name or SID. Only named accounts are removed.
- Windows built-in accounts (even renamed ones) and the account running the
  restore are protected by SID; attempts to remove them are reported as errors.
- An account that is already absent is reported as nothing to remove.
  Other failures are reported, and remaining entries are still processed.
- This deletes the account, **not its Windows profile or files**. Recreating
  the same name creates a different SID and does not restore its old permissions.
- Run as administrator. Removal cannot be undone by this tool; review the
  names before restoring.

See [Examples/UserAccounts.json](Examples/UserAccounts.json) for a mixed
create/update/removal example. Exports still capture only existing accounts
for creation or update; they never generate removal actions.

### Accounts in other Windows languages

Built-in accounts and groups have a different name in each Windows language: *Everyone* is *Iedereen* in Dutch and *Jeder* in German. So exports store them by their security ID (SID), which is the same everywhere, for example `S-1-1-0` for Everyone and `S-1-5-32-544` for Administrators. A restore turns the SID back into the name used by that computer. This applies to user group names and members, share permissions and folder permissions. You can write SIDs in your own configurations too. Local and domain accounts keep their name, because their SID differs per computer or domain.

### Paths

All paths in a configuration (installers, files to copy, custom scripts, shared sections) are relative to the root of the USB stick, unless you give a full path like `C:\Temp\file.txt`. Environment variables such as `%ProgramData%` are expanded in these paths, in the folders to create (`CreateFolders`) and in the destinations of `CopyFilesFolders`. An unknown variable is reported as an error instead of becoming part of a folder name.

### Settings

| Setting               | Default | Meaning                                                                   |
| --------------------- | ------- | ------------------------------------------------------------------------- |
| `RebootComputer`      | `false` | Restart the computer after a restore in which nothing failed, after a countdown (`shutdown /a` cancels it). The report shows whether it restarts. |
| `RestartDelaySeconds` | `60`    | Length of that countdown, from `0` to `600` seconds.                      |
| `OpenReportInBrowser` | `true`  | Open the HTML report when the run is finished.                            |
| `RunElevated`         | `false` | When restoring from a shortcut or the command line, restart as administrator first (UAC prompt). |

### SMB shares

`SmbShares` is a list with one entry per share. Each share has its settings, its share permissions in `Access`, and the permissions of its folder in `NTFS`:

```json
"SmbShares": [
  {
    "Name": "Data",
    "Path": "C:\\Data",
    "Access": [
      { "AccountName": "S-1-5-32-544", "AccessControlType": "Allow", "AccessRight": "Full" },
      { "AccountName": "S-1-5-11", "AccessControlType": "Allow", "AccessRight": "Change" }
    ],
    "NTFS": {
      "Owner": "S-1-5-32-544",
      "AreAccessRulesProtected": false,
      "Access": [
        { "IdentityReference": "S-1-5-32-545", "AccessControlType": "Allow", "FileSystemRights": "Modify, Synchronize", "InheritanceFlags": "ContainerInherit, ObjectInherit", "PropagationFlags": "None" }
      ]
    }
  },
  {
    "Name": "Scans",
    "Path": "D:\\Scans",
    "Access": [ { "AccountName": "S-1-5-32-545", "AccessControlType": "Allow", "AccessRight": "Read" } ]
  }
]
```

- A share without `Access` keeps its current share permissions; a share without `NTFS` keeps the current permissions of its folder.
- Configured permissions are applied first. Existing share permissions that aren't configured are only removed when every configured one could be applied, so a share never ends up with less access than configured.
- Each share name may appear only once.

### Network cards and IP settings

Each entry in `NetworkCards` has two parts: `FindBy` says how to find the card, `Change` says what to change on it. Nothing in `FindBy` is ever changed.

```json
"NetworkCards": [
  {
    "FindBy": { "Name": "Ethernet" },
    "Change": {
      "NewName": "LAN",
      "IPSettings": {
        "IPAddress": "{{ipv4:IP address of this PC}}",
        "PrefixLength": "{{prefix:Prefix length, such as 24}}",
        "DefaultGateway": "{{ipv4:Default gateway}}",
        "DNSServers": ["10.75.38.23", "10.75.38.22"]
      }
    }
  },
  {
    "FindBy": { "Description": "Broadcom" },
    "Change": { "IPSettings": { "Dhcp": true } }
  }
]
```

`FindBy` has exactly one of:

| `FindBy`      | Finds the card                                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Description` | by its description, the name in Device Manager: an exact match first, otherwise the one card containing the text. The driver sets the description; it can't be changed. |
| `Name`        | by its current name, such as `Ethernet`, before any rename; names can differ per computer                                         |

`Change` can hold, applied in this order; anything left out stays as it is:

| `Change`          | Does                                                                     |
| ----------------- | ------------------------------------------------------------------------ |
| `NewName`         | renames the card                                                         |
| `DnsSuffix`       | sets the connection-specific DNS suffix; an empty string clears it        |
| `NetworkCategory` | sets the network profile, such as `Private` or `Public`                  |
| `IPSettings`      | sets the IPv4 address, gateway and DNS servers, see below                |

- A static address needs `IPAddress` and `PrefixLength`. It turns DHCP off and replaces all IPv4 addresses and the default gateway of the card. `DefaultGateway` is optional and must be in the same subnet.
- `{ "Dhcp": true }` makes the address automatic again; static addresses and the gateway are removed, and hand-set DNS servers too unless `DNSServers` is given.
- `DNSServers` replaces the DNS servers, in order of use. An empty list makes DNS automatic; leaving it out keeps the current DNS servers.
- Use `{{ipv4:...}}` and `{{prefix:...}}` placeholders to ask for the values during the restore (see [Restore-Time Input](#restore-time-input)).
- When a change to the IPv4 settings fails, for example because the address is already in use, the previous settings are put back: DHCP on or off, the addresses, the default gateway and the DNS servers. The report names the failure and says whether restoring them worked.
- An export finds each card by its description and writes its current name in `NewName`, with its settings: `Dhcp: true`, or its static address, prefix and gateway, plus DNS servers that were set by hand. A card with several IPv4 addresses exports the first one; the report says so.

> Changing the IP address of the card you are connected through, for example over remote desktop, ends that connection. Restore network settings at the computer itself.

### Hosts file

`HostsFileEntries` lists host names per IP address, for the Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`):

```json
"HostsFileEntries": [
  { "IPAddress": "10.20.60.47", "Hostnames": ["belsdaise0001", "belsdaise0001.grouphc.net"] },
  { "IPAddress": "fd00::47", "Hostnames": ["belsdaise0001-v6.grouphc.net"] },
  { "IPAddress": "{{ipv4:IP address of the print server}}", "Hostnames": ["printserver"] },
  { "Action": "Remove", "Hostnames": ["oldserver", "oldserver.grouphc.net"] }
]
```

- Each host name is made to point to its `IPAddress` (IPv4 or IPv6). A name that already does is left alone; a name that points to another address is moved, and the report says from which address; a missing name is added on a new line.
- `"Action": "Remove"` removes the host names, whatever address they point to. It has no `IPAddress`.
- Comments, empty lines and all other entries in the hosts file are kept as they are. A line whose names were all moved or removed is dropped.
- The file is only written when something changed. The previous version is kept as `hosts.bak`, and the DNS cache is cleared so the change works straight away.
- A host name may point to one address only, across the whole section, also when it is combined from several files in `Shared\`.
- An export writes every active line of the hosts file, one entry per address.

### Registry changes

Each entry in `RegistryKeys` has an `Action`; without one, it sets a value.

| `Action`        | Needs                      | Does                                                                 |
| --------------- | -------------------------- | -------------------------------------------------------------------- |
| `Set`           | `Path`, `Name`, `Type`, `Value` | creates or changes a value, including missing keys               |
| `RemoveValue`   | `Path`, `Name`             | removes one value                                                    |
| `ClearValues`   | `Path`                     | removes all values of the key, keeps its subkeys                     |
| `ClearKey`      | `Path`                     | removes all values and subkeys, keeps the key                        |
| `RemoveKey`     | `Path`                     | removes the key with everything in it                                |

| `Type`                      | `Value`                                                       |
| --------------------------- | ------------------------------------------------------------- |
| `String`, `ExpandString`    | text; `%variables%` in an `ExpandString` stay as written       |
| `MultiString`               | a list: `["one", "two"]`                                       |
| `Binary`                    | hex text `"01 0A FF"`, or a list of numbers `[1, 10, 255]`     |
| `DWord`, `QWord`            | a number (`16`), or text in decimal (`"16"`) or hex (`"0x10"`) |

- `"Name": ""` is the key's (Default) value. `Path` can be `HKLM:\...`, `HKCU:\...` or `HKEY_LOCAL_MACHINE\...`.
- An unchanged value isn't rewritten, and removing something that doesn't exist is reported, not an error, so a configuration can be restored again.
- `ClearValues`, `ClearKey` and `RemoveKey` are refused for a hive root or a key directly below it, such as `HKLM:\SOFTWARE`.
- In `RunAsOtherUser`, `HKCU` means that user's registry.

```json
"RegistryKeys": [
  { "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Servers", "Type": "MultiString", "Value": ["srv1", "srv2"] },
  { "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Flags", "Type": "DWord", "Value": "0x10" },
  { "Action": "RemoveValue", "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Obsolete" },
  { "Action": "ClearKey", "Path": "HKLM:\\SOFTWARE\\Vendor\\Cache" }
]
```

### Scheduled tasks

An export captures the tasks in the Task Scheduler folder `\HC\` and its subfolders. To export other folders, enter them in the wizard under **Scheduled task folders**, or use `-ExportOptions` on the command line (see [Command-Line Use](#-command-line-use)).

Each task needs its XML definition, in one of two ways:

- `Xml`: the complete XML inline, as an export writes it.
- `XmlFile`: a file exported from Task Scheduler (right-click a task, **Export...**), relative to the USB stick root unless it is a full path. This is easier to edit and review than XML inside JSON.

The account a task runs as:

| Properties                       | The task runs                                                                          |
| -------------------------------- | -------------------------------------------------------------------------------------- |
| `RunAsUser` and `RunAsPassword`  | as that user, whether or not the user is signed in; the password is saved in Task Scheduler |
| `RunAsUser` only                 | as that account: a service account such as `S-1-5-19` (LOCAL SERVICE), or a user while signed in |
| neither                          | as SYSTEM                                                                              |

Use a `{{password:...}}` placeholder for `RunAsPassword`, so the password is asked for during the restore and never stored in the configuration. An export does exactly that for each task with a saved password. A task that runs for a group can't be exported with its account and is restored as SYSTEM; the export report says so.

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

### Exit codes of custom scripts and installers

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

### Example: Dell driver updates after a restore

[Examples/StartCustomScriptsAfter.json](Examples/StartCustomScriptsAfter.json)
runs [Files/Update Dell drivers.ps1](Files/Update%20Dell%20drivers.ps1) after the
other restore sections. This example is opt-in; it is not enabled in the
shipped configurations. Add this entry inside your configuration's `Items`:

```json
"StartCustomScriptsAfter": "Examples\\StartCustomScriptsAfter.json"
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

### Removing software

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
- Some uninstallers start a second process and end straight away. The tool waits for the processes an uninstaller starts, and afterwards gives the application up to 60 seconds to disappear from Programs and Features.

### Time limit for installers and uninstallers

Each entry in `Install` and `Remove` gets `TimeoutMinutes` to finish, by default 15, from 1 to 1440. That includes the processes it starts. An installer or uninstaller that is still running then, for example because it waits for a click, is stopped and reported as failed; the next entries still run.

```json
{ "ExecutablePath": "Software\\BigSuite.exe", "Arguments": "/quiet", "TimeoutMinutes": 60 }
```

### Editing with autocomplete

Every configuration starts with `"$schema": "../Scripts/config.schema.json"`. Editors like Visual Studio Code use this to offer autocomplete and flag mistakes while you type. Keep this line, and keep your configurations in the `Configurations/` folder so the relative path works.

> **🔒 Important Security Warning:**
> When you save settings that include passwords (like user accounts or certain registry keys), **they are saved in plain text**. Please keep your USB stick physically secure, and never upload files containing sensitive passwords to public spaces. Where possible, use a `{{password:...}}` placeholder instead, so the password is asked for during the restore and never stored (see [Restore-Time Input](#restore-time-input)).

## Restore-Time Input

Use a placeholder instead of a fixed string when a value changes between restores:

| Placeholder                                     | Popup behavior                                                                      |
| ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| `{{input:Enter the local account name}}`        | Required text input.                                                                |
| `{{password:Enter the local account password}}` | Required, masked input. Use this form for passwords and other secrets.              |
| `{{ipv4:Enter the time-server IPv4 address}}`   | Required IPv4 address, such as `192.0.2.10`; invalid addresses cannot be submitted. |
| `{{prefix:Enter the prefix length}}`            | Required subnet prefix length from 1 to 32, such as `24`; stored as a number.        |

The text after the colon is the field description shown in the popup. The configuration field path is also displayed. For example, a user-account entry can contain:

```json
{
  "Name": "{{input:Enter the local account name}}",
  "Password": "{{password:Enter the local account password}}",
  "TimeServerNames": ["{{ipv4:Enter the IPv4 address of your NTP time server}}"]
}
```

Select the configuration, click **Restore**, review the section checklist, and click **Restore selected**. In interactive mode, after any required UAC elevation, a popup requests each value not supplied by an answer file. **Continue** accepts a valid answer; **Cancel**, Escape, or closing any input popup cancels the entire restore before any sections run. All answers are collected and the resolved configuration is validated before applying settings. Windows may still reject an otherwise valid answer, for example because of password policy.

Placeholders work in string values inside `Items`, including nested objects, arrays, and referenced shared sections. Only selected sections prompt. An identical placeholder (including its type and description) asks once and reuses the answer within that restore; use different descriptions to request independent values. Comments, metadata, settings, property names and section-reference filenames are not input fields. Do not use placeholders for other numbers or booleans, or embed them within larger strings; `{{prefix:...}}` is the only placeholder that gives a number. Answers are used literally, not evaluated as PowerShell or expanded as further placeholders.

**Placeholders inside a copied file:** a script or other text file on the USB stick can contain placeholders anywhere in its text, also in the middle of a line. Copy it with `CopyFilesFolders` and `"FillPlaceholders": true`; the placeholders are asked for at the start of the restore, together with the others, and the copy on the computer gets the answers. The file on the USB stick stays as it is, and the copy keeps the file's encoding.

```powershell
# Files\Start terminal.ps1 on the USB stick
$ArgumentList = '--kiosk http://{{ipv4:IP address of the terminal server}}:1353/terminal/?reference=TRM_AISE_01'
```

```json
"CopyFilesFolders": [
  { "From": "Files\\Start terminal.ps1", "To": "C:\\HC\\Start terminal.ps1", "FillPlaceholders": true }
]
```

`{{input:...}}`, `{{ipv4:...}}` and `{{prefix:...}}` work in files. `{{password:...}}` is refused, because the password would be stored in plain text on the computer. `FillPlaceholders` works for a single file, not for a folder.

**Exported user accounts:** Windows never reveals passwords, so an export writes `{{password:Password for local user 'name'}}` for each local user. Restoring the export asks for each password (unless supplied in an answer file), and sets it on the user, also on a user that already exists. Accounts that Windows manages itself (Guest, DefaultAccount, WDAGUtilityAccount) get an empty password instead and keep their current one. To keep an existing user's password, replace its placeholder in the configuration with an empty string; a user that doesn't exist yet needs a password to be created.

Interactive command-line restores use the same popups for missing answers and require an interactive Windows desktop. Browsing configurations and exporting do not ask for placeholder values. Use `-Unattended` to forbid input popups.

See [Configurations/Example prompted setup.json](Configurations/Example%20prompted%20setup.json) for a complete example. It prompts for a local account name, its password, and an NTP time-server IPv4 address. Restoring it creates or updates the named account and changes time synchronization; uncheck either section to skip it. To ask for a network card's static IP address, see [Network cards and IP settings](#network-cards-and-ip-settings).

**Password handling:** Answers are kept in memory for the current run. The original configuration and shared files are not rewritten, and answers are not included in the wizard's process-launch arguments or a resolved temporary JSON file. Password placeholders mask typing and redact exact matches from the tool's generated results, HTML reports and captured PowerShell child output. This is not encrypted storage: the restore scripts receive plain strings in memory, and custom scripts or external programs can independently log, persist or transform them. Only run trusted scripts and use `password` placeholders for sensitive values. Ordinary `input` answers are not redacted.

### Answer files and unattended restores

Keep a configuration as a reusable template and supply per-computer values in a
separate JSON file. `-AnswerFile` supplies values; `-Unattended` determines
whether missing values may prompt:

| Answer file | `-Unattended` | Behavior |
| --- | --- | --- |
| Supplied | No | Use its answers; prompt for missing answers. |
| Supplied | Yes | Fail before any sections run if any required answer is missing. |
| Not supplied | No | Prompt for all required answers. |
| Not supplied | Yes | Proceed only if the selected sections and their template files require no answers. |

An answer file contains an `Answers` object, with an optional `Comment`.
Keys are **complete, case-sensitive placeholders**, including the braces,
type and description. Values are strings; write a prefix as `"24"`, not `24`.
`null` means **not supplied** and is useful in a generated template. Empty
strings and invalid values are errors, not requests to prompt. Malformed files,
duplicate keys, unknown top-level properties and invalid supplied answers
always fail before any sections run, even in interactive mode.

```json
{
  "Answers": {
    "{{input:Enter the local account name to create or update}}": "kiosk",
    "{{password:Enter the password for this local account}}": null,
    "{{ipv4:Enter the IPv4 address of your NTP time server}}": "192.0.2.10"
  }
}
```

This is the bundled [partial answer example](Examples/Answers%20prompted%20setup.json)
for [Example prompted setup](Configurations/Example%20prompted%20setup.json).
It supplies a name and a documentation-only NTP address, and leaves the password
to be entered interactively. **Change the address to your real NTP server**
before using it. It is not a complete unattended answer file.

Identical placeholders share one answer across the selected configuration,
its shared sections and copied files using `FillPlaceholders`. Valid extra
answers for unselected sections are ignored, so one answer file can be reused
with different `-Items` selections. Every supplied answer is still checked
for its type and format. Answers are literal data, never PowerShell code.

#### Generate an answer template

From the tool's root folder:

```powershell
New-Item -Path '.\Answers' -ItemType Directory -Force | Out-Null
& '.\Scripts\New answer file.ps1' `
    -ConfigurationFile 'Configurations\Example prompted setup.json' `
    -AnswerFile 'Answers\KIOSK01.json'
```

The generator writes each distinct placeholder with `null`, without applying
settings or asking for answers. It includes shared sections and copied text
templates with `FillPlaceholders`. Those source files must exist at fixed
paths so the generator can inspect them. Add `-Items UserAccounts` to generate
only that section's answers. The destination directory must exist. Existing
answer files are protected unless you explicitly add `-Force`; that replaces
their contents with a new empty template.

Edit the generated file locally, replacing each required `null` with a string.
The configuration and all source files stay unchanged.

#### Interactive restore with partial answers

```powershell
& '.\Scripts\Invoke configuration.ps1' `
    -ConfigurationFile 'Configurations\Example prompted setup.json' `
    -AnswerFile 'Examples\Answers prompted setup.json'
```

This still asks for confirmation, and asks for the missing password after any
required elevation. Use `-SkipConfirmation` to skip only the initial confirmation.

#### Unattended restore

Start PowerShell as administrator first when the configuration requires it.
After filling in your local answer file:

```powershell
$result = & '.\Scripts\Invoke configuration.ps1' `
    -ConfigurationFile 'Configurations\Example prompted setup.json' `
    -AnswerFile 'Answers\KIOSK01.json' `
    -Unattended

if (-not $result.Success) { exit 1 }
```

`-Unattended` skips confirmation and requires an explicit configuration path;
it never shows the configuration picker. It suppresses browser opening even
if `OpenReportInBrowser` is true. When `Settings.RunElevated` is true and the
process is not elevated, it fails with instructions rather than requesting
UAC. Restart settings still apply; use `-RebootComputer $false` to override them.
A validation failure throws before any section runs, and the executor writes a
failure report. Section failures are reported through `Success: false`, as in
other restores; check that result in automation as shown above.

`Invoke scripts.ps1 -Action RestoreSnapshot` also accepts `-AnswerFile` and
`-Unattended`; these options are rejected on export. Both configuration and
answer-file relative paths are resolved from the tool's root, not the current
working directory. When launching PowerShell from Task Scheduler or another
program, also use PowerShell's `-NoProfile -NonInteractive` options and an
already elevated account. Custom scripts and installers must themselves be
configured to run silently; these switches cannot prevent their own UI.

#### Wizard

The **Restore** section-selection window includes:

- **Answer file** and **Browse...** to select an existing JSON file. Leave it
  blank for the existing interactive behavior.
- **Create template...** to save an empty answer file for the currently checked
  sections without starting a restore. Edit its `null` values externally.
- **Unattended: fail on missing answers (no prompts)**. This also unchecks and
  disables **Open report in browser**. Restart the wizard as administrator
  first if the configuration requests elevation.

> **Passwords in answer files are plain text.** Keep real files in the
> Git-ignored `Answers` folder, restrict filesystem access, and protect any USB
> copies. Git ignoring is not encryption or access control. Only the file path
> is passed to the restore process; password answers receive the same report
> redaction as prompted passwords. The bundled example deliberately contains
> no password.

## 💻 Command-Line Use

For scripting or one-off runs, open PowerShell in the root of the USB stick.

Restore a configuration (asks for confirmation; add `-SkipConfirmation` to skip the question, or leave out `-ConfigurationFile` to pick from a list). The old name `-Confirm` still works, so existing shortcuts keep working:

```powershell
& '.\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Example PC1.json'
```

Restore only some sections, and override saved settings for this run:

```powershell
& '.\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Example PC1.json' -Items UserAccounts, Software -RebootComputer $true -RestartDelaySeconds 300
```

Export this computer to a new configuration file (add `-Force` to overwrite an existing file):

```powershell
& '.\Scripts\Invoke scripts.ps1' -Action CreateSnapshot -ConfigurationFile 'Configurations\KIOSK01.json' -Items RegionalSettings, UserAccounts, FirewallRules
```

Export the scheduled tasks of other Task Scheduler folders than the default `\HC\` (subfolders are included):

```powershell
& '.\Scripts\Invoke scripts.ps1' -Action CreateSnapshot -ConfigurationFile 'Configurations\KIOSK01.json' -Items ScheduledTasks -ExportOptions @{ ScheduledTasks = @{ TaskPath = '\HC\', '\Vendor\' } }
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

- On export, `-Data` holds the section's export options from `-ExportOptions`, or `$null`.
- All three properties are required. `Messages` and `Errors` must be string arrays, also when they are empty (`[string[]]@()`); a result without them is reported as **Failed**.
- Set `$ErrorActionPreference = 'Stop'` at the top, handle each entry in its own `try`/`catch` and add a line to `$errors` in the `catch`. A failed step then skips the rest of that entry only, and the other entries still run.
- A section with any `Errors` is reported as **Failed**, and on export its data is not saved.
- Don't let commands write stray output: capture it or discard it with `$null =`, because anything extra breaks the "exactly one object" rule.
- Errors written with `Write-Error` or a `throw` that escape the script are still caught and reported as a safety net, but report expected problems in `Errors`.

## 🧪 Running the Tests

The tests use Pester 6. They mock all Windows changes and only create files in a temporary folder, so they are safe to run on your own computer. Run them on both Windows PowerShell 5.1 and PowerShell 7; on PowerShell 7 the JSON schema is also checked with `Test-Json`.

**PowerShell 7:**

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser
Invoke-Pester -Path .\Tests
```

**Windows PowerShell 5.1:** Windows ships with the old Pester 3.4.0, and PowerShell 7 keeps its modules in a separate folder, so install Pester 6 again from a Windows PowerShell window. `-SkipPublisherCheck` is needed because the built-in Pester is signed by a different publisher:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Pester -MinimumVersion 6.0.0 -Force
Invoke-Pester -Path .\Tests
```

Always import Pester 6 explicitly in Windows PowerShell; otherwise `Invoke-Pester` can load 3.4.0, and every test file fails with *the following modules that are specified by the "#requires" statements of the script are missing: Pester*.

If installing fails with a download or NuGet error, run this first and try again:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
```

## 🔄 Upgrading from an Older Version?

If you have old configuration files from a previous version of this tool, they won't work right away. But don't worry—there's an automatic converter!

Just open PowerShell from your USB stick and run:

```powershell
& '.\Scripts\Convert configuration.ps1' -OldConfigurationFile 'Configurations\Old PC.json' -RootFolder $PWD.Path
```

This converts an old configuration (version 1, the `StartScript` format) to the current format (version 3). The result is written to `Configurations\<name>.json` and the original is kept as `<name>.v1.json`.

Run the converter once per configuration file; a file that is already version 3 is left alone. Share permissions that belong to a share that isn't in the old share list can't be applied, and are reported.