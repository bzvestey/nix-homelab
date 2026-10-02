# Wave 1: observability Pi

This runbook installs `observability-pi` at `10.15.4.6`. Record evidence in
the fields at the end without copying credentials, private keys, or decrypted
secret values. Stop at any failed guard; a device path alone is never an
identity.

## 1. Controller and build preflight

Use the reviewed `main` revision and a native AArch64 Linux builder. Emulation
is not acceptance evidence.

The `images` GitHub Actions workflow also builds this image on a native
`ubuntu-24.04-arm` runner. For a successful `main` run, download the
revision-specific `observability-pi-<git-commit>` artifact. It contains only
the compressed image, `observability-pi.sha256`, and
`observability-pi.manifest`; the manifest binds the image to the Git commit and
Nix output/store path. Artifacts expire after seven days. Verify the workflow
commit equals the reviewed revision, the manifest commit matches it, and run
`sha256sum -c observability-pi.sha256` before proceeding. A failed build posts
a bounded Nix error tail to the public job summary; never use a failed or
missing artifact.

```sh
set -eu
test "$(uname -m)" = aarch64
test -z "$(jj --no-pager status | sed -n '/Working copy changes:/,$p')"
revision=$(jj log -r main -T 'commit_id' --no-graph)
test -n "$revision"
nix build ".#images.observability-pi"
nix build ".#nixosConfigurations.observability-pi.config.system.build.toplevel"
image=$(find -L result/sd-image -maxdepth 1 -type f -name 'observability-pi-bootstrap.img.zst' -print -quit)
test -n "$image" && test -f "$image"
sha256sum "$image" | tee observability-pi-bootstrap.img.zst.sha256
nix path-info -S ".#images.observability-pi" ".#nixosConfigurations.observability-pi.config.system.build.toplevel"
```

Inspect both closures before transfer. Replace `SECRET_SENTINEL` only with a
non-secret test marker that is known to be absent; never put a real secret in
an argument, environment variable, store path, or log.

```sh
set -eu
for output in \
  "$(nix path-info .#images.observability-pi)" \
  "$(nix path-info .#nixosConfigurations.observability-pi.config.system.build.toplevel)"
do
  nix-store -qR "$output"
done | sort -u > /tmp/observability-pi-closure
! grep -RIl --binary-files=without-match 'SECRET_SENTINEL' $(cat /tmp/observability-pi-closure)
! find -L $(cat /tmp/observability-pi-closure) -type f \
  \( -name 'ssh_host_*_key' -o -name '*.agekey' -o -name 'id_ed25519' \) -print -quit | grep -q .
```

Transfer the image and checksum over an authenticated channel. On the flashing
controller, require `sha256sum -c observability-pi-bootstrap.img.zst.sha256`.

## 2. Guarded boot-media flash

The owner confirms `/dev/sdb` is intentionally the Pi boot MicroSD, not a
telemetry SSD. Its currently observed identity is: model
`MicroSD(2nd Gen)`, serial `FRACCVBZ91544401B2`, exactly `128177930240`
bytes. Do not write it until the native artifact and hash have been verified.
Immediately before writing, run this whole block as root. It refuses identity
drift, mounted children, the system disk, non-removable media, and an
unverified image hash.

```sh
set -eu
test "$(id -u)" -eq 0
device=/dev/sdb
image=./observability-pi-bootstrap.img.zst
checksum=./observability-pi-bootstrap.img.zst.sha256
test -b "$device"
test "$(lsblk -bdno SIZE "$device")" = 128177930240
test "$(lsblk -dno MODEL "$device" | xargs)" = 'MicroSD(2nd Gen)'
test "$(lsblk -dno SERIAL "$device" | xargs)" = FRACCVBZ91544401B2
test "$(lsblk -bdno RM "$device")" = 1
test -z "$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d')"
root_source=$(findmnt -nro SOURCE /)
test "$device" != "$root_source"
! lsblk -srno PATH "$root_source" | grep -Fxq "$device"
sha256sum -c "$checksum"
read -r -p "Type FLASH observability-pi TO MicroSD(2nd Gen) FRACCVBZ91544401B2: " answer
test "$answer" = 'FLASH observability-pi TO MicroSD(2nd Gen) FRACCVBZ91544401B2'
# Revalidate at the write boundary.
test "$(lsblk -bdno SIZE "$device")|$(lsblk -dno MODEL "$device" | xargs)|$(lsblk -dno SERIAL "$device" | xargs)|$(lsblk -bdno RM "$device")" = \
  '128177930240|MicroSD(2nd Gen)|FRACCVBZ91544401B2|1'
test -z "$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d')"
zstdcat -- "$image" | dd of="$device" bs=16M iflag=fullblock oflag=direct conv=fsync status=progress
sync
```

Power off the Pi, insert the medium, connect exactly one Ethernet cable and
boot. Do not connect or initialize a telemetry disk yet.

## 3. First boot and NIC identity

```sh
set -eu
ping -c 3 10.15.4.6
ssh root@10.15.4.6 'hostnamectl --static; ip -br link; ip route'
ssh root@10.15.4.6 'for i in /sys/class/net/*; do printf "%s " "$(basename "$i")"; cat "$i/address"; done'
```

