#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path required}
runbook="$repo/docs/runbooks/wave-1-hl-node-00.md"
acceptance=$(sed -n '/^## 6\. Acceptance/,/^## 7\. Rollback/p' "$runbook")

! grep -Fq '! findmnt -M /var/lib/telemetry' <<<"$acceptance"
grep -Fq 'findmnt -nro FSTYPE -M /var/lib/telemetry' <<<"$acceptance"
grep -Fq 'findmnt -nro OPTIONS -M /var/lib/telemetry' <<<"$acceptance"
grep -Fq 'prjquota' <<<"$acceptance"
grep -Fq 'readlink /run/booted-system' <<<"$acceptance"
grep -Fq 'systemctl is-active prometheus loki tempo grafana otel-gateway opentelemetry-collector comin cloudflared-fleet tailscaled fleet-backup-grafana-state.timer fleet-backup-check.timer' <<<"$acceptance"
grep -Fq 'fleet-restore grafana-state --rehearsal' <<<"$acceptance"

mapfile -t ssh_commands < <(grep '^ssh ' <<<"$acceptance")
test "${#ssh_commands[@]}" -ge 2
for command in "${ssh_commands[@]}"; do
  grep -Fq -- '-o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes' <<<"$command"
done
printf '%s\n' "${ssh_commands[@]}" | bash -n
