# SmbShares

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [SmbShares.json](SmbShares.json).

## SMB shares

`SmbShares` is a list with one entry per share. Each share has its settings, its share permissions in `Access`, and the permissions of its folder in `NTFS`:

```json
"SmbShares": [
  {
    "Name": "Data",
    "Path": "C:\\Data",
    "Access": [
      { "AccountName": "BUILTIN\\Administrators", "AccessControlType": "Allow", "AccessRight": "Full" },
      { "AccountName": "NT AUTHORITY\\Authenticated Users", "AccessControlType": "Allow", "AccessRight": "Change" }
    ],
    "NTFS": {
      "Owner": "BUILTIN\\Administrators",
      "AreAccessRulesProtected": false,
      "Access": [
        { "IdentityReference": "BUILTIN\\Users", "AccessControlType": "Allow", "FileSystemRights": "Modify, Synchronize", "InheritanceFlags": "ContainerInherit, ObjectInherit", "PropagationFlags": "None" }
      ]
    }
  },
  {
    "Name": "Scans",
    "Path": "D:\\Scans",
    "Access": [ { "AccountName": "BUILTIN\\Users", "AccessControlType": "Allow", "AccessRight": "Read" } ]
  }
]
```

- A share without `Access` keeps its current share permissions; a share without `NTFS` keeps the current permissions of its folder.
- Configured permissions are applied first. Existing share permissions that aren't configured are only removed when every configured one could be applied, so a share never ends up with less access than configured.
- Each share name may appear only once.
