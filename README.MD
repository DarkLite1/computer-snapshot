# 🖥️ Computer Snapshot

Computer Snapshot is a portable tool that lets you easily backup (export) and set up (restore) Windows computers directly from a USB stick. 

The best part? **No installation is required** on the computers you are managing. As long as the PC is running 64-bit Windows (PowerShell 5.1 or newer), you are good to go. Every computer's configuration is neatly saved as a single, easy-to-read text file.

## 🚀 Quick Start: Using the Wizard

The easiest way to use Computer Snapshot is through the built-in graphical wizard. 

1. Plug in your USB stick.
2. Double-click **`Start wizard.lnk`**.
3. **To set up a PC (Restore):** Select a saved configuration and click **Restore**. Review the section names and descriptions, uncheck anything you do not want to apply, then click **Restore selected**. **Select all** and **Clear all** help with larger selections; **Cancel** leaves the computer unchanged. The saved configuration file is not modified.
4. **To save a PC's setup (Export):** Click **Export**, review the item names and descriptions, choose which sections you want to save (like users, folders, or network settings), and give your file a name. Some sections export editable templates rather than current settings, so review the file before restoring it. *Tip: The wizard will suggest a handy default name like `KIOSK01 2026-10-21 142536.json`*.

When the wizard is not elevated, an optional **Restart as administrator** button appears above the tabs. Windows handles any administrator credentials or consent prompt according to its UAC policy; the wizard never collects UAC credentials. Cancelling the prompt keeps the current window open. You can also ignore the button and continue without elevation, although some Windows operations require administrator rights. Restarting opens a fresh wizard with the same configuration folder.

Restore selections apply to whole sections, not individual users, applications, or rules within them. Missing or empty sections in the selected configuration are shown in gray and cannot be checked; **Select all** checks only available sections. Empty arrays, empty objects, nulls, blank references and comment-only sections contain no settings to restore. Nonempty section references remain selectable and are resolved and validated when restoring. Only selected sections are resolved, validated, and executed. Command-line restores keep their existing all-sections behavior unless you pass `-Items`, for example `-Items UserAccounts,Software` to `Scripts\Invoke configuration.ps1`.

Below the restore checklist, **Restart computer after successful restore** and **Open report in browser** start with the configuration's `Settings.RebootComputer` and `Settings.OpenReportInBrowser` values. Change either checkbox to override it for this run only; the input file is never updated. When settings are omitted, restart defaults to off and opening the report defaults to on. Command-line restores accept the same per-run overrides, for example `-RebootComputer $false -OpenReportInBrowser $true`; omitted overrides continue to use the saved settings.

Once you run a task, you can check the `Log` folder for an easy-to-read HTML report showing exactly what succeeded and what failed.

## 📂 Know Your Folders

Your USB stick has a specific layout to keep everything organized. Here are the main folders you will use:

*   **`Configurations/`**: This is where your saved PC setups live (one file per computer).
*   **`Software/`**: Place any app installers (like `.exe` files) in here.
*   **`Files/`**: Put any standard files or custom scripts you want copied to the new PC here.
*   **`Shared/`**: A great place to keep standard, reusable settings (like a standard "Guest" user account) that you want to apply to multiple computers.
*   **`Log/`**: Check here for your execution reports.

## ✍️ Customizing Your Setups

All configurations are saved as standard JSON files. You can open and edit them in any code editor, like Visual Studio Code. 

*   **Smart Automation:** You don't need to worry about the order of operations. The script automatically handles things in a safe sequence (for example, creating user accounts before trying to copy files into their folders).
*   **Skipping Items:** If an item or section is missing from your file, the script simply skips it and moves on. 
*   **Safety First:** If a specific setting fails to apply, the tool won't crash. It will continue setting up the rest of the computer and log the error for you to review later. 

> **🔒 Important Security Warning:** 
> When you save settings that include passwords (like user accounts or certain registry keys), **they are saved in plain text**. Please keep your USB stick physically secure, and never upload files containing sensitive passwords to public spaces. 

## Restore-Time Input

Use a placeholder instead of a fixed string when a value changes between restores:

| Placeholder | Popup behavior |
| --- | --- |
| `{{input:Enter the local account name}}` | Required text input. |
| `{{password:Enter the local account password}}` | Required, masked input. Use this form for passwords and other secrets. |
| `{{ipv4:Enter the time-server IPv4 address}}` | Required IPv4 address, such as `192.0.2.10`; invalid addresses cannot be submitted. |

The text after the colon is the field description shown in the popup. The configuration field path is also displayed. For example, a user-account entry can contain:

```json
{
	"Name": "{{input:Enter the local account name}}",
	"Password": "{{password:Enter the local account password}}"
}
```

Select the configuration, click **Restore**, review the section checklist, and click **Restore selected**. After any required UAC elevation, a popup requests each value. **Continue** accepts a valid answer; **Cancel**, Escape, or closing any input popup cancels the entire restore before any sections run. All answers are collected and the resolved configuration is validated before applying settings. Windows may still reject an otherwise valid answer, for example because of password policy.

Placeholders work in string values inside `Items`, including nested objects, arrays, and referenced shared sections. Only selected sections prompt. An identical placeholder (including its type and description) asks once and reuses the answer within that restore; use different descriptions to request independent values. Comments, metadata, settings, property names and section-reference filenames are not input fields. Do not use placeholders for numbers or booleans, or embed them within larger strings. Answers are used literally, not evaluated as PowerShell or expanded as further placeholders.

Command-line restores use the same popups and require an interactive Windows desktop. Browsing configurations and exporting do not prompt. For unattended restores, provide ordinary configuration values instead.

See [Configurations/Example prompted setup.json](Configurations/Example%20prompted%20setup.json) for a complete example. It prompts for a local account name, its password, and an NTP time-server IPv4 address. Restoring it creates or updates the named account and changes time synchronization; uncheck either section to skip it. This example does not set a network adapter's static IP address, which the current `NetworkCards` section does not support.

**Password handling:** Answers are kept in memory for the current run. The original configuration and shared files are not rewritten, and answers are not included in the wizard's process-launch arguments or a resolved temporary JSON file. Password placeholders mask typing and redact exact matches from the tool's generated results, HTML reports and captured PowerShell child output. This is not encrypted storage: the restore scripts receive plain strings in memory, and custom scripts or external programs can independently log, persist or transform them. Only run trusted scripts and use `password` placeholders for sensitive values. Ordinary `input` answers are not redacted.

## 🔄 Upgrading from an Older Version?

If you have old configuration files from a previous version of this tool, they won't work right away. But don't worry—there's an automatic converter!

Just open PowerShell from your USB stick and run:
```powershell
& '.\Scripts\Convert configuration.ps1' -OldConfigurationFile 'Configurations\Old PC.json' -RootFolder $PWD.Path
```
This will automatically update your old file to the new format and safely back up your original setup as a `.v1.json` file just in case.