# Image Patching Compatibility

Use this guide when patching container images used by application, data,
analytics, machine-learning, or shared platform workloads.

## Core Rule

Patch images to reduce vulnerability and supply-chain risk without breaking
runtime contracts that downstream products depend on.

Security fixes are not a license to make accidental product changes. Treat each
image patch as a compatibility-sensitive change.

## Compatibility Contracts

Before changing an image, identify and preserve:

- image name, tag strategy, and chart/product reference path
- base image family, OS package manager, FIPS expectations, and architecture
- entrypoint, command, args, and process signal behavior
- exposed ports, protocols, health endpoints, and readiness behavior
- user ID, group ID, filesystem permissions, and writable paths
- environment variables, config file paths, mounted volumes, and expected
  working directory
- installed binaries, library paths, Python/Node/Java/Go runtime versions, and
  plugin directories
- TLS, CA bundle, trust store, time zone, locale, and crypto behavior
- Kubernetes security context assumptions in the consuming chart
- startup time, migration behavior, and backward compatibility with existing
  PVCs or generated state

## Patching Rules

- Prefer minimal patch-level upgrades that address the vulnerability without
  changing application behavior.
- Do not change major versions, base image family, runtime version, UID/GID,
  entrypoint, ports, or config paths unless the breaking impact is intentional,
  documented, and coordinated with downstream products.
- Do not remove binaries, packages, certificates, plugins, or shell tools that
  the workload, probes, lifecycle hooks, or operational runbooks may use.
- Do not switch images from root to non-root, change writable paths, or enable a
  read-only root filesystem without validating the consuming chart and runtime.
- Keep image metadata in the owning layer: Dockerfile and base-image selection
  in the source/image repo; chart image references under
  `dependencies.containerImages` in `the owning charts repository`; product version pins in
  product repos.
- When a patch requires a breaking change, stop and create a coordinated rollout
  plan across image, chart, product, and customer or program repos.

## Validation Evidence

For each patched image, capture:

- original image and patched image reference
- vulnerability or CVE source and expected remediation
- Dockerfile or build diff
- image scan result before and after
- chart values or product pins that consume the image
- smoke test or workload startup evidence
- rendered manifest or deployed pod evidence when chart behavior is affected
- known compatibility risks and skipped checks

## PR-Ready Standard

An image patch is not ready when it only proves the CVE count changed. It is
ready when the vulnerability reduction is shown and downstream runtime contracts
are preserved or intentionally changed with a documented rollout plan.
