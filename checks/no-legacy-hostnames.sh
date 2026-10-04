#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-$script_dir/..}"

legacy='(observability-pi|services-pi|framework-01|framework-02|framework-03)'
failed=0

scan_files() {
  local label=$1
  shift
  local matches
  matches=$(grep -nHE "$legacy" "$@" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    printf 'Legacy fleet identities in %s:\n%s\n' "$label" "$matches" >&2
    failed=1
  fi
}

mapfile -t executable_files < <(
  find . \
    -path './.git' -prune -o \
    -path './.jj' -prune -o \
    -path './.amp' -prune -o \
    -path './.superpowers' -prune -o \
    -type f -name '*.nix' -print
)
scan_files 'executable Nix files' "${executable_files[@]}"

mapfile -t shell_files < <(
  find . \
    -path './.git' -prune -o \
    -path './.jj' -prune -o \
    -path './.amp' -prune -o \
    -path './.superpowers' -prune -o \
    -type f -name '*.sh' ! -path './checks/no-legacy-hostnames.sh' -print
)
if (( ${#shell_files[@]} )); then
  scan_files 'executable shell files' "${shell_files[@]}"
fi

mapfile -t policy_files < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print)
scan_files 'workflow and policy YAML' "${policy_files[@]}"

scan_files 'current inventory' \
  docs/inventory/services.md \
  docs/inventory/hosts.md \
  docs/inventory/nfs-mappings.md

while IFS= read -r runbook; do
  matches=$(awk '
    /^```/ { in_command = !in_command; next }
    in_command { print FNR ":" $0 }
  ' "$runbook" | grep -E "$legacy" || true)
  if [[ -n "$matches" ]]; then
    printf 'Legacy fleet identities in active commands (%s):\n%s\n' "$runbook" "$matches" >&2
    failed=1
  fi
done < <(find docs/runbooks -type f -name '*.md' -print)

mapfile -t legacy_paths < <(find docs/runbooks -type f | grep -E "$legacy" || true)
if (( ${#legacy_paths[@]} )); then
  printf 'Legacy fleet identities in active runbook paths:\n%s\n' "${legacy_paths[*]}" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi

echo 'No legacy fleet identities found in operational surfaces.'