Record the Ethernet interface/MAC as observed evidence in both inventories,
replace the bootstrap any-Ethernet match with that exact MAC, and rebuild.
Only then remove the forced comin disable from the host configuration.

## 4. Telemetry SSD refusal, identity, and initialization

`/dev/sdb` is 128,177,930,240 bytes and must be refused. Connect a separate
SSD of at least 2,000,000,000,000 bytes and collect its stable identity:

```sh
ssh root@10.15.4.6 'set -eu; lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,FSTYPE,MOUNTPOINTS; findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib /var/lib/telemetry 2>/dev/null || true'
```

Record model, serial or WWN, exact bytes, and `/dev/disk/by-id` symlink. Update
`telemetryIdentity` with that tuple (capacity represented by its exact sector
count), rebuild natively, and rerun installer safety checks. On the Pi, first
prove the unresolved image refuses `initialize-telemetry-ssd`; after deploying
the pinned build, run it interactively. Do not pipe confirmations. It must
locate the disk by the pinned tuple and revalidate at the format boundary.

```sh
initialize-telemetry-ssd
findmnt -M /var/lib/telemetry -o SOURCE,TARGET,FSTYPE,OPTIONS
lsblk -f
smartctl -x /dev/disk/by-id/REPLACE_WITH_OBSERVED_STABLE_ID
```

Record the filesystem UUID and a redacted SMART health baseline. Never record
device credentials or unrelated serials.

## 5. sops enrollment and comin deployment

On the Pi, `fleet-enroll` reads only the public SSH host key. Add its printed
public age recipient only to the `observability-pi` host rule and the
`pi-connectors` group in `.sops.yaml`. Rewrap only affected encrypted files;
inspect metadata-only diffs and never print decrypted content.

```sh
ssh root@10.15.4.6 fleet-enroll
sops updatekeys secrets/hosts/observability-pi/REPLACE.yaml
sops updatekeys secrets/pi-connectors/REPLACE.yaml
jj diff --summary
```

Commit and push a signed reviewed `main` revision, then confirm comin reports
that exact revision. GitHub is the bootstrap source. A stable self-hosted
Forgejo remote is deliberately deferred to Task 18: add it as an additional
comin remote only after its URL, TLS trust, availability independent of this
host, protected `main`, and replication/recovery have been proven. Do not
replace the bootstrap remote during this wave.

## 6. Acceptance and current-cluster connection

Run and record every check after a reboot:

```sh
ssh root@10.15.4.6 'set -eu; systemctl reboot'
ping -c 3 10.15.4.6
ssh root@10.15.4.6 'set -eu; findmnt -M /var/lib/telemetry; systemctl --failed --no-legend | grep -q . && exit 1 || :; systemctl is-active prometheus loki tempo grafana opentelemetry-collector comin cloudflared'
ssh root@10.15.4.6 'curl -fsS http://127.0.0.1:9090/-/ready; curl -fsS http://127.0.0.1:3100/ready; curl -fsS http://127.0.0.1:3200/ready; curl -fsS http://127.0.0.1:3000/api/health; curl -fsS http://127.0.0.1:4243/metrics >/dev/null'
```

From a disposable test client, send uniquely labelled OTLP metrics, logs, and
one sampled trace to the configured gateway, then query Prometheus, Loki, and
Tempo for those labels. Record queries and non-secret results. Verify configured
retention and filesystem quotas, fire and resolve each required test alert,
and save Grafana/comin dashboard URLs. Confirm connector 1 is healthy without
displaying its credential.

Connect the current Kubernetes cluster only through its approved telemetry
agent/scrape configuration. Apply no workload changes. Verify targets are up,
all three signals arrive with cluster identity, and delivery interruption does
not make workloads depend on telemetry.

Run the documented backup job, verify a new snapshot exists, and perform the
approved restore rehearsal from `docs/runbooks/backup-restore.md`. Do not claim
readiness from configuration alone.

## 7. Rollback

If deployment health fails, select the prior NixOS boot generation locally or
run `nixos-rebuild switch --rollback`, retain bootstrap SSH, and point `main`
to a reviewed forward-fix commit (never force-push). Disable current-cluster
telemetry forwarding by reverting only its approved telemetry change. Do not
reformat the telemetry SSD; preserve it for diagnosis and restore. If the boot
medium fails, power off and reflash only after repeating the complete media
guard.

## Evidence record

- Reviewed/pushed revision and signature verification:
- Native builder architecture; image store path, byte size, SHA-256:
- Closure inspection commands/results:
- Boot-media immediate identity/revalidation and flash timestamp:
- First boot timestamp; interface/MAC; static-address and SSH results:
- Telemetry SSD model, serial/WWN, by-id, exact bytes; guard result:
- Filesystem UUID, mount options, SMART baseline:
- sops recipient scope and encrypted files rewrapped (no key material):
- comin deployed revision/dashboard URL:
- Reboot and service acceptance outputs:
- OTLP labels and Prometheus/Loki/Tempo query results:
- Retention/quota and alert fire/resolve results:
- Grafana/dashboard links and connector 1 status:
- Current-cluster scrape/forwarding evidence and change reference:
- Backup snapshot and restore rehearsal result:
- Rollback generation/revision and steps exercised:
- Unresolved blockers:
