# Contributing

Changes must preserve portable behavior and evidence. Start by reading
`AGENTS.md`.

The plugin source is `plugins/flightdeck/`. The generated workspace is an asset
of `flightdeck-setup`; changes to its CLI, schemas, workflows, docs, bridges, or
tests must be validated both in place and after fresh generation.

For a behavioral change:

1. identify the mandatory functional surface and neutral source mapping;
2. update `plugins/flightdeck/process-parity.json` when an inventory surface
   changes;
3. update the implementation, machine-readable contract, and focused tests;
4. add or strengthen a functional parity probe;
5. run `make release-validate SOURCE_HUB=/absolute/read-only/reference` so the
   complete local suite includes strict source inventory and semantic parity;
6. run de-branding over hidden and visible distributable files;
7. leave runtime-only UI acceptance explicitly unverified until an installed
   fresh task executes it.

Do not contribute credentials, private URLs, live topology, real evidence,
program artifacts, task history, or generated findings. Do not add a license
unless the owner later changes the current private-distribution decision.
