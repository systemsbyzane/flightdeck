# Automations

Use real Codex UI automations for schedules. Keep repository YAML files as
reviewable specifications, not claims that a job is active.

## Output Contract

Every recurring job must state its source and freshness, produce stable finding
keys when possible, compare with prior automation memory, and classify findings
as new, resolved, persistent, or blocked. A nonzero diagnostic exit is a
finding, not automatically an automation failure.

Scheduled jobs are read-only by default. They may inspect local files, source
control, and explicitly authorized sources, and may produce inbox reports or
proposed handoffs. They may not edit repos, clone, build, commit, push, open
pull requests, comment, rerun workflows, mutate environments, submit compliance
artifacts, close POA&M items, or accept risk.

## Authority And State

- The prompt and current user authorization define the read boundary.
- Credentials are supplied by runtime capabilities; never place them in YAML.
- Repository YAML never proves a Codex automation is installed, enabled, or
  scheduled.
- Create or update a real schedule only when the user explicitly asks.
- Read back the live automation after a write and distinguish accepted schedule
  state from a local specification.
- Report blocked sources without converting them into successful checks.

## Recommended Jobs

- Daily Doctor: local repository, workflow, task, handoff, bridge, and
  compliance integrity with deltas and priorities.
- Weekday repository and CI monitor: failing checks, unresolved reviews, stale
  drafts, and proposed fix tasks.
- Weekly vulnerability triage after an authoritative portfolio scan:
  evidence-backed fixability and an approval-gated patch queue.
- Weekly research refresh: only stale material claims with refresh dates.
- Monthly compliance evidence review: metadata, sidecar integrity, and evidence
  freshness for authorized program workspaces.
- Monthly Hub governance: registry, saved-project, bridge, skill, automation,
  and task-link drift.

Avoid separate jobs that repeat the same findings. Prefer one morning Hub brief
when Doctor, repository status, and task state would otherwise create noise.
