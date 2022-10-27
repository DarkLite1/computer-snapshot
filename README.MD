# Description
A PowerShell script designed to create and restore snapshots on Windows computers.

This script is intended to run from a USB stick and is portable. The intent is to create a snapshot on one computer and restore the snapshot on another computer. Snapshots are by default stored on the USB stick in easily editable .JSON files.

# Snapshots

### What can be backed up or restored?
Find a full list of supported snapshot items in the argument `Snapshot` of the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1). Summary of the most used snapshot items:

- Files or folders to copy
- Folders to create
- Regional settings
- Registry keys
- SMB shares and their SMB share and NTFS permissions
- User accounts
- User groups
- Windows firewall rules
- Windows scheduled tasks to create
- Network card renaming and network profile
- Custom PowerShell scripts to run before or after execution
- ...

### What is a snapshot folder?
A snapshot is a single folder ([SnapshotFolder](./Snapshots/RestoreSnapshot%20PC1%20Example)) that contains the state of a machine at the time a backup was made. This folder can contain multiple child folders, one for each selected snapshot item during the backup. Each of these child folders contain the saved configuration files that can be edited.

Example:
```bash
├── Snapshots
│   ├── Kiosk PC app X (`SnapshotFolder`)
│   │   ├── CopyFilesFolders
│   │   ├── FirewallRules
│   │   ├── SMBshares
│   ├── Kiosk PC app Y (`SnapshotFolder`)
│   │   ├── NtpTimeServers
│   │   ├── RegionalSettings
│   │   ├── RegistryKeys
```
# How to use this script

## Use the graphical user interface

This is the **preferred way** to restore or backup a computer.

The shortcut launcher `Start wizard` starts a GUI that will guide you through the process. It will ask questions like: Would you like to create or restore a backup? What would you like to backup or restore? Where do we need to store the backup files? ..

The wizard comes preconfigured with default settings and best practices. It creates the required .JSON file that is used to execute the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1) with the correct arguments. No manual file editing is required when using this method.

## Use manual input files

This method is only available for **experienced users**.

The required configuration files can also be created manually. These files are used to send the correct arguments to the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1) for execution.

### Step 1: Create your custom configuration file
By preference it's a good idea to copy the example .JSON file that can be found in the folder [Configurations](./Configurations) and save it with a new name.

Edit the file to your liking. All accepted arguments can be found in the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1).

### Step 2: Execute your custom configuration file
Click on the shortcut launcher `Select configuration` and select the custom .JSON file in the window that pops up. The [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1) will now be executed with the arguments provided in the .JSON file.

 # Tips
- It is encouraged to modify the exported files in the child folders of the [SnapshotFolder](./Snapshots/RestoreSnapshot%20PC1%20Example) to contain only the data you really need. This will speed up the process and reduces the risks. Use a text file editor like [Notepad++] or [VS Code] to edit the exported files. Simply remove the data you don't need or update data to your liking. **_Less is more_**

- When creating a snapshot it is advised to use a descriptive name to identify the correct image folder within the [SnapshotFolder](./Snapshots) (ex. 'Kiosk PC config for application X'). This allows you to easily recognize the correct backup folder months later when a restore is needed. **_Know what you're doing_**

- Exporting all data on a computer would take a long time. So some snapshot items like `CreateFolders`, `RegistryKeys`, [Software](./Snapshots/RestoreSnapshot%20PC1%20Example/Software) only create example files that need to be edited before starting the restore backup process.

[Notepad++]: https://notepad-plus-plus.org/
[VS Code]: https://code.visualstudio.com/