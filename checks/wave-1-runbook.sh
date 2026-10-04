#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path required}
runbook="$repo/docs/runbooks/wave-1-hl-node-00.md"
acceptance=$(sed -n '/^## 6\. Acceptance/,/^## 7\. Rollback/p' "$runbook")

grep -Fq '! findmnt -M /var/lib/telemetry' <<<"$acceptance"
grep -Fq 'systemctl is-active opentelemetry-collector comin cloudflared' <<<"$acceptance"
grep -Fq 'for backend in prometheus loki tempo grafana; do ! systemctl is-active --quiet "$backend"; done' <<<"$acceptance"

mapfile -t ssh_commands < <(grep '^ssh ' <<<"$acceptance")
test "${#ssh_commands[@]}" -ge 2
for command in "${ssh_commands[@]}"; do
  grep -Fq -- '-o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes' <<<"$command"
done
