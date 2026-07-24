#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s TASK_SLUG TITLE OUTCOME REPOSITORY_ID [REPOSITORY_ID ...]\n' "$(basename "$0")" >&2
  exit 2
}

[[ $# -ge 4 ]] || usage
task_slug=$1
title=$2
outcome=$3
shift 3

[[ "$task_slug" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || {
  printf 'task slug must use lowercase letters, numbers, and hyphens\n' >&2
  exit 2
}
for repository_id in "$@"; do
  [[ "$repository_id" =~ ^[a-z0-9]+([a-z0-9._-]*[a-z0-9])?$ ]] || {
    printf 'unsafe repository ID: %s\n' "$repository_id" >&2
    exit 2
  }
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hub_root=$(cd "$script_dir/.." && pwd)
out_dir="$hub_root/handoffs/development/$task_slug"
[[ ! -e "$out_dir" ]] || {
  printf 'refusing to overwrite existing handoff: %s\n' "$out_dir" >&2
  exit 1
}
mkdir -p "$out_dir"

"$hub_root/bin/flightdeck" task new development "$task_slug" \
  --title "$title" --outcome "$outcome" --workload development

{
  printf '# Multi-repository coordinator: %s\n\n' "$title"
  printf -- '- Task: `%s`\n' "$task_slug"
  printf -- '- Outcome: %s\n' "$outcome"
  printf -- '- Workflow: `docs/workflows/multirepo-coordination.md`\n'
  printf -- '- Template: `docs/templates/multirepo-feature-handoff.md`\n\n'
  printf '## Dispatch contract\n\n'
  printf 'Search recent tasks in every resolved owning project. Resume a matching objective or create one in the planned mode. Return all project/task IDs and modes immediately, then stop without polling, waiting, reading, or monitoring.\n\n'
  printf '## Owning repositories\n\n'
  for repository_id in "$@"; do
    printf -- '- `%s`: prompt `%s.md`, route `%s.route.json`\n' "$repository_id" "$repository_id" "$repository_id"
  done
} >"$out_dir/coordinator.md"

for repository_id in "$@"; do
  "$hub_root/bin/flightdeck" route plan \
    --workload development \
    --work-type implementation \
    --repo-id "$repository_id" \
    --json >"$out_dir/$repository_id.route.json"

  cat >"$out_dir/$repository_id.md" <<EOF
# Owning repository task: $title

Repository ID: \`$repository_id\`
Outcome: $outcome

Before analysis or implementation:

1. Read every applicable repository \`AGENTS.md\`.
2. Read the installed Flightdeck bridge.
3. Read the bridge's required Hub documents.
4. Confirm branch, SHA, dirty state, and the repository-owned portion of the work.
5. Apply repository rules for layout, commands, tests, and generated files; the stricter security or authorization rule wins.

Keep implementation in this repository. Return changed files, exact checks,
skipped checks with impact, evidence, cross-repository contract notes, residual
risk, and approval state.

Do not commit, push, create or update a pull request, publish, deploy, mutate a
shared environment, communicate externally, submit compliance material, accept
risk, or claim closure without the applicable explicit authorization.
EOF
done

cat >"$out_dir/status.md" <<EOF
# Multi-repository status: $title

Fill this only after the user explicitly asks the Hub to consolidate completed
owning-project tasks. Do not monitor from the dispatch turn.

| Repository | Logical key | Runtime project ID | Task ID | Mode | Branch/SHA | Checks | Risks |
| --- | --- | --- | --- | --- | --- | --- | --- |
EOF

printf 'Created non-destructive handoff packet: %s\n' "$out_dir"
printf 'Dispatch from: %s\n' "$out_dir/coordinator.md"
