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