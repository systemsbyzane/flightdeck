# Setup contract

The generated Hub is a coordination workspace, not a source monorepo.

- Keep stable topology in `flightdeck.yaml`.
- Keep generated task, report, bridge, parity, and provider state ignored.
- Keep real program evidence and outputs outside tracked control-plane content.
- Use synthetic fixtures only in tests.
- Configure providers without credentials: GitHub, GitLab, Bitbucket, generic
  Git, existing local checkouts, and remote validation contexts.
- Resolve and record repository ownership and the verified default branch
  before cloning. Hosted provider hosts may be configured; generic Git requires
  an explicit owner and canonical URL.
- Automations remain disabled until explicit enablement.
- Register each owning repository or program folder as a separate Codex project.
- Keep its stable logical project key separate from Codex's opaque runtime
  project ID.
- Validate saved project registration by exact normalized real path against a
  refreshed live project list, reject display-name-only matches, and record the
  opaque runtime ID only after that match.

The generated workspace must pass Ruby tests, control-plane YAML/JSON parsing,
Doctor, and the de-branding scanner before use. Control-plane parsing and
de-branding exclude configured workload repositories, program payloads, and
ignored local runtime state. Doctor remains responsible for repository state,
bridges, tasks, handoffs, and compliance artifact integrity.

The repo-managed bootstrap is preview-first and credential-free. It may
generate an absent or empty target or validate a recognized generated Hub as a
no-op. Stable topology in `flightdeck.yaml` and repository declarations in
`hub/repositories.yaml` are configuration surfaces and may differ from the
template when they remain valid. Other generated managed files must remain
recognizable; partial, unmanaged, path-mismatched, or drifting non-empty targets
are rejected. Bootstrap has no force, merge, repair, or in-place upgrade mode.
Plugin installation, project registration, and runtime capability verification
remain separate explicit actions.
