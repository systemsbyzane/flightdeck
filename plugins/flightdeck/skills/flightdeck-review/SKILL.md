---
name: flightdeck-review
description: Review changes and readiness through Flightdeck with findings-first, evidence-backed output. Use when a user asks to review a pull request, diff, branch, commit, working tree, architecture or implementation plan, release readiness, or a cross-repository change for correctness, security, regressions, compatibility, and missing validation. Natural review intent should trigger this skill; explicit invocation is optional.
---

# Flightdeck Review

Review the exact candidate surface and lead with actionable findings. Review is
read-only by default; do not fix findings unless the user separately asks.

## Resolve the review target

1. Identify the artifact or Git comparison being reviewed and the question the
   review must answer. Do not silently substitute a different base, branch,
   commit, pull request, or working-tree diff.
2. In a generated Hub, read `AGENTS.md` and
   `docs/review/change-review.md`. Review Hub-owned coordination material in
   place. For a repository-owned target, resolve every owner and dispatch the
   review before inspecting owner code, then return the receipt without
   monitoring.
3. In an owning repository, read applicable instructions, record branch, SHA,
   dirty state, and the exact review target, then inspect the candidate diff and
   enough surrounding code or tests to validate behavior.
4. Use the applicable specialized skill for security, charts, patching,
   compliance, artifacts, CI/CD, or platform evidence without weakening this
   review contract.

## Adapt the review

Infer review depth from change size, trust boundaries, compatibility, and
blast radius. A focused diff can stay compact. Large, cross-repository,
security-sensitive, migration, deployment, or release work requires deeper
contract and validation review. Do not ask the user to choose a review mode
unless two materially different targets remain ambiguous.

Use `references/review-method.md` for severity, evidence, readiness, and
cross-repository guidance.

## Report

Lead with findings ordered by severity. Each finding must name the impact,
evidence with a path and tight line range when available, and a concrete fix
direction. Then state open questions, skipped checks, and residual risk.

If no actionable findings remain, say so plainly and still report validation
gaps or unreviewed surfaces. Do not edit, comment on a pull request, request an
external review, approve, merge, deploy, or claim readiness without the
required evidence and authorization.
