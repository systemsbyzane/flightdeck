# Image patch compatibility

Capture before and after values for:

- base image family, package manager, architecture, and crypto requirements
- runtime family and major version
- entrypoint, command, arguments, signals, ports, and health endpoints
- UID/GID, permissions, working directory, writable paths, and volumes
- environment variables, configuration paths, trust stores, locale, and time
- installed binaries, libraries, plugins, and operational tools
- consuming chart security context and image metadata

Do not claim remediation from a source diff or scan alone. Require a rebuilt
candidate and identify it by digest. Compare vulnerability results and runtime
contracts, then trace every downstream tag or digest consumer.

