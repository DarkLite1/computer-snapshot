# Description

A PowerShell script designed to create and restore snapshots of Windows computers. 

This script is intended to be run from a USB stick and is portable. The intend is to create a snapshot on one computer and restore a snapshot on another computer. Snapshots can contain firewall rules, local user accounts, local user groups, smb shares and their permissions, ...

# How to use this script

## Step 1: Configure the current computer to the desired state
Create local users, create local user groups and add users, create smb shares and set smb share permissions and NTFS permissions, configure firewall rules, ...

## Step 2: Create a snapshot
Plug in the USB stick that contains all the script files and run the script `Start-Script.ps1` with `$Action = 'CreateSnapshot'` and set the `$Snapshot` items to `$true` for the data you want to collect.

At this point a snapshot is created and saved on the USB stick in the `$SnapshotsFolder`.

## Step 3: Restore the snapshot on another computer
Plug in the same USB stick that contains all the script files and the collected snapshot data and run the script `Start-Script.ps1` with `$Action = 'RestoreSnapshot'` and set the `$Snapshot` items to `$true` for the data you want to restore.

At this point the data of the latest snapshot will be used to create or update the current computer to the desired state. In case you want to restore another snapshot than the last one created use the `$RestoreSnapshotFolder`.

 # Tips
- It is encouraged to modify the exported files to contain only the data you really need. This will speed up the process and reduces the risks. Use something like [Notepad++] or [VS Code] to edit the exported files. Simply remove the data you don't need or update data to your liking. You can then use the updated files with `$action = 'RestoreSnapshot'` and `$RestoreSnapshotFolder` # less is more

- After making a snapshot it is advised to rename the folder in the snapshots folder to something more recognizable (ex. 'Image MyApp'). Then move it to another folder on the USB drive so you can start the restore process with the argument `$RestoreSnapshotFolder` set to the new folder (ex. `$RestoreSnapshotFolder = 'Production\Image MyApp'`). This way you are always certain the correct snapshot is restored. Otherwise, when not using `$RestoreSnapshotFolder`, the last created snapshot is restored which might lead to unexpected results. # know what you're doing

[Notepad++]: https://notepad-plus-plus.org/
[VS Code]: https://code.visualstudio.com/