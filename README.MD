# 📸 Computer Snapshot

**Set up a Windows computer once, then repeat it on every other computer with one click.**

Computer Snapshot is a portable PowerShell tool that you can run from a USB stick. It saves the settings of a computer in one readable JSON file, called a **configuration**. Restore that file on another computer and you get the same accounts, shares, firewall rules, software and more. No installation needed.

```text
 🖥️ Computer A  ──Export──▶  📄 Configurations\Kiosk.json  ──Restore──▶  🖥️ Computer B, C, D…
```

---

## ✨ What can it set up?

Each part of a configuration is called a **section**. A restore runs the sections in the order below. Click a section for an example and more explanation.

| Section | What it does | Export captures it? |
| ------- | ------------ | :-----------------: |
| [`StartCustomScriptsBefore`](Shared/Examples/StartCustomScriptsBefore.json) | Run your own PowerShell scripts before everything else | ✏️ |
| [`RegionalSettings`](Shared/Examples/RegionalSettings.json) | Language, keyboards, culture, home location and time zone | ✅ |
| [`AccountPolicy`](Shared/Examples/AccountPolicy.md) | Local password rules and account lockout | ✅ |
| [`UserAccounts`](Shared/Examples/UserAccounts.md) | Local user accounts to create, update or remove | ✅ |
| [`UserGroups`](Shared/Examples/UserGroups.json) | Local groups and their members | ✅ |
| [`FirewallRules`](Shared/Examples/FirewallRules.json) | Windows Firewall rules | ✅ |
| [`EnvironmentVariables`](Shared/Examples/EnvironmentVariables.md) | Variables such as `JAVA_HOME`, and entries in `Path` | ✅ |
| [`CreateFolders`](Shared/Examples/CreateFolders.json) | Folders to create | ✏️ |
| [`SmbShares`](Shared/Examples/SmbShares.md) | Shared folders, with share and NTFS permissions | ✅ |
| [`NetworkCards`](Shared/Examples/NetworkCards.md) | Adapter name, IP address, DNS and more | ✅ |
| [`HostsFileEntries`](Shared/Examples/HostsFileEntries.md) | Host names in the Windows hosts file | ✅ |
| [`NtpTimeServers`](Shared/Examples/NtpTimeServers.json) | Domain time sync or NTP time servers | ✅ |
| [`PowerSettings`](Shared/Examples/PowerSettings.md) | Power plan, sleep and display timeouts, hibernation | ✅ |
| [`RegistryKeys`](Shared/Examples/RegistryKeys.md) | Registry keys and values to set or remove | ✏️ |
| [`ScheduledTasks`](Shared/Examples/ScheduledTasks.md) | Scheduled tasks and whether they are enabled | ✅ |
| [`CopyFilesFolders`](Shared/Examples/CopyFilesFolders.json) | Files and folders to copy from the USB stick | ✏️ |
| [`Software`](Shared/Examples/Software.md) | Applications to install or remove | ✏️ |
| [`Services`](Shared/Examples/Services.md) | Startup type of Windows services, start or stop them | ✏️ |
| [`StartCustomScriptsAfter`](Shared/Examples/StartCustomScriptsAfter.md) | Run your own PowerShell scripts after everything else | ✏️ |

✅ **Captured:** an export reads the current settings from the computer.
✏️ **You fill it in:** Windows can't tell which files, registry values or installers you chose on purpose. An export saves these sections **empty**, ready for you to fill in. Copy what you need from [`Shared/Examples`](Shared/Examples). On restore, an empty section is skipped.

---

## 🚀 Quick Start

1. Copy this folder to a USB stick or to a local folder.
2. Double-click **`Start wizard.lnk`**.
3. Choose a tab:

### 📤 Export: save this computer

1. Enter a **configuration name**, such as `Kiosk PC app X`.
2. Tick the sections you want.
3. Click **Export**.

The result is saved as `Configurations\<name>.json`. A report opens in your browser, and a copy is kept in the `Log` folder.

> 💡 Open the file in an editor such as VS Code. Remove everything you don't need and fill in the ✏️ sections. **Less is more:** a small configuration is faster and won't change things by accident.

### 📥 Restore: set up a computer

The wizard guides you step by step:

