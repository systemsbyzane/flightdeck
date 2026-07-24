# Weekly Image Patch Review

## Outcome

Turn the portfolio vulnerability scan into a reviewable patch queue, then
route only user-approved candidates into owning-repository implementation and
draft pull requests.

## Authoritative Sources

The portfolio source is `the owning charts repository` GitHub Actions workflow
`Security - Trivy Container Scan`. The committed schedule starts Mondays at
08:00 UTC, but GitHub may delay the actual start. The Codex review automation
runs Mondays at 11:00 America/Chicago and uses the newest completed successful
run from the prior eight days.

Select the newest non-expired artifact by creation time for:

- `trivy-summary-report-image-collection`
- `trivy-summary-report-application`
- `poam-csv-report-image-collection`
- `poam-csv-report-application`

Treat `summary-report.json` as the source of truth for scanned-image coverage,
severity totals, and image ranking. It does not include package fix versions.
Use the POA&M CSV `Fixed Version` column for fixability ranking and consolidated
SARIF for deeper finding-level validation. Never infer fixability from fields
that are not present in the summary payload.

The portfolio scan currently supplies Trivy data. Grype runs in relevant
repository pull-request workflows, including `image-collection` `Trivy (Monorepo)`.
The review must not claim weekly Grype portfolio coverage. Approved patch PRs
should use both scanners when their owning workflow provides them.

## Scheduled Review

The automation is read-only. It may inspect GitHub runs/artifacts, local repo
metadata, Dockerfiles, `dockerfile.targets`, charts, and prior automation
memory. It may not clone, edit, build, rerun workflows, commit, push, comment,
open a PR, deploy, or accept risk.

Rank fixable Critical, then fixable High, then fixable Medium findings. Keep
no-fix findings separate. Deduplicate by image identity, package,
vulnerability, installed version, and fixed version.

Each candidate must contain:

- numbered candidate ID and recommendation
- exact image and digest when available
- package, CVE, installed version, and fixed version
- likely owning repository and Dockerfile target with confidence
- chart/product/program consumers
- patch class and compatibility risk
- required build, SBOM, rescan, test, and runtime validation
- new, changed, persistent, or resolved state relative to the prior review

## Approval And Implementation

The user selects candidates in Flightdeck. A request such as
`Approve candidates 1 and 3 for implementation and draft PRs after validation`
authorizes local clone/worktree/edit/build/test/scan activity for those
candidates and authorizes draft PR creation after validation. The Hub still
reports exact repos, branches, checks, residual findings, and downstream impact
before publication.

The Hub automatically resolves each approved candidate to its owning repo,
searches for a matching project task, and creates a Worktree task when none
exists. If the repo is not cloned, the Hub verifies ownership, clones it under
`patching/`, registers the repo and saved project, installs the bridge, and then
launches the task. Saved-project verification requires an exact normalized
real-path match in a refreshed live list. The Hub keeps its logical project key
separate, captures the opaque runtime project ID from that match, and uses the
runtime ID for task search and launch.

After launching approved implementation tasks, return their IDs immediately.
Do not poll, wait for builds, or read task progress from the approval thread.
The user monitors the project tasks and can return to the Hub for later
consolidation or follow-up.

Only after automatic project registration or cross-project task creation fails
after a live-state refresh and one retry, use the fallback handoff:

1. Generate one self-contained handoff per owning repo.
2. Tell the user the exact saved project and Local/Worktree mode.
3. After the user starts it, discover or read it only when the user explicitly
   asks the Hub to resume.
4. Consolidate source, chart, and runtime evidence only on that later request.

