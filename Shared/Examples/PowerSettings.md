# PowerSettings

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [PowerSettings.json](PowerSettings.json).

## Power settings

`PowerSettings` chooses the active power plan and sets its timeouts, in minutes where 0 means never, for `AC` (plugged in) and `DC` (on battery):

```json
"PowerSettings": {
  "ActivePlan": "HighPerformance",
  "MonitorTimeoutMinutes": { "AC": 30, "DC": 10 },
  "SleepTimeoutMinutes": { "AC": 0, "DC": 30 },
  "HibernateEnabled": false
}
```

`ActivePlan` is `Balanced`, `HighPerformance` or `PowerSaver`, which work in every Windows language, a plan name as `powercfg /list` shows it, or a plan GUID. Laptops with modern standby often only have `Balanced`. The timeouts are set on the plan that is active after `ActivePlan`. `HibernateEnabled` false also turns off fast startup.