1. **Configuration:** choose a file from `Configurations` (subfolders are listed too).
2. **Sections:** untick the sections or installers you want to skip.
3. **Answer file:** optionally pick saved answers from `Answers` (see [placeholders](#-restore-time-input-placeholders)).
4. **Questions:** answer what the configuration asks, such as a password or an IP address.
5. **Review:** check your choices and start.

Nothing changes on the computer before you click the final button. Afterwards a report shows what was done and what failed. Each section keeps going when one entry fails.

> 🎯 New here? Try `Configurations\Examples\Prompted Setup.json`. It is a small example that asks three questions.

---

## 📂 Folder Layout

| Folder | What goes in it |
| ------ | --------------- |
| `Configurations\` | Your configurations. Ready-made examples are in `Configurations\Examples\`. |
| `Shared\` | Section files that several configurations reuse (see [Reusing sections](#-reusing-sections)). |
| `Shared\Examples\` | An example of every section, with explanations. |
| `Answers\` | Saved answers to the questions of a configuration (see [Answer files](#-answer-files-skip-the-typing)). |
| `Files\` | Files to copy or scripts to run, used by `CopyFilesFolders` and `StartCustomScripts...`. |
| `Software\` | Installers used by the `Software` section. |
| `Log\` | The HTML report of every export and restore. |
| `Engine\` | The tool itself. You don't need to touch it ([developer docs](Engine/README.MD)). |

Paths in a configuration, such as `Software\\setup.exe`, are relative to this root folder, so the USB stick works from any drive letter.

---

## 📄 A Configuration File

```json
{
  "$schema": "../Engine/Schemas/config.schema.json",
  "SchemaVersion": 3,
  "Description": "Office PC: Belgian settings and the office printer",
  "Settings": {
    "RebootComputer": false,
    "RestartDelaySeconds": 60,
    "OpenReportInBrowser": true,
    "RunElevated": true
  },
  "Items": {
    "RegionalSettings": {
      "WinSystemLocaleName": "nl-BE",
      "TimeZoneId": "Romance Standard Time",
      "WinHomeLocationGeoId": 21,
      "CultureName": "nl-BE"
    },
    "HostsFileEntries": [
      { "IPAddress": "192.0.2.50", "Hostnames": ["printserver"] }
    ]
  }
}
```

| Setting | Meaning |
| ------- | ------- |
| `Description` | Shown in the wizard, so you know which configuration to pick. |
| `RebootComputer` | Restart after a restore, **only** when nothing failed. Cancel the countdown with `shutdown /a`. |
| `RestartDelaySeconds` | The restart countdown, 0 to 600 seconds. |
| `OpenReportInBrowser` | Open the report when done. |
| `RunElevated` | Run as administrator; Windows asks for permission (UAC). Most sections need this. |

✍️ **Editor hints:** with the `$schema` line, VS Code completes section names and explains every setting while you type.
💬 **Notes:** add a `"Comment"` to any section or entry to explain it. The tool ignores comments.

---

## 💬 Restore-Time Input (Placeholders)

Some values differ per computer, such as an IP address or a password. Don't hard-code them, and never store a password in a file you share. Use a **placeholder** instead. The restore asks for the value and fills it in.

### How it looks

Write `{{type:question}}` where the value should go:

```json
"UserAccounts": [
  {
    "Name": "{{input:Name of the local account}}",
    "Password": "{{password:Password for this account}}"
  }
]
```

On restore, the wizard shows:

```text
  Name of the local account     [ kiosk            ]
  Password for this account     [ ●●●●●●●●         ]
```

The text after the colon is the question you see, so write it the way you would ask a colleague.

### The five types

| Placeholder | Asks for | Example answer |
| ----------- | -------- | -------------- |
| `{{input:...}}` | Any text | `kiosk-gent` |
| `{{password:...}}` | A password, hidden while typing | `●●●●●●●●` |
| `{{ipv4:...}}` | An IPv4 address | `192.168.1.20` |
| `{{prefix:...}}` | A subnet prefix length, 1 to 32 | `24` |
| `{{number:...}}` | A whole number | `30` |

Each answer is checked before anything runs. When a setting allows only certain values, you pick from a list. When it has a range, the allowed range is shown.

### Good to know

- 🔁 **Asked once, used everywhere:** when the same placeholder appears in several places, you answer it once. The text must match exactly, including capitals.
- 📋 **All questions up front:** every question is asked in one form before the restore starts. Cancel the form and nothing changes on the computer.
- 🧱 **The whole value:** a placeholder must be the complete value. `"{{ipv4:Gateway}}"` works, but `"Server {{input:Name}}"` doesn't.
- 🔒 **Passwords stay secret:** they are hidden while typing and replaced by `[redacted]` in the report.
- 🧩 **Shared files too:** placeholders work in section files in `Shared\` (see [Reusing sections](#-reusing-sections)).
- 📝 **Inside copied files:** set `"FillPlaceholders": true` on a `CopyFilesFolders` entry. Then the placeholders anywhere in that text file are filled in on the copy ([example](Shared/Examples/CopyFilesFolders.json)). `{{password:...}}` isn't allowed there, because the password would end up in plain text on the computer.
- 🤖 **Exports use them too:** an export writes static IP addresses, saved task passwords and secret-looking environment variables as placeholders. That way, restoring on several computers never copies one computer's address or password.

### 🗂️ Answer files: skip the typing

Restoring the same configuration on many computers? Save the answers in an **answer file** in the `Answers` folder:

```json
{
  "Comment": "Kiosk in Gent",
  "Answers": {
    "{{input:Name of the local account}}": "kiosk-gent",
    "{{password:Password for this account}}": null
  }
}
```

- Each key is the **complete placeholder**, copied exactly from the configuration.
- `null` means "ask me during the restore". Leave passwords `null`, so they never sit on the USB stick.
- To create one, open the **Answer file** step in the wizard, type a name and click **Create**. Or run `New answer file.ps1` (see below). Both list every placeholder for you, also those inside copied files.
- Make one answer file per site or per computer, for example `Answers\Kiosk\Gent\Prompted Setup.json` ([examples](Answers/Examples)).
- **Unattended** (in the wizard or on the command line) asks nothing. Every answer must then be filled in, otherwise the restore stops before changing anything.

> ⚠️ A filled-in password is stored in plain text. Protect the file. Git ignores the `Answers` folder, except `Answers\Examples`.

---

## ♻️ Reusing Sections

Instead of data, a section can point to one file, or a list of files, relative to the root folder. A list is combined in order:

```json
"Items": {
  "UserAccounts": "Shared\\UserAccounts Kiosk.json",
  "RegistryKeys": [
    "Shared\\RegistryKeys Common.json",
    "Shared\\RegistryKeys Kiosk.json"
  ]
}
```

Change a shared file once, and every configuration that uses it is updated. See [`Combined Sections.json`](Configurations/Examples/Combined%20Sections.json) and [`Kiosk.json`](Configurations/Examples/Kiosk.json) for working examples.

---

## 🖥️ Command-Line Use

For shortcuts, scripts and deployment tools. Open PowerShell in the root folder.

**Restore** with a picker, then a yes/no question:

```powershell
& '.\Engine\Scripts\Invoke configuration.ps1'
```

**Restore** a specific file without the yes/no question:

```powershell
& '.\Engine\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Kiosk.json' -SkipConfirmation
```

**Restore unattended**, with only some sections. Run this from an administrator window:

```powershell
& '.\Engine\Scripts\Invoke configuration.ps1' -ConfigurationFile 'Configurations\Kiosk.json' `
    -AnswerFile 'Answers\Kiosk\Gent.json' -Items UserAccounts, NetworkCards -Unattended
```

**Create an answer file** with every placeholder set to `null`:

```powershell
& '.\Engine\Scripts\New answer file.ps1' -ConfigurationFile 'Configurations\Kiosk.json' -AnswerFile 'Answers\Kiosk.json'
```

**Export** without the wizard, here with scheduled tasks from two Task Scheduler folders:

```powershell
& '.\Engine\Scripts\Invoke scripts.ps1' -Action CreateSnapshot -ConfigurationFile 'Configurations\This PC.json' `
    -Items ScheduledTasks, FirewallRules -ExportOptions @{ ScheduledTasks = @{ TaskPath = '\HC\', '\Vendor\' } }
```

Useful restore options: `-RebootComputer $true`, `-RestartDelaySeconds 30` and `-OpenReportInBrowser $false` override the configuration's settings for one run.

> 🔗 **One-click restore:** see the shortcuts in `Configurations\Examples`, such as `Restore PC1 Immediately.lnk`. Copy one and change the file name to make your own.

---

## 💡 Tips

- **Start from an example:** `Configurations\Examples` has ready-made setups for a kiosk, office PC, production PC and Remote Desktop.
- **Be descriptive:** name configurations clearly (`Kiosk PC for app X`) and fill in `Description`. You'll thank yourself months later.
- **Test first:** restore on a test computer or virtual machine before you roll out.
- **Read the report:** every run writes one to `Log`. It shows what changed and which entries failed.
- **Upgrading from an older version?** See [Upgrading](Engine/README.MD#-upgrading-from-an-older-version) and the [version history](Engine/VERSION.MD).
