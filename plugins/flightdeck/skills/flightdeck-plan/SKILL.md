---
name: flightdeck-plan
description: Create right-sized, evidence-led plans for work coordinated through Flightdeck. Use when a user asks to plan, scope, design, sequence, break down, or choose an approach for implementation, migration, release, CI/CD, platform, security, compliance, or cross-repository work before changes begin. Natural planning intent should trigger this skill; explicit invocation is optional.
---

# Flightdeck Plan

Turn an outcome into the smallest useful executable plan without forcing every
request through one template. Planning is read-only by default.

## Establish the planning surface

1. Determine whether the task is in a generated Flightdeck Hub or an owning
   repository.
2. In a Hub, read its `AGENTS.md`, registry, and
   `docs/workflows/planning.md`. Use Hub topology and `route plan` for ownership
   and sequencing; do not inspect owning-repository code before dispatch.
3. In an owning repository, read every applicable instruction file before
   inspecting code, tests, history, or configuration.
4. State assumptions only when they affect scope, ownership, risk, or
   validation. Ask one focused question only when a missing decision would
   materially change the plan.

## Keep planning separate from execution

A planning-only request does not edit files, create or resume tasks, run
state-changing commands, or imply authorization to implement. Read-only
inspection is allowed within the current owning project.

In a Hub, produce a coordination-level plan from Hub evidence. If a credible
code-level plan requires owner analysis, identify that need. Dispatch only when
the user also asks Flightdeck to have the owner investigate or proceed; then
follow `$flightdeck` and return the receipt without monitoring.

## Adapt the depth

Infer depth from scope and risk; do not make the user select a mode.

- For a small, well-understood change, give the outcome, a short ordered plan,
  and validation.
- For normal work, add non-goals, owner, dependencies, risk, and approval
  boundaries.
- For cross-repository or high-risk work, add contracts, sequence, migration or
  rollout, rollback, and unresolved decisions.

Do not invent owners, files, commands, branch state, or external facts. Mark
unknowns and name the evidence needed to resolve them. Use
`references/planning-method.md` when the request needs more than a compact plan.

## Handoff

End with the plan, validation criteria, and any decision that blocks execution.
Do not begin implementation unless the user separately asks to proceed.
