# Description

A PowerShell script designed to create and restore snapshots of Windows computers. 

This script is intended to run from a USB stick and is portable. The intent is to create a snapshot on one computer and restore the snapshot on another computer. Snapshots are by default stored on the USB stick in easily editable .JSON files.

# What can be restored?
A snapshot can contain different things:
- local user accounts
- local user groups
- smb shares and their SMB share and NTFS permissions
- Windows firewall rules
- regional settings
- registry keys
- folders to create
- files or folders to copy
- scheduled tasks to create
- network card renaming and network profile
- custom PowerShell scripts to run
- ...

# How to use this script

## Step 1: Configure the current computer to the desired state
Create local users, create local user groups and add users, create smb shares and set smb share permissions and NTFS permissions, configure firewall rules, ...

## Step 2: Create a snapshot
Plug in the USB stick that contains all the script files and run the script `Start-Script.ps1` with `$Action = 'CreateSnapshot'` and set the `$Snapshot` items to `$true` for the data you want to collect.

At this point a snapshot is created and saved on the USB stick in the `$SnapshotsFolder`.

## Step 3: Restore the snapshot on another computer
Plug in the same USB stick that contains all the script files and the collected snapshot data and run the script `Start-Script.ps1` with `$Action = 'RestoreSnapshot'` and set the `$Snapshot` items to `$true` for the data you want to restore.

At this point the data of the latest snapshot will be used to create or update the current computer to the desired state. In case you want to restore another snapshot than the last one created use the `$RestoreSnapshotFolder`.

# Quick and easy execution
The folder 'Configurations' holds .JSON files that represent the arguments used in 'Start-Script.ps1'. This can be convenient when you have multiple configurations on the USB stick but you only want to apply a specific snapshot. 

Click on 'Quick launcher.lnk' to open a new window. In the new window all files in the folder 'Configurations' are displayed. Select a single file to apply that configuration on the current machine.

 # Tips
- It is encouraged to modify the exported files to contain only the data you really need. This will speed up the process and reduces the risks. Use a text file editor like [Notepad++] or [VS Code] to edit the exported files. Simply remove the data you don't need or update data to your liking. You can then use the updated files with `$action = 'RestoreSnapshot'` and `$RestoreSnapshotFolder` . **_Less is more_**

- After making a snapshot it is advised to rename the folder in the snapshots folder to something more recognizable (ex. 'Image MyApp'). Then move it to another folder on the USB drive so you can start the restore process with the argument `$RestoreSnapshotFolder` set to the new folder (ex. `$RestoreSnapshotFolder = 'Production\Image MyApp'`). This way you are always certain the correct snapshot is restored. Otherwise, when not using `$RestoreSnapshotFolder`, the last created snapshot is restored which might lead to unexpected results. **_Know what you're doing_**

- Exporting all folders and registry keys on a computer would take ages. So some snapshot items like `CreateFolders` and `RegistryKeys` only create example files on `$Action = 'Export'`. These files should always be edited before running `$Action = 'Import'`.

[Notepad++]: https://notepad-plus-plus.org/
[VS Code]: https://code.visualstudio.com/