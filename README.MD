# Description
A PowerShell script designed to create and restore snapshots on Windows computers.

This script is intended to run from a USB stick and is portable. The intent is to create a snapshot on one computer and restore the snapshot on another computer with the `Start wizard.lnk` shortcut. 

Snapshot data is stored by default on the USB stick in the folder [Snapshots](./Snapshots). Preconfigured configuration files, for fast and easy execution with the `Select configuration.lnk` shortcut, are stored in the folder [Configurations](./Configurations).

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
A [SnapshotFolder](./Snapshots/RestoreSnapshot%20PC1%20Example) is a single folder within the folder [Snapshots](./Snapshots) that contains the state of a machine at the time a backup was made. This folder can contain multiple child folders, one for each selected snapshot item during the backup. Each of these child folders contain configuration files that can be edited.

Example:
```bash
├── Snapshots
│   ├── Kiosk PC app X (`SnapshotFolder`)
│   │   ├── Software
│   │       ├── Software.json (`file to edit`)
│   ├── Kiosk PC app Y (`SnapshotFolder`)
│   │   ├── NtpTimeServers
│   │       ├── ntpServers.json (`file to edit`)
│   │   ├── RegionalSettings
│   │       ├── regionalSettings.json (`file to edit`)
│   │   ├── RegistryKeys 
│   │       ├── registryKeys.json (`file to edit`)
```
# How to use this script

## Use the graphical user interface

This is the **preferred way** to restore or backup a computer.

The shortcut `Start wizard.lnk`, in the root folder of the script, starts a GUI that will guide you through the process. It will ask questions like: Would you like to create or restore a backup? What would you like to backup or restore? Where do we need to store the backup files? ..

The wizard comes preconfigured with default settings and best practices. It creates the required .JSON file that is used to execute the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1) with the correct arguments. No manual file editing is required when using this method, except for the backup/restore files within the [SnapshotFolder](#what-is-a-snapshot-folder).

## Use manual input files

This method is only available for **experienced users**.

The folder [Configurations](./Configurations) contains preconfigured .JSON files that contain the required arguments to execute the [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1). These files are only used by the shortcut `Select configuration.lnk`, which avoids all the extra questions asked by the `Start wizard.lnk` launcher. 

### Step 1: Create a custom configuration file
There are 2 ways to create a custom configuration file for use with the `Select configuration.lnk` launcher:
- Create a backup with the `Start wizard.lnk` and copy the generated .JSON file to the folder [Configurations](./Configurations)
- Copy the example .JSON file in the folder [Configurations](./Configurations) and save it with a new name

In case you are creating a restore configuration file make sure that `Action` is set to `RestoreBackup` and only the required `Snapshot` items are set to `true`.

### Step 2: Update the data in the snapshot folder
If you want to do a restore verify that all data in the [SnapshotFolder](#what-is-a-snapshot-folder) is correct. 

### Step 2: Execute the custom configuration file
Click on the shortcut `Select configuration.lnk`, in the root folder, and select the custom .JSON file in the window that pops-up. The [main script](./Scripts/Invoke%20scripts/Invoke%20scripts.ps1) will now be executed with the arguments provided in the selected .JSON custom configuration file.

 # Tips
- It is encouraged to modify the exported files in the [SnapshotFolder](#what-is-a-snapshot-folder) to contain only the data you really need. This will speed up the process and reduces the risks. Use a text file editor like [Notepad++] or [VS Code] to edit the exported files. Simply remove the data you don't need or update data to your liking. **_Less is more_**

- When creating a snapshot it is advised to use a descriptive name to identify the correct [SnapshotFolder](#what-is-a-snapshot-folder) (ex. 'Kiosk PC config for application X'). This allows you to easily recognize the correct backup folder months later when a restore is needed. **_Know what you're doing_**

- Exporting all data on a computer would take a long time. So some snapshot items like `CreateFolders`, `RegistryKeys`, [Software](./Snapshots/RestoreSnapshot%20PC1%20Example/Software) only create example files that need to be edited before starting the restore backup process.

[Notepad++]: https://notepad-plus-plus.org/
[VS Code]: https://code.visualstudio.com/