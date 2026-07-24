#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s REMOTE_HOST REMOTE_ROOT [REMOTE_REPO ...]\n' "$(basename "$0")" >&2
  printf 'REMOTE_REPO values are safe relative directory names. Set VALIDATION_NAMESPACE only for bounded cluster reads.\n' >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
remote_host=$1
remote_root=$2
shift 2

[[ "$remote_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'unsafe remote host alias\n' >&2
  exit 2
}
[[ "$remote_root" =~ ^/[A-Za-z0-9._/-]+$ && "$remote_root" != *"/../"* ]] || {
  printf 'remote root must be a safe absolute path\n' >&2
  exit 2
}
for repository in "$@"; do
  [[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'unsafe remote repository directory: %s\n' "$repository" >&2
    exit 2
  }
done

namespace=${VALIDATION_NAMESPACE:-}
[[ -z "$namespace" || "$namespace" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
  printf 'unsafe validation namespace\n' >&2
  exit 2
}

printf 'Read-only remote validation preflight\n'
printf 'host: %s\nroot: %s\n' "$remote_host" "$remote_root"

ssh -- "$remote_host" bash -s -- "$remote_root" "$namespace" "$@" <<'REMOTE_SCRIPT'
set -euo pipefail
remote_root=$1
namespace=$2
shift 2

printf 'host: %s\nuser: %s\ncwd: %s\n' "$(hostname)" "$(whoami)" "$(pwd)"
for repository in "$@"; do
  path="$remote_root/$repository"
  printf '\n== repository %s ==\n' "$repository"
  if [[ ! -d "$path/.git" ]]; then
    printf 'missing git repository: %s\n' "$path"
    continue
  fi
  git -C "$path" status --short --branch
  printf 'sha: '
  git -C "$path" rev-parse HEAD
  printf 'origin: '
  git -C "$path" remote get-url origin 2>/dev/null || printf 'none\n'
  printf 'upstream: '
  git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || printf 'none\n'
done

printf '\n== tools ==\n'
printf 'container runtime: '
docker info --format '{{.ServerVersion}}' 2>/dev/null || printf 'unavailable\n'
printf 'local clusters: '
kind get clusters 2>/dev/null | tr '\n' ' ' || true
printf '\ncurrent context: '
kubectl config current-context 2>/dev/null || printf 'unavailable\n'

if [[ -n "$namespace" ]]; then
  printf '\n== namespace %s ==\n' "$namespace"
  kubectl get namespace "$namespace" -o name 2>/dev/null || printf 'namespace unavailable\n'
  kubectl get deployment,statefulset,pod -n "$namespace" -o wide 2>/dev/null || true
  helm list -n "$namespace" 2>/dev/null || true
fi
REMOTE_SCRIPT

cat <<EOF

This preflight performed inspection only. Register the exact remote project
paths and verify them in the live Codex project list before dispatch. Any build,
image load, rollout, deployment, or shared-environment mutation requires
separate explicit authorization.
EOF
