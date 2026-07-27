# Delivery method

## Establish the evidence chain

Record:

- repository and provider;
- candidate branch and SHA;
- pipeline, run, job, and first causal step;
- workflow definition and reusable dependencies at that SHA;
- runner or execution environment;
- produced artifacts, digests, attestations, and retention where relevant;
- target environment and promotion state.

Separate observed provider facts from repository evidence and inference.
Redact credentials and secret values from logs and reports.

## Diagnose

Start with the first failed or unexpectedly skipped dependency. Distinguish:

- product or test failure;
- workflow syntax or expression error;
- permissions, identity, or secret availability;
- runner, capacity, network, or external service failure;
- cache or artifact mismatch;
- flaky or timing-sensitive behavior;
- policy, environment protection, or approval block.

Confirm the failure is reproducible or explain why current evidence is
insufficient. Do not rerun merely to hide a causal signal.

## Change and validate

Keep the fix in the surface that owns the behavior. Reuse repository commands
and validation policy. Where relevant:

- lint or parse workflow configuration;
- test scripts outside provider YAML;
- minimize token and job permissions;
- keep secrets out of untrusted execution paths and output;
- validate cache keys, restore behavior, and invalidation;
- make matrix, retry, timeout, and concurrency behavior explicit;
- pin external workflow dependencies according to repository policy;
- verify artifact integrity and producer-consumer compatibility;
- preserve environment approvals and rollback paths.

Record skipped provider-only checks and the evidence still required after a
source change.

## Cross-repository delivery

Assign each source change to its owner. Sequence artifact producers before
consumers, version or digest updates, deployment configuration, promotion, and
runtime validation. Do not treat one green repository pipeline as proof that
the integrated release is safe.

## External actions

Rerun, cancel, manually dispatch a workflow, approve, publish, promote, deploy,
change provider settings, and communicate externally are separate actions.
Perform only the actions the user explicitly authorized and verify the
resulting provider state.
