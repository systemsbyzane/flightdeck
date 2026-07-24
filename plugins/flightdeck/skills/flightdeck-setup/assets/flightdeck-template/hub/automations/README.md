# Automation specifications

These files are disabled specifications, not active schedules. Only a
successfully created and read-back Codex automation proves that a real job
exists. Activation requires a separate explicit user action and confirmation of
scope, schedule, timezone, access, handling, and output destination.

Automation defaults are read-only. Findings propose owning tasks; they do not
authorize edits, commits, pushes, pull requests, deployments, external
communication, compliance submission, risk acceptance, or closure.

Every job records source freshness, uses a stable finding key, and classifies
findings as new, resolved, persistent, or blocked. A nonzero diagnostic result
is a finding unless the job itself cannot complete. Read
`docs/workflows/automations.md` before translating a specification into a real
schedule.
