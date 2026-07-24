# Bridge contract

Every bridge record contains:

- repository ID and resolved Git root
- profile, mode, and bridge version
- target instruction path
- expected SHA-256 digest
- Hub root and required relative document paths
- installation timestamp

Declared repositories live in `hub/repositories.yaml`. Each declaration
contains ID, workload, provider, locator, Hub-relative checkout path, owner,
verified default branch, bridge profile/mode, and exact Codex saved-project
expectation with a stable logical project key. The declaration never stores a
Codex runtime project ID. That opaque ID enters ignored state only after a
refreshed live project list contains an exact normalized path match.

`reference` mode uses a machine-local ignored override and may reference the
absolute Hub path. `materialized` mode copies an ignored portable policy pack
under `.flightdeck/bridge/` and uses only repository-relative references.
`repo-native` mode appends a portable minimum policy to the existing tracked
`AGENTS.md`; it contains no Hub or repository absolute path and requires the
explicit acknowledgement flag plus review of the resulting diff.

Ignored reference and materialized files are not present in a newly created
Codex Worktree. For later project-owned dispatch, `route plan` verifies the
bridge record and emits a `bridge_handoff` with the original checkout path,
target and artifact paths, and their SHA-256 digests. The child prompt carries
that complete handoff. The child reads active-Worktree repository instructions
first, then verifies and reads the ignored bridge from the original checkout.
It never copies the bridge into the Worktree. Repo-native policy is tracked and
is read directly in the Worktree.

Never overwrite existing instructions. An update must show the old and new
digest and preserve unrelated content. Doctor fails on digest drift, a missing
tracked instruction boundary, unprotected overrides, invalid modes, missing Hub
references, a record whose target resolves outside the repository, or a
machine-specific absolute path in portable bridge content. Absolute roots in
ignored local registry records are runtime metadata, not portable content.

`bridge plan --all` is read-only. `bridge install --all` uses an explicit
`stop` or `continue` failure policy and writes one ignored per-repository
receipt. A valid record and artifacts produce `noop`; any mismatch is drift,
not permission to overwrite. Repo-native mutation additionally requires
`--authorize-repo-native <repository-id>` for every reviewed repository.
