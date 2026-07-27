# Review method

## Review target

Prefer an explicit base and candidate SHA. When reviewing a working tree,
include staged, unstaged, and relevant untracked files without altering them.
When reviewing a plan or architecture, treat requirements, ownership,
interfaces, failure states, validation, rollout, and rollback as the candidate
surface.

If the target is ambiguous and different interpretations would change the
findings, ask one focused question before reviewing.

## Finding threshold

Report a finding when the candidate introduces a concrete correctness,
security, reliability, compatibility, operability, maintainability, or test
gap that the author should act on.

Use severity consistently:

- P0: immediate catastrophic or broadly exploitable impact;
- P1: serious breakage, security exposure, data loss, or release blocker;
- P2: meaningful defect or regression under realistic conditions;
- P3: bounded issue worth fixing that is not merely stylistic.

Avoid speculative findings, style preferences, and restating successful
behavior. Tie every finding to evidence and explain the triggering condition.

## Review layers

Cover the layers affected by the change:

- intent and ownership;
- behavior and failure paths;
- trust, identity, authorization, secrets, and data exposure;
- API, schema, migration, image, manifest, and runtime compatibility;
- concurrency, retries, idempotency, and rollback;
- tests, static checks, renders, scans, or runtime evidence;
- documentation and operator impact where behavior changes.

Use specialized security review when the user requests a security audit or the
candidate crosses a material trust boundary.

## Cross-repository review

Review each repository in its owning project. The Hub coordinates targets and
contract edges but does not inspect owner code. Reconcile producer and consumer
contracts only after the user explicitly asks to consolidate completed owner
reviews.

## Output

Return findings first, ordered by severity. For each finding include:

- severity and concise title;
- path and tight line range when available;
- observed behavior and triggering condition;
- user, security, or operational impact;
- focused fix direction.

Then list open questions, checks run, checks skipped, and residual risk. If
there are no findings, say that directly without claiming unrun validation or
unreviewed surfaces are safe.
