# Repository bridges

Bridges expose Hub workflow, design, security, and validation policy inside
independent repositories without absorbing their Git history.

- `reference` creates a machine-local ignored `AGENTS.override.md`.
- `materialized` creates a local policy pack plus an ignored override.
- `repo-native` appends a versioned policy block to tracked `AGENTS.md` only
  after explicit acknowledgement.

Installation refuses unmanaged existing targets and returns an idempotent no-op
for a valid recorded bridge. Every install records mode, profile, version,
target, and digest under ignored Hub state. Doctor validates drift and unsafe
overrides.

Declare the full repository set in `hub/repositories.yaml`. Use `bridge plan
--all` for a deterministic read-only preview and `bridge install --all` for the
explicit apply. The apply writes an ignored receipt with checkout, bridge,
project-registration, and error state per repository. Repo-native mode requires
explicit authorization per repository.
