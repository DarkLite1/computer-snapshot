# UserAccounts

Part of the [Computer Snapshot README](../../README.MD); the format of every setting is in [UserAccounts.json](UserAccounts.json).

## Removing local user accounts

Use `Action: "Remove"` in `UserAccounts` instead of a custom removal script:

```json
"UserAccounts": [
  { "Name": "bob", "Action": "Remove" }
]
```

- Without `Action`, or with `Action: "Set"`, the existing create/update
  behavior is unchanged.
- Removal accepts only `Name`, `Action` and an optional `Comment`. Do not
  include a password or other account settings.
- Use an exact local account name (case-insensitive), not a wildcard,
  domain-qualified name or SID. Only named accounts are removed.
- Windows built-in accounts (even renamed ones) and the account running the
  restore are protected by SID; attempts to remove them are reported as errors.
- The last enabled local administrator is never removed. Another enabled
  local account, or a domain or Azure AD user or group, in the
  Administrators group counts as another administrator. When the members of
  that group cannot be read, removal is refused.
- An account that is already absent is reported as nothing to remove.
  Other failures are reported, and remaining entries are still processed.
- This deletes the account, **not its Windows profile or files**. Recreating
  the same name creates a different SID and does not restore its old permissions.
- Run as administrator. Removal cannot be undone by this tool; review the
  names before restoring.

See [Shared/Examples/UserAccounts.json](UserAccounts.json) for a mixed
create/update/removal example. Exports still capture only existing accounts
for creation or update; they never generate removal actions.
