# Change review

Ask for a review in natural language. Flightdeck infers the required depth from
the exact target, trust boundaries, compatibility risk, and blast radius.

## Ownership and target

Review code, configuration, manifests, artifacts, and repository evidence in
the owning project. Review Hub-owned coordination plans or workflows in place.
For a repository-owned target, resolve the owner and dispatch the review before
inspecting owner code, then return the receipt without monitoring.

Record the exact pull request, base and candidate SHA, branch comparison,
working tree, plan, or architecture under review. Do not silently substitute a
different target.

## Findings-first result

Lead with actionable findings ordered by severity. Each finding names:

- the impact and triggering condition;
- the evidence, including a path and tight line range when available;
- a focused fix direction.

Then state open questions, checks run, checks skipped, and residual risk. If
there are no actionable findings, say so plainly without treating unrun checks
or unreviewed surfaces as proof of readiness.

Review is read-only by default. Fixes, pull-request comments, external review
requests, approval, merge, publication, deployment, and closure are separate
actions with their own authorization and evidence gates.
