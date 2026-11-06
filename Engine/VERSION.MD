# Version 3.0
Breaking changes, check these on every USB stick you update:
- New folder layout. The tool moved from `Scripts\` to `Engine\Scripts\`, its shared code to `Engine\Common\`, the schemas to `Engine\Schemas\` and the tests to `Engine\Tests\`. Update copied shortcuts and scheduled jobs that call `Scripts\...`.
- Configurations are `SchemaVersion` 3. Convert older files with `Engine\Scripts\Convert configuration.ps1`.
- Change the `$schema` line of your own configurations to `../Engine/Schemas/config.schema.json` to keep the editor hints. Restoring works without it.
- The bundled examples moved: section examples to `Shared\Examples\`, example configurations and their shortcuts to `Configurations\Examples\`, answer examples are named after their configuration. Configurations that point to `Examples\...` need `Shared\Examples\...`.
- `-Confirm` of `Invoke configuration.ps1` is now `-SkipConfirmation`.

New sections:
- `AccountPolicy`: local password rules and account lockout, set before `UserAccounts`.
- `EnvironmentVariables`: variables for the computer or the restoring account, with `AddToList` and `RemoveFromList` for lists such as `Path`. Secret-looking values are exported as password placeholders.
- `Services`: startup type and running state, after `Software`.
- `PowerSettings`: active power plan, display, sleep, hibernate and disk timeouts, and hibernation.
- `HostsFileEntries`: host names in the Windows hosts file.

Changed sections:
- `RegionalSettings`: language list with keyboards and the display language.
- `NetworkCards`: `FindBy` (description, name or the only card) and `Change`, with static or DHCP IPv4 settings, DNS registration, NetBIOS and IPv6. A failed IPv4 change puts the old settings back.
- `ScheduledTasks`: run as a specific account with a saved password, which gets 'Log on as a batch job' when needed; tasks from exported XML files; choose the folders to export.
- `Software`: remove applications by pattern with their own uninstall options, time limits, success exit codes per installer.
- `RegistryKeys`: set, remove and clear values and keys of every type.
- `UserAccounts`, `UserGroups`, `SmbShares`: built-in accounts by English name, so configurations work in every Windows language.
- Every section reports failures per entry in `Errors` and keeps going with the other entries.

Restore and wizard:
- Restore-time input with `{{input}}`, `{{password}}`, `{{ipv4}}`, `{{prefix}}` and `{{number}}` placeholders, also inside copied files, answered in one form or from answer files in `Answers\`, also unattended.
- The wizard restores in steps: configuration, sections, answer file, questions and review, and lists configurations in subfolders.
- A section can be built from several files in `Shared\`.
- Ready-made examples for Remote Desktop, kiosk auto logon, File Explorer and Windows suggestions, and example configurations for a kiosk, office PC, production PC and Remote Desktop.
- Editor hints for section files in `Shared\` and `Shared\Examples\`.
- The restart countdown is a setting, adjustable in the wizard; a restart only happens after a successful restore.

# Version 2.0
- Breaking change: one SchemaVersion 2 JSON configuration replaces the old StartScript wrapper and per-item input folders. Runtime does not support the previous format.
- Child scripts accept Action, Data and RootFolder and return one Data/Messages object. Existing Windows apply and capture logic is retained behind that contract.
- Export writes inline data directly, with no staging folders or intermediate files. HTML reports remain in Log. Partial exports retain successful items; an all-failed export writes no configuration.
- Add a separate converter that renames the original JSON and preserves legacy snapshot data and assets.
- Add Shared section references, fixed execution order, root-relative asset paths, aggregate preflight validation, and a bundled JSON schema with VS Code completion.
- Replace the generated folder wizard with a native configuration picker and direct export workflow.
- Scheduled tasks now carry XML and enabled state inline; import explicitly restores the enabled state. SMB and NTFS data are combined into one section.
- Failed runs no longer reboot automatically. HTML report messages are encoded before rendering.
- Pester 6 tests mock Windows changes and support Windows PowerShell 5.1. PowerShell 7 additionally checks the JSON schema with Test-Json.

# Version 1.3
- Add `Start wizard` and GUI script

# Version 1.2
- Changes in `Start-Script.ps1`:
    - rename `Start-Script.ps1` to `Invoke scripts.ps1`
    - moved to its own folder `Scripts\Invoke scripts\Invoke scripts.ps1`
    - rename `RestoreSnapshotFolder` to `SnapshotFolder`
    - rename `RebootComputerAfterRestoreSnapshot` to `RebootComputer`
    - `SnapshotFolder` is now mandatory in all cases

# Version 1.1
- Add support for relative paths to `Start-Script.ps1`

# Version 1.0
- Add support for installing software executables in other locations
  Update `Software.json`:
    - rename `ExecutableName` to `ExecutablePath`
    - use `.\Packages\foobar.exe` instead of `foobar.exe`