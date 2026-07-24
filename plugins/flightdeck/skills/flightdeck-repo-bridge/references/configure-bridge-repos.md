# Configure bridge repositories runbook

This runbook is mandatory when the user asks to “configure bridge repos”,
“configure repository bridges”, “set up all repos”, or makes an equivalent
request. Execute it from the generated Hub. Bridge setup configures checkouts,
bridges, and saved projects; it does not create implementation tasks.

## 1. Read authority and declarations

1. Locate the Hub by walking upward to `flightdeck.yaml`.
2. Read the Hub's applicable `AGENTS.md` completely.
3. Read `flightdeck.yaml`, `hub/repositories.yaml`,
   `docs/workflows/configure-bridge-repos.md`, and
   `docs/workflows/repo-onboarding.md`.
4. Validate that every declaration contains:
   repository ID, workload, provider, credential-free locator, Hub-relative
   local path, owner, verified default branch, bridge profile/mode, and a
   `saved_exact_path` Codex project expectation with a stable logical project
   key. The declaration never requires or stores a Codex runtime project ID.
5. Refuse duplicate IDs, escaping paths, unknown providers/workloads,
   unverified default branches, credentials, or missing project expectations.

Default new declarations to `reference`. Use `materialized` when the repository
must remain portable without a machine-local Hub reference. Never select
`repo-native` by default.

## 2. Validate prerequisites and resolve metadata

Confirm usable Git and the provider tooling required by each declaration.
Confirm access to the live Codex project list and either native project
registration or the supported Codex/operating-system open-folder mechanism.

For each declaration, use the user's already-authenticated provider tools to
verify provider, owner, canonical locator/URL, and default branch. Do not copy
tokens, passwords, SSH material, credential-helper output, or authenticated
URLs into the Hub. If ownership or the default branch cannot be verified, mark
that repository blocked and do not clone or install its bridge.

## 3. Prepare or onboard checkouts

For each declared local path:

1. If the checkout exists, verify its exact Git root, origin when applicable,
   branch, SHA, and status. Preserve dirty, untracked, ignored, ahead, and
   behind state. Do not reset, clean, stash, switch branches, fetch, or pull as
   part of bridge setup.
2. If it is absent and clone authorization is within the user's request, run
   `bin/flightdeck repo plan` with the verified facts, inspect the plan, then run
   `bin/flightdeck repo onboard` under the declared workload root.
3. If an existing checkout is not registered, use `repo onboard` with the
   `existing-local` adapter and the exact resolved path.
4. Pass the declared safe bridge mode/profile to onboarding. A bridge already
   installed by onboarding must later appear as an idempotent no-op in the bulk
   apply.
5. For repo-native mode, stop and obtain explicit per-repository authorization
   after showing the tracked `AGENTS.md` target and expected portable policy
   change.

Never overwrite an existing `AGENTS.md`, `AGENTS.override.md`, materialized
pack, unmanaged bridge marker, or unrelated repository instruction.

## 4. Plan and apply bridges

Run the deterministic read-only plan:

```text
bin/flightdeck bridge plan --all --failure-policy stop --json
```

For every repository, review the exact Git root, checkout verification,
existing `AGENTS` files, profile/mode, targets, overwrite blockers, local
registry changes, and project-registration work.

The default failure policy is `stop`. Use `continue` only when the user
explicitly authorizes independent repositories to proceed after a failure.
Record every blocker; never weaken a declaration or delete a target merely to
make the apply pass.

Apply safe modes:

```text
bin/flightdeck bridge install --all --failure-policy stop --json
```

For each authorized repo-native declaration, add exactly one
`--authorize-repo-native <repository-id>` argument. Review the resulting
tracked diff for that repository before treating the bridge as installed.

The apply writes `hub/state/bridge-repos.json`, an ignored machine-readable
receipt. Valid existing bridges return `noop`. Drift, conflicts, unsafe
ignores, path mismatches, and missing registrations fail closed.
Receipt `ok` covers the local bridge apply; `complete` remains false until
every declared exact Codex project is live-list verified.

## 5. Doctor verification

Run:

```text
bin/flightdeck doctor --json
```

For every declaration, require:

- the recorded target and every artifact match their SHA-256 digest;
- `AGENTS.override.md` is untracked and Git-locally ignored;
- materialized packs are Git-locally ignored;
- portable materialized and repo-native content contains no absolute machine
  path;
- every profile-required Hub document exists;
- no unmanaged override or bridge marker displaced repository authority.

Doctor does not fetch. Report its ahead/behind values as local tracking-ref
observations.

## 6. Register and verify exact Codex projects

For each checkout:

1. Refresh the live project list.
2. Accept an existing project only when its normalized real path exactly equals
   the Git root. Never accept a display-name-only match.
3. Otherwise use a native project-registration capability when available.
4. If native registration is unavailable, use the supported Codex or
   operating-system open-folder mechanism for the exact Git root.
5. Refresh the live project list and require an exact normalized path match.
6. On failure, refresh capability state and retry the same registration/open
   path once.
7. Refresh again. Do not infer success from a UI action or folder name.
8. From the exact-path live-list match, capture the opaque runtime project ID.
   Keep it separate from the declaration's logical project key and use only the
   runtime ID for later task search, resume, or create.

After a second verified failure, record the error and give this one manual
action for that unresolved repository, substituting its exact Git root:

```text
In Codex, choose File > Open Folder, select "<exact-repository-path>", then reply "done".
```

Do not provide alternative actions. One unresolved repository may receive one
such action; independently resolved repositories keep their verified status.

Atomically record only live-list-verified results under ignored
`hub/state/projects.yaml` using the `CodexProjectVerifications` schema. Key each
record by the stable logical project key and record `logical_key`,
`runtime_project_id`, exact `path`, `verified: true`,
`verification_source: live_project_list_exact_path`, and `verified_at`. Never
write `verified: true` from a successful open action alone.

## 7. Final receipt and boundary

Rerun the bulk plan and idempotent bulk install after updating verified project
state. This refreshes `hub/state/bridge-repos.json` with, for every repository:

- checkout path, branch, SHA, origin when available, clean/dirty state;
- bridge status, mode/profile, record, and errors;
- logical project key, opaque runtime project ID, exact-path verification
  status, and remaining work.

Return the receipt path, per-repository outcome, Doctor result, and unresolved
manual actions. Do not create implementation tasks for bridge configuration.

When the user later requests project-owned work, resolve the owner, search
recent tasks using the verified opaque runtime project ID, resume or create the
owning task, and include the complete verified route-plan `bridge_handoff` in
the child prompt. This is required for ignored reference or materialized
bridges because a newly created Codex Worktree does not contain them: the child
reads repository instructions in the active checkout first, then verifies and
reads the bridge from its original checkout path. Return logical key/runtime
project ID/task ID/mode and authorization boundary, then stop without
monitoring.
