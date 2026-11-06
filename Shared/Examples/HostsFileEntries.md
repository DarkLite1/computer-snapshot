# HostsFileEntries

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [HostsFileEntries.json](HostsFileEntries.json).

## Hosts file

`HostsFileEntries` lists host names per IP address, for the Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`):

```json
"HostsFileEntries": [
  { "IPAddress": "10.20.60.47", "Hostnames": ["belsdaise0001", "belsdaise0001.grouphc.net"] },
  { "IPAddress": "fd00::47", "Hostnames": ["belsdaise0001-v6.grouphc.net"] },
  { "IPAddress": "{{ipv4:IP address of the print server}}", "Hostnames": ["printserver"] },
  { "Action": "Remove", "Hostnames": ["oldserver", "oldserver.grouphc.net"] }
]
```

- Each host name is made to point to its `IPAddress` (IPv4 or IPv6). A name that already does is left alone; a name that points to another address is moved, and the report says from which address; a missing name is added on a new line.
- `"Action": "Remove"` removes the host names, whatever address they point to. It has no `IPAddress`.
- Comments, empty lines and all other entries in the hosts file are kept as they are. A line whose names were all moved or removed is dropped.
- The file is only written when something changed. The previous version is kept as `hosts.bak`, and the DNS cache is cleared so the change works straight away.
- A host name may point to one address only, across the whole section, also when it is combined from several files in `Shared\`.
- An export writes every active line of the hosts file, one entry per address.
