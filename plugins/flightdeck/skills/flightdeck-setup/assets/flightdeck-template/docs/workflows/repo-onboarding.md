# Repository onboarding

For ordinary existing checkouts, prefer:

```text
bin/flightdeck setup plan --repositories-root <absolute-root> --json
bin/flightdeck setup connect --repositories-root <absolute-root> --json
```

This discovers repositories under the authorized root, attaches them in place,
creates portable declarations, and installs safe ignored reference bridges.
Absolute attached paths remain in ignored local state. Dirty state is reported
and preserved.

Use `repo plan` first. For onboarding:

1. Resolve provider, ownership, canonical URL, and default branch. Pass the
   verified owner and default branch to `repo onboard`; generic Git requires an
   explicit owner. Provider hosts are configurable without credentials.
2. Clone under the configured workload root using argument-safe commands, or
   verify the exact existing-local Git root.
3. Verify origin, branch, SHA, and status. Require new clones to be clean;
   preserve and report existing-local changes without cleaning them.
4. Install a bridge without overwriting instructions.
5. Atomically update ignored local registry state.
6. Register the exact checkout as a saved Codex project.
7. Refresh and verify an exact normalized real-path match in the live project
   list. Keep the stable logical project key separate and capture the opaque
   runtime project ID from that match; display names are not identity.
8. Search for a matching task with the opaque runtime project ID, create one if
   needed, return both identities and the task ID, and stop.

Use the lower-level `repo plan` and `repo onboard` path for an explicitly named
clone, provider-specific onboarding, or a repository that cannot be classified
by discovery. Supported adapters are GitHub, GitLab, Bitbucket, generic Git,
existing-local, and remote-validation. Credentials are supplied by the user's
configured tools and are never stored in the Hub.

For the declared repository set, keep credential-free facts in
`hub/repositories.yaml` and follow
`docs/workflows/configure-bridge-repos.md`. Onboarding one missing checkout may
install its declared bridge; the required later bulk apply must recognize that
valid bridge as an idempotent no-op.
