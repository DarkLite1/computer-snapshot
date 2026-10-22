# 🖥️ Computer Snapshot

Computer Snapshot is a portable tool that lets you easily backup (export) and set up (restore) Windows computers directly from a USB stick. 

The best part? **No installation is required** on the computers you are managing. As long as the PC is running 64-bit Windows (PowerShell 5.1 or newer), you are good to go. Every computer's configuration is neatly saved as a single, easy-to-read text file.

## 🚀 Quick Start: Using the Wizard

The easiest way to use Computer Snapshot is through the built-in graphical wizard. 

1. Plug in your USB stick.
2. Double-click **`Start wizard.lnk`**.
3. **To set up a PC (Restore):** Select a saved configuration and click **Restore**. Review the section names and descriptions, uncheck anything you do not want to apply, then click **Restore selected**. **Select all** and **Clear all** help with larger selections; **Cancel** leaves the computer unchanged. The saved configuration file is not modified.
4. **To save a PC's setup (Export):** Click **Export**, review the item names and descriptions, choose which sections you want to save (like users, folders, or network settings), and give your file a name. Some sections export editable templates rather than current settings, so review the file before restoring it. *Tip: The wizard will suggest a handy default name like `KIOSK01 2026-10-21 142536.json`*.

When the wizard is not elevated, an optional **Restart as administrator** button appears above the tabs. Windows handles any administrator credentials or consent prompt according to its UAC policy; the wizard never collects passwords. Cancelling the prompt keeps the current window open. You can also ignore the button and continue without elevation, although some Windows operations require administrator rights. Restarting opens a fresh wizard with the same configuration folder.

Restore selections apply to whole sections, not individual users, applications, or rules within them. Sections missing from the selected configuration are shown in gray and cannot be checked; **Select all** checks only available sections. Sections present in the file remain selectable even if their contents are empty. Only selected sections are resolved, validated, and executed; configuration-level options such as automatic restart still apply. Command-line restores keep their existing all-sections behavior unless you pass `-Items`, for example `-Items UserAccounts,Software` to `Scripts\Invoke configuration.ps1`.

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

## 🔄 Upgrading from an Older Version?

If you have old configuration files from a previous version of this tool, they won't work right away. But don't worry—there's an automatic converter!

Just open PowerShell from your USB stick and run:
```powershell
& '.\Scripts\Convert configuration.ps1' -OldConfigurationFile 'Configurations\Old PC.json' -RootFolder $PWD.Path
```
This will automatically update your old file to the new format and safely back up your original setup as a `.v1.json` file just in case.