# Planning work

Ask for a plan in natural language. Flightdeck chooses the least detail that
still makes the work executable; users do not need to name a skill or select a
planning mode.

## Planning-only boundary

A planning-only request is read-only. It does not edit files, create or resume
tasks, or begin implementation. In the Hub, planning uses the registry, route
plan, bridge metadata, and saved-project state without inspecting owning
repository code.

If credible detail requires code-level analysis, name the owning project and
the missing evidence. Dispatch a read-only owner task only when the user also
asks Flightdeck to have that owner investigate or proceed. Return its receipt
without monitoring.

## Right-sized output

- Small work: outcome, short ordered plan, and validation.
- Normal work: add non-goals, owner, dependencies, risk, and approvals.
- Cross-repository or high-risk work: add contract order, migration or rollout,
  rollback, and unresolved decisions.

Do not invent files, commands, owners, branches, or external facts. Mark
unknowns and identify the evidence needed to resolve them. Planning never
authorizes commit, publication, deployment, shared-environment mutation,
external communication, compliance submission, risk acceptance, or closure.
