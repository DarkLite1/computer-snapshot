# Computer Snapshot

Create and restore Windows computer configurations from a USB stick. Each configuration is one JSON file. Runtime requires **64-bit Windows PowerShell 5.1 or later** and the Windows features used by the selected items. No modules need to be installed on the target computer.

## Layout

```text
USB root/
	Configurations/  one JSON file per computer configuration
	Shared/          optional reusable JSON sections
	Software/        installers
	Files/           files to copy and reviewed custom scripts
	Log/             HTML execution reports
	Scripts/         production scripts and config.schema.json
		Common/      shared runtime modules and helpers
	Examples/        named JSON templates and example scripts
	Tests/           Pester test suites
		Common/      shared test helpers
		Fixtures/    test-only data
```

## Use the Wizard

Open **Start wizard.lnk**. Restore selects a configuration by name and description. Export selects items and an output name. The wizard calls the main script directly; it does not create an intermediate configuration or working folder.

The suggested export name is `COMPUTERNAME yyyy-MM-dd HHmmss` (for example, `KIOSK01 2026-10-21 142536.json`). You can edit it; explicitly supplied command-line filenames are unchanged.

The two example shortcuts use [Configurations/Example PC1.json](Configurations/Example%20PC1.json). That example runs the bundled hello-world executables; review any executable before running it.

## Command Line

From the USB root:

```powershell
& '.\Scripts\Invoke scripts.ps1' `
		-Action CreateSnapshot `
		-ConfigurationFile 'Configurations\My PC.json' `
		-Items UserAccounts, UserGroups, RegionalSettings

& '.\Scripts\Invoke configuration.ps1' `
		-ConfigurationFile 'Configurations\My PC.json'
```

Export refuses to overwrite an existing file unless `-Force` is supplied. It captures all selected sections in memory and writes one JSON file, plus its HTML report under `Log`. No temporary folders, per-item files, or copied assets are created. The `Configurations` directory must already exist.

Written JSON uses two-space indentation, with `Comment` first wherever present. Short arrays stay inline; arrays exceeding an 80-column target expand across lines. Individual strings, including task XML, remain intact and can exceed 80 columns. Formatting requires no external tools.

If an item fails, successful sections are still exported and failed items are listed in the console and report. If every item fails, no configuration is written. Post-export validation warnings commonly indicate example assets that have not been placed yet. Review the report before restoring.

`CreateFolders`, `RegistryKeys`, `Software`, `CopyFilesFolders` and custom scripts export templates, not a complete capture of those parts of the computer. Scheduled-task capture retains the existing `\HC\*` selection. Task XML and enabled state are stored inline. SMB shares include `Shares`, `Access` and optional `NTFS` permissions.

NTP export captures every configured manual peer in order. `TimeServerNames` contains server names, without the Windows per-peer flag suffixes.
Time-service command failures include the native exit code and diagnostics in the item failure; synchronization is reported as successful only after configuration, service restart and resynchronization succeed.

Network profiles are matched to adapters by interface index, so category changes still apply when restoring a different adapter name. Set `NetworkCardDnsSuffix` to `""` to clear a suffix; omit it or use `null` to leave the existing suffix unchanged.

## Configuration Format

```json
{
	"$schema": "../Scripts/config.schema.json",
	"SchemaVersion": 2,
	"Description": "Kiosk PC for application X",
	"Settings": {
		"RebootComputer": false,
		"OpenReportInBrowser": true,
		"RunElevated": false
	},
	"Items": {
		"UserAccounts": "Shared\\UserAccounts kiosk.json",
		"CreateFolders": {
			"Comment": "Folders required by the kiosk application.",
			"FolderPaths": ["C:\\Kiosk"]
		},
		"CopyFilesFolders": [
			{ "From": "Files\\Monitor SSD.ps1", "To": "C:\\Kiosk\\Monitor SSD.ps1" }
		],
		"Software": {
			"Remove": [],
			"Install": [
				{ "ExecutablePath": "Software\\App hello world 1.exe", "Arguments": null }
			]
		}
	}
}
```

- A present section is restored; a missing section is skipped. Empty objects and arrays are reported as "Nothing to do". There are no enable switches and no stored action.
- Execution order is fixed: custom scripts before, regional settings, users, groups, firewall, folders, shares, network cards, NTP, registry, tasks, copies, software, custom scripts after. JSON key order does not change execution order.
- A section is inline data or a JSON file path. The referenced file contains only that section, not a complete configuration. References cannot point to another reference.
- References, installer paths, copy sources and custom-script paths resolve against the USB root, never the current directory or the configuration file's folder. Absolute paths stay absolute. Environment variables such as `%SystemRoot%` are expanded before use. Destination and registry paths retain their Windows meaning.
- `Comment` is optional on section objects and is ignored when applying data. JSON comments and the old `?` property are not supported. Unknown properties are validation errors.
- Settings default to `RebootComputer: false`, `OpenReportInBrowser: true`, `RunElevated: false`. Elevation is handled by the launcher. Direct main-script invocation uses the current session's privileges.
- All input is validated before the first component runs. Validation problems are shown together in the console and HTML report. Runtime failures are reported per item; other items continue. Failed operations never trigger an automatic reboot.

## Shared Sections and Editing

For example, [Shared/UserAccounts kiosk.json](Shared/UserAccounts%20kiosk.json) contains a JSON array and is referenced by `Items.UserAccounts`. Its initial empty array deliberately makes no account changes. The same file can be referenced by several configurations.

Open a configuration in VS Code as **JSON**, leaving its `$schema` property in place. The bundled [Scripts/config.schema.json](Scripts/config.schema.json) supplies completion, hover descriptions and misspelled-key validation without an extension. Named templates such as [Examples/Software.json](Examples/Software.json) show each inline shape. Keep `Examples` on the USB stick: several export scripts read their templates there. A shared section is validated when its containing configuration is loaded.

Passwords remain plain text in `UserAccounts` and `RegistryKeys`, as before. Keep sensitive sections in access-controlled `Shared` files on encrypted media; a shared reference does not encrypt them. Never commit production credentials. Custom scripts and installers execute code with the session's privileges; use trusted assets only.

## Convert an Old Configuration

The main script never accepts the old format. Run the separate one-time converter:

```powershell
& '.\Scripts\Convert configuration.ps1' `
		-OldConfigurationFile 'Configurations\Old PC.json' `
		-RootFolder $PWD.Path
```

It writes `Configurations\Old PC.json`, renames the original to `Old PC.v1.json`, converts `?` notes to `Comment`, embeds scheduled-task XML, combines share permissions, and copies required assets to `Software` or `Files`. Old snapshot folders are never deleted. Existing asset files with different contents and existing migration backups are never overwritten. Validation results are printed at the end. Archive the `.v1.json` backup after reviewing the result; pickers exclude these backups.

## Tests

Development tests require **Pester 6**; production runtime does not require Pester. Run:

```powershell
Invoke-Pester .\Tests
```

Production entry scripts are directly under `Scripts`, and test suites directly under `Tests`, without a folder per script. Shared test helpers and fixtures are grouped under `Tests/Common` and `Tests/Fixtures`. The entire `Tests` folder is development-only and can be omitted from the target computer or USB stick.

Windows-changing operations are mocked, including local accounts, groups, shares and registry writes. Tests do not require administrator rights. Run the suite in Windows PowerShell 5.1 and PowerShell 7. Only the independent `Test-Json -SchemaFile` tests are skipped on 5.1; the dependency-free runtime validator is tested on both.