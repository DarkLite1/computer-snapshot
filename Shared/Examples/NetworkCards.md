# NetworkCards

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [NetworkCards.json](NetworkCards.json).

## Network cards and IP settings

Each entry in `NetworkCards` has two parts: `FindBy` says how to find the card, `Change` says what to change on it. Nothing in `FindBy` is ever changed.

```json
"NetworkCards": [
  {
    "FindBy": { "Name": "Ethernet" },
    "Change": {
      "NewName": "LAN",
      "IPSettings": {
        "IPAddress": "{{ipv4:IP address of this PC}}",
        "PrefixLength": "{{prefix:Prefix length, such as 24}}",
        "DefaultGateway": "{{ipv4:Default gateway}}",
        "DNSServers": ["10.75.38.23", "10.75.38.22"]
      }
    }
  },
  {
    "FindBy": { "Description": "Broadcom" },
    "Change": { "IPSettings": { "Dhcp": true } }
  }
]
```

`FindBy` has exactly one of:

| `FindBy`      | Finds the card                                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Description` | by its description, the name in Device Manager: an exact match first, otherwise the one card containing the text. The driver sets the description; it can't be changed. |
| `Name`        | by its current name, such as `Ethernet`, before any rename; names can differ per computer                                         |
| `OnlyCard`    | `true`: the one physical card of the computer, for PCs with a single network card. `"Wired"` or `"WiFi"`: the one card of that kind, such as the Ethernet card of a laptop that also has Wi-Fi. VPN, virtual (such as a Hyper-V switch) and Bluetooth adapters don't count; with no or several such cards the entry fails and lists the cards. |

`Change` can hold, applied in this order; anything left out stays as it is:

| `Change`          | Does                                                                     |
| ----------------- | ------------------------------------------------------------------------ |
| `NewName`         | renames the card                                                         |
| `DnsSuffix`       | sets the connection-specific DNS suffix; an empty string clears it        |
| `NetworkCategory` | sets the network profile, such as `Private` or `Public`                  |
| `IPSettings`      | sets the IPv4 address, gateway and DNS servers, see below                |

- A static address needs `IPAddress` and `PrefixLength`. It turns DHCP off and replaces all IPv4 addresses and the default gateway of the card. `DefaultGateway` is optional and must be in the same subnet.
- `{ "Dhcp": true }` makes the address automatic again; static addresses and the gateway are removed, and hand-set DNS servers too unless `DNSServers` is given.
- `DNSServers` replaces the DNS servers, in order of use. An empty list makes DNS automatic; leaving it out keeps the current DNS servers.
- Use `{{ipv4:...}}` and `{{prefix:...}}` placeholders to ask for the values during the restore (see [Restore-Time Input](../../README.MD#-restore-time-input-placeholders)).
- When a change to the IPv4 settings fails, for example because the address is already in use, the previous settings are put back: DHCP on or off, the addresses, the default gateway and the DNS servers. The report names the failure and says whether restoring them worked.
- An export finds each card by its description and writes its current name in `NewName`, with its settings: `Dhcp: true`, or its static address, prefix and gateway, plus DNS servers that were set by hand. A card with several IPv4 addresses exports the first one; the report says so.
- A static address is exported as a placeholder that shows the exported address, for example `"IPAddress": "{{ipv4:IP address of network card 'Ethernet' (was 192.168.1.20)}}"`, so restoring on several PCs never gives them all the same address. Restoring on the same PC means retyping the address shown; for an unattended restore, put it in the answer file (`New answer file.ps1` lists it). `PrefixLength`, `DefaultGateway` and `DNSServers` are exported as they are, because they are normally the same for every PC on that network. The export report names each card that got a placeholder.

> Changing the IP address of the card you are connected through, for example over remote desktop, ends that connection. Restore network settings at the computer itself.
