# AccountPolicy

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [AccountPolicy.json](AccountPolicy.json).

## Password and lockout policy

`AccountPolicy` sets the local password rules and account lockout, before `UserAccounts` creates accounts with passwords that must meet them. Leave out a setting to keep it as it is:

```json
"AccountPolicy": {
  "MinimumPasswordLength": 12,
  "PasswordComplexity": true,
  "MaximumPasswordAgeDays": 0,
  "LockoutThreshold": 5,
  "LockoutDurationMinutes": 15,
  "ResetLockoutCounterMinutes": 15
}
```

`MaximumPasswordAgeDays` 0 means passwords never expire, `LockoutThreshold` 0 never locks an account and `LockoutDurationMinutes` 0 keeps an account locked until an administrator unlocks it. The policy is read back after the change; a setting Windows refused, such as a lockout duration shorter than `ResetLockoutCounterMinutes`, is reported as an error. On a computer in a domain, a group policy can overwrite these local settings.
