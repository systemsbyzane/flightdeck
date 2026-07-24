# Automation operating model

Use real Codex automations for schedules. Files under `hub/automations/` are
disabled, reviewable specifications; they are not evidence that a job is
installed or active.

## Output contract

Every recurring job must:

- state source and freshness;
- derive a stable finding key from category and scope;
- compare against prior job state;
- classify each item as new, resolved, persistent, or blocked;
- treat nonzero diagnostic status as a finding rather than automatically
  treating the automation as failed;
- provide a prioritized read-only action queue.

## Authority

Jobs are read-only by default. They may inspect local files, source-control
metadata, and explicitly authorized sources. They may create an inbox report or
propose an owning-project handoff. They may not clone, edit, build, commit,
push, create or comment on pull requests, rerun workflows, mutate environments,
publish artifacts, submit compliance material, accept risk, or close POA&M
items without separate explicit authority.

Credentials come from configured runtime capabilities and are never stored in
Hub YAML. Create or update a live schedule only when the user explicitly asks,
then read it back and report the verified live state.

## Recommended jobs

- daily workspace Doctor and action queue;
- weekday repository and CI monitor;
- weekly evidence-backed vulnerability triage;
- weekly stale-claim research refresh;
- monthly compliance evidence and sidecar review;
- monthly project, registry, bridge, skill, task-link, and automation governance.

Combine overlapping jobs when separate schedules would repeat the same finding.
