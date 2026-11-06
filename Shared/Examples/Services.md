# Services

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [Services.json](Services.json).

## Services

`Services` sets how Windows starts a service and, with `Status`, starts or stops it right away. It runs after `Software`, so the services of software installed by the restore can be set too. Use the service name, not the display name; `Get-Service` shows both:

```json
"Services": [
  { "Name": "wuauserv", "StartupType": "AutomaticDelayedStart" },
  { "Name": "Spooler", "StartupType": "Disabled", "Status": "Stopped" }
]
```

`StartupType` is `Automatic`, `AutomaticDelayedStart`, `Manual` or `Disabled`. Stopping a service also stops the services that depend on it. A service listed twice, or `Disabled` together with `Running`, is reported before anything is changed.
