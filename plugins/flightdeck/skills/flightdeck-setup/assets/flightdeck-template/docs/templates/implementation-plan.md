# Implementation Plan Template

Use this after the design is clear and before editing the owning repo.

## Goal

One sentence describing what the change builds or fixes.

## Repo And Starting Point

- Repo:
- Branch:
- Codex mode: Local or Worktree
- Related remote or cluster thread:

## Files

List files to create, modify, or inspect. Keep ownership clear.

## Plan

1. Read the repo `AGENTS.md` and any nested instruction files.
2. Confirm the current behavior with code, tests, artifacts, or cluster output.
3. Add or update the smallest focused tests that describe the expected behavior.
4. Implement the smallest coherent change.
5. Run targeted checks.
6. Run broader repo checks required by the repo `AGENTS.md`.
7. Run security preflight.
8. Capture validation evidence.
9. Prepare PR notes with risks, checks, and any follow-up work.

## Security Notes

State the affected trust boundaries and required controls.

## Validation Commands

Include exact commands and expected successful outcomes.

## Rollback

Describe how to revert, disable, or back out the change.

