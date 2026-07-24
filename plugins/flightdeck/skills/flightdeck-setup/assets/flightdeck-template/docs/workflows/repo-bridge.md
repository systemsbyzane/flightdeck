# Repo Bridge Design

Nested repos such as `development/backend` are separate Git repos. When
opened as Codex projects, they load their own repo instructions. They should not
be expected to automatically inherit this hub's `AGENTS.md`.

The bridge makes the hub docs available from repo-level work without blurring
repo ownership.

## Recommended Bridge Level

Use **Level 1** first.

### Level 1: Reference Bridge

Add a small section to each repo `AGENTS.md` that:

- names the hub path: `<hub-root>`
- references the hub docs for design, security, workflow, and validation
- embeds the minimum mandatory checklist
- states that repo-specific commands and code rules still win

This is fast and works well for local Mac Codex projects. It also works for
local Codex-managed worktrees when the hub path remains readable from the same
machine and the dispatch prompt carries the verified original-checkout bridge
handoff. Ignored files themselves do not appear in a new Worktree.

### Level 2: Materialized Bridge Pack

Copy a small `docs/flightdeck-bridge/` pack into each repo if you need the
guides to travel with worktrees, cloud tasks, or other machines. This adds
duplication but removes dependence on the absolute hub path.

The installed pack remains ignored. A local Codex Worktree reads it through
the verified original-checkout paths and digests emitted by `route plan`; it is
not copied into the Worktree. To make policy physically travel in Git, use an
explicitly authorized repo-native bridge.

Use this when:

- work often happens outside `<hub-root>`
- cloud or remote Codex tasks need the guidance
- reviewers need the same docs inside the repo
- absolute local paths are not reliable

### Level 3: Repo-Native Policy

Promote the most important rules directly into the repo `AGENTS.md` when they
must be mandatory for everyone working in that repo. This is the strongest
option and should be used for security-critical rules, required checks, and
repo-specific architecture constraints.

## Bridge Contract

The bridge must preserve these boundaries:

- Hub docs guide workflow, design, security posture, and evidence.
- Repo `AGENTS.md` controls code layout, commands, tests, and local conventions.
- If a hub doc and repo doc conflict, follow the repo doc for implementation
  mechanics and the stricter rule for security.
- Code edits happen inside the actual repo project, not from the hub.
- `remote-validation` is for inspection, rebuilds, and validation, not unreviewed source
  of truth.

## Target Repos

Initial bridge candidates:

- `development/backend`
- `development/frontend`
- `charts`
- `patching/image-collection`
- `environments/restricted-runtime`

Future bridge candidates can be added under `patching/` as repos are migrated
into the hub.

## Bridge Snippet

Use `docs/templates/repo-bridge.md` as the source snippet. Apply
it intentionally to a repo only after checking that repo's current `AGENTS.md`
and any `AGENTS.override.md` files.

If a local `AGENTS.override.md` exists in the same directory as `AGENTS.md`, the
override can supersede the tracked file during Codex instruction discovery. In
that case, add the bridge to the override too and include a startup requirement
to read `./AGENTS.md` completely before implementation, review, or PR-ready
claims.

## Validation

After adding a bridge to a repo, start a new Codex thread in that repo and ask
it to summarize loaded instructions and the hub references. Confirm it sees the
repo rules first and the hub bridge second.
