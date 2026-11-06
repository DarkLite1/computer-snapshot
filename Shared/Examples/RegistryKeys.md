# RegistryKeys

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [RegistryKeys.json](RegistryKeys.json).

## Registry changes

Each entry in `RegistryKeys` has an `Action`; without one, it sets a value.

| `Action`        | Needs                      | Does                                                                 |
| --------------- | -------------------------- | -------------------------------------------------------------------- |
| `Set`           | `Path`, `Name`, `Type`, `Value` | creates or changes a value, including missing keys               |
| `RemoveValue`   | `Path`, `Name`             | removes one value                                                    |
| `ClearValues`   | `Path`                     | removes all values of the key, keeps its subkeys                     |
| `ClearKey`      | `Path`                     | removes all values and subkeys, keeps the key                        |
| `RemoveKey`     | `Path`                     | removes the key with everything in it                                |

| `Type`                      | `Value`                                                       |
| --------------------------- | ------------------------------------------------------------- |
| `String`, `ExpandString`    | text; `%variables%` in an `ExpandString` stay as written       |
| `MultiString`               | a list: `["one", "two"]`                                       |
| `Binary`                    | hex text `"01 0A FF"`, or a list of numbers `[1, 10, 255]`     |
| `DWord`, `QWord`            | a number (`16`), or text in decimal (`"16"`) or hex (`"0x10"`) |

- `"Name": ""` is the key's (Default) value. `Path` can be `HKLM:\...`, `HKCU:\...` or `HKEY_LOCAL_MACHINE\...`.
- An unchanged value isn't rewritten, and removing something that doesn't exist is reported, not an error, so a configuration can be restored again.
- `ClearValues`, `ClearKey` and `RemoveKey` are refused for a hive root or a key directly below it, such as `HKLM:\SOFTWARE`.
- In `RunAsOtherUser`, `HKCU` means that user's registry.

```json
"RegistryKeys": [
  { "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Servers", "Type": "MultiString", "Value": ["srv1", "srv2"] },
  { "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Flags", "Type": "DWord", "Value": "0x10" },
  { "Action": "RemoveValue", "Path": "HKLM:\\SOFTWARE\\Vendor", "Name": "Obsolete" },
  { "Action": "ClearKey", "Path": "HKLM:\\SOFTWARE\\Vendor\\Cache" }
]
```
