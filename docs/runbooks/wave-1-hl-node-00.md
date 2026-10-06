# Wave 1: observability Pi

This runbook installs `hl-node-00` at `10.15.4.6`. Record evidence in
the fields at the end without copying credentials, private keys, or decrypted
secret values. Stop at any failed guard; a device path alone is never an
identity.

## 1. Controller and build preflight

Use the reviewed `main` revision and a native AArch64 Linux builder. Emulation
is not acceptance evidence.

Before approving the revision, run the full serialized x86 flake check on a
local machine with readable and writable KVM: `nix flake check --show-trace
--option max-jobs 1`. A hosted non-KVM evaluation and native-check run does not
replace this full VM-backed suite.

Pi 5 firmware is embedded in EEPROM, so the managed firmware package excludes
the unused external `start*.elf` and `fixup*.dat` variants while retaining
device trees, overlays, and `bootcode.bin`. Future bootstrap images use a 128
MiB firmware partition. Existing 30 MiB installations are not resized: managed
activation removes only stale external Pi firmware files before installing the
managed set. After an interrupted firmware update, do not reboot until that
activation succeeds.

### Historical pre-rename evidence (non-executable)

The reviewed, successfully booted image was produced before the canonical
identity migration. Its immutable GitHub metadata records revision
`f2136979cfa49aee795857b0c536e15711907272`, workflow run `37098600729`, and
artifact `11267220813`. The artifact name and member names below are retained
verbatim as migration history; this block documents the old evidence and is
not an active procedure. Task 5 must obtain and pin new canonical CI evidence
before a canonical artifact is used for installation. Do not substitute new
names while retaining these immutable IDs or hashes.

```text
set -euo pipefail
repo=bzvestey/nix-homelab
workflow_run=37098600729
artifact_id=11267220813
image_revision=f2136979cfa49aee795857b0c536e15711907272
artifact_name="observability-pi-$image_revision"
archive=./observability-pi-artifact.zip
archive_sha256=faae280f4ace27c640bc5bf89528ba93fa0089a3c1adc3628f2d2774dcade7fa
artifact_dir=./observability-pi-artifact
image_filename=nixos-image-sd-card-26.11.20261001.c59305b-aarch64-linux.img.zst

metadata=$(gh api "repos/$repo/actions/artifacts/$artifact_id")
test "$(jq -r '.id' <<<"$metadata")" = "$artifact_id"
test "$(jq -r '.name' <<<"$metadata")" = "$artifact_name"
test "$(jq -r '.expired' <<<"$metadata")" = false
test "$(jq -r '.workflow_run.id' <<<"$metadata")" = "$workflow_run"
test "$(jq -r '.workflow_run.head_sha' <<<"$metadata")" = "$image_revision"
test "$(jq -r '.digest' <<<"$metadata")" = "sha256:$archive_sha256"

run_metadata=$(gh api "repos/$repo/actions/runs/$workflow_run")
test "$(jq -r '.id' <<<"$run_metadata")" = "$workflow_run"
test "$(jq -r '.path' <<<"$run_metadata")" = .github/workflows/images.yml
test "$(jq -r '.head_sha' <<<"$run_metadata")" = "$image_revision"
test "$(jq -r '.head_branch' <<<"$run_metadata")" = main
test "$(jq -r '.conclusion' <<<"$run_metadata")" = success

gh api "repos/$repo/actions/artifacts/$artifact_id/zip" > "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c -
rm -rf -- "$artifact_dir"
mkdir -- "$artifact_dir"
mapfile -t members < <(unzip -Z1 "$archive" | LC_ALL=C sort)
expected_members=(
  "$image_filename"
  observability-pi.manifest
  observability-pi.sha256
)
test "${#members[@]}" -eq "${#expected_members[@]}"
for i in "${!expected_members[@]}"; do
  test "${members[$i]}" = "${expected_members[$i]}"
done
unzip -q "$archive" -d "$artifact_dir"

manifest="$artifact_dir/observability-pi.manifest"
mapfile -t manifest_keys < <(cut -d= -f1 "$manifest" | LC_ALL=C sort)
expected_keys=(git_commit image_store_path nix_output)
test "${#manifest_keys[@]}" -eq "${#expected_keys[@]}"
for i in "${!expected_keys[@]}"; do
  test "${manifest_keys[$i]}" = "${expected_keys[$i]}"
done
manifest_value() {
  local key=$1
  local -a matches
  mapfile -t matches < <(sed -n "s/^${key}=//p" "$manifest")
  test "${#matches[@]}" -eq 1
  test -n "${matches[0]}"
  printf '%s\n' "${matches[0]}"
}
test "$(manifest_value git_commit)" = "$image_revision"
nix_output=$(manifest_value nix_output)
image_store_path=$(manifest_value image_store_path)
[[ "$nix_output" = /nix/store/* ]]
[[ "$image_store_path" = "$nix_output/sd-image/$image_filename" ]]
(cd "$artifact_dir" && sha256sum -c observability-pi.sha256)
```

The historical run ID and workflow definition are separate GitHub fields; the
recorded checks bound both for that already-reviewed run.

For a local rebuild instead, use the reviewed `main` tree. Jujutsu normally
places an empty working-copy commit above `main`, so compare trees rather than
requiring `@` and `main` to have the same commit ID.

```bash
set -euo pipefail
test "$(uname -m)" = aarch64
reviewed_revision=REPLACE_WITH_REVIEWED_MAIN_COMMIT
[[ "$reviewed_revision" =~ ^[0-9a-f]{40}$ ]]
test "$(jj log -r main -T 'commit_id' --no-graph)" = "$reviewed_revision"
test -z "$(jj diff --from "$reviewed_revision" --to @ --summary)"
nix build ".#images.hl-node-00"
nix build ".#nixosConfigurations.hl-node-00.config.system.build.toplevel"
mapfile -t images < <(find -L result/sd-image -maxdepth 1 -type f -name '*.img.zst' -print)
test "${#images[@]}" -eq 1
image=${images[0]}
sha256sum "$image" | tee "$(basename "$image").sha256"
nix path-info -S ".#images.hl-node-00" ".#nixosConfigurations.hl-node-00.config.system.build.toplevel"
```

Inspect both closures before transfer. Replace `SECRET_SENTINEL` only with a
non-secret test marker that is known to be absent; never put a real secret in
an argument, environment variable, store path, or log.

```bash
set -euo pipefail
for output in \
  "$(nix path-info .#images.hl-node-00)" \
  "$(nix path-info .#nixosConfigurations.hl-node-00.config.system.build.toplevel)"
do
  nix-store -qR "$output"
done | sort -u > /tmp/hl-node-00-closure
! grep -RIl --binary-files=without-match 'SECRET_SENTINEL' $(cat /tmp/hl-node-00-closure)
! find -L $(cat /tmp/hl-node-00-closure) -type f \
  \( -name 'ssh_host_*_key' -o -name '*.agekey' -o -name 'id_ed25519' \) -print -quit | grep -q .
```

Transfer the locally built image and checksum over an authenticated channel.
The local rebuild is a new image and requires its own review and binding
evidence. Once Task 5 pins canonical CI evidence, use that procedure instead.

## 2. Guarded boot-media flash

The stable boot-media path is
`/dev/disk/by-id/usb-FRMW_MicroSD_2nd_Gen__FRACCVBZ91544401B2-0:0`; it must
resolve to the observed whole disk `/dev/sdb`, but `/dev/sdb` alone must never
be used to select the target. Its currently observed identity is: model
`MicroSD(2nd Gen)`, serial `FRACCVBZ91544401B2`, exactly `128177930240`
bytes. Do not write it until the reviewed native image and checksum have been
verified. Immediately before writing, run this whole block as root. It refuses
identity drift, mounted children, the system disk, non-removable media, and an
unverified image hash.

```bash
set -euo pipefail
test "$(id -u)" -eq 0
stable_device=/dev/disk/by-id/usb-FRMW_MicroSD_2nd_Gen__FRACCVBZ91544401B2-0:0
expected_device=/dev/sdb
image_filename=nixos-image-sd-card-26.11.20261001.c59305b-aarch64-linux.img.zst
image=./result/sd-image/$image_filename
checksum=./$image_filename.sha256

guard_flash_target() {
  test -L "$stable_device"
  device=$(readlink -f -- "$stable_device")
  test "$device" = "$expected_device"
  test -b "$device"
  test "$(lsblk -dnro TYPE "$device")" = disk
  test "$(lsblk -bdno SIZE "$device")" = 128177930240
  test "$(lsblk -dno MODEL "$device" | xargs)" = 'MicroSD(2nd Gen)'
  test "$(lsblk -dno SERIAL "$device" | xargs)" = FRACCVBZ91544401B2
  test "$(lsblk -bdno RM "$device")" = 1
  test -z "$(lsblk -nrpo MOUNTPOINTS "$device" | sed '/^$/d')"
  for target in / /boot /nix; do
    findmnt -rnT "$target" >/dev/null || continue
    system_source=$(findmnt -nro SOURCE -T "$target")
    system_source=${system_source%%\[*}
    system_ancestry=$(lsblk -srno PATH "$system_source")
    ! grep -Fxq "$device" <<<"$system_ancestry"
  done
  test -f "$checksum"
  sha256sum -c "$checksum"
}

guard_flash_target
read -r -p "Type FLASH hl-node-00 TO MicroSD(2nd Gen) FRACCVBZ91544401B2: " answer
test "$answer" = 'FLASH hl-node-00 TO MicroSD(2nd Gen) FRACCVBZ91544401B2'
# Repeat every destructive guard after confirmation, directly at the write boundary.
guard_flash_target
zstdcat -- "$image" | dd of="$device" bs=16M iflag=fullblock oflag=direct conv=fsync status=progress
sync
```

Keep the Pi powered off, insert the medium, and connect exactly one Ethernet
cable. Before boot, prove `10.15.4.6` is unused from the controller's intended
interface. Any ICMP or ARP response is a conflict and a hard stop. Do not
connect or initialize a telemetry disk yet.

```bash
set -euo pipefail
address=10.15.4.6
interface=$(ip -json route get "$address" | jq -er '.[0].dev')
if ping -c 3 -W 1 "$address"; then
  echo "address conflict: $address responds to ICMP" >&2
  exit 1
fi
arping -D -I "$interface" -c 3 "$address"
```

Boot only after that check passes. At the local Pi console, independently
record `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. On the controller,
scan the key into a dedicated file and compare its fingerprint exactly with
the console value before making any SSH connection. Never disable host-key
checking.

## 3. First boot and NIC identity

```bash
set -euo pipefail
expected_fingerprint='SHA256:AbBRaZDEZOslLc9vS5xIvQjshiizOBBVtFQKhUxuAug'
known_hosts=$(mktemp)
trap 'rm -f -- "$known_hosts" "$known_hosts.pub"' EXIT
ssh-keyscan -t ed25519 hl-node-00 > "$known_hosts"
ssh-keygen -lf "$known_hosts" > "$known_hosts.pub"
test "$(wc -l < "$known_hosts.pub")" -eq 1
test "$(awk 'NR == 1 { print $2 }' "$known_hosts.pub")" = "$expected_fingerprint"
ping -c 3 10.15.4.6
ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes \
  root@hl-node-00 'hostnamectl --static; ip -br link; ip route'
ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes \
  root@hl-node-00 'for i in /sys/class/net/*; do printf "%s " "$(basename "$i")"; cat "$i/address"; done'
```

The observed wired identity is `end0` at `2c:cf:67:72:a7:20`; `wld0` at
`2c:cf:67:72:a7:21` was down. The normal configuration matches the exact wired
interface/MAC, removes the one-interface bootstrap service, and enables comin.
This network is intended as VLAN 4 on an untagged access port. Do not add an
802.1Q interface or claim LLDP advertises VLAN membership. Host tagging remains
deferred until the switch port is confirmed and coordinated as a trunk.

## 4. Telemetry SSD refusal, identity, and initialization

The boot card is `/dev/mmcblk0`, exactly 128,177,930,240 bytes, at stable ID
`/dev/disk/by-id/mmc-ED2S5_0xb13669d3`; partition 1 is mounted at
`/boot/firmware`, and partition 2 backs `/` and `/nix/store`. It is not telemetry
storage. The telemetry SSD is now attached through a powered USB 3/UAS path at
`/dev/disk/by-id/ata-Samsung_SSD_970_EVO_Plus_2TB_S6S2NS0W226715A`. Its pinned
tuple is model `Samsung SSD 970 EVO Plus 2TB`, serial `S6S2NS0W226715A`, and
exactly 3,907,029,168 512-byte sectors (2,000,398,934,016 bytes). Revalidate all
of those facts immediately before seeking destructive approval:

```sh
ssh root@hl-node-00 'set -eu; lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,FSTYPE,MOUNTPOINTS; findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib /var/lib/telemetry 2>/dev/null || true'
```

The drive's ATA by-id is intentionally pinned instead of the observed Sabrent
USB bridge ID because the ATA identity follows the physical SSD rather than
the enclosure. Read-only inspection on 2026-10-06 found the disk unmounted,
SMART overall passed, no critical warning, 37 C, 100% spare, 0% used, and no
media/data-integrity or logged errors. It also found about 826 GB of old data
and existing Windows recovery, Microsoft data, and EFI partitions. Do not use
their mutable GPT/PTUUID or filesystem identifiers in the guard.

The pinned tuple is not destructive approval. Before using the initializer,
obtain separate explicit approval to erase all old data, rebuild the image on
native ARM64, rerun installer safety checks, and repeat the read-only identity,
mount, and health checks. Run it interactively and do not pipe confirmations.
It must locate the whole disk by the pinned tuple and revalidate it at the
format boundary before `mkfs`.

```sh
initialize-telemetry-ssd
findmnt -M /var/lib/telemetry -o SOURCE,TARGET,FSTYPE,OPTIONS
lsblk -f
smartctl -x /dev/disk/by-id/ata-Samsung_SSD_970_EVO_Plus_2TB_S6S2NS0W226715A
```

Record the filesystem UUID and a redacted SMART health baseline. Never record
device credentials or unrelated serials.

## 5. sops enrollment and comin deployment

On the Pi, `fleet-enroll` reads only the public SSH host key. Add its printed
public age recipient only to the `hl-node-00` host rule and the
`pi-connectors` group in `.sops.yaml`. Rewrap only affected encrypted files;
inspect metadata-only diffs and never print decrypted content.

```sh
ssh root@hl-node-00 fleet-enroll
sops updatekeys secrets/hosts/hl-node-00/REPLACE.yaml
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
set -eu
expected_fingerprint='SHA256:AbBRaZDEZOslLc9vS5xIvQjshiizOBBVtFQKhUxuAug'
known_hosts=$(mktemp)
trap 'rm -f -- "$known_hosts" "$known_hosts.pub"' EXIT
ssh-keyscan -t ed25519 hl-node-00 > "$known_hosts"
ssh-keygen -lf "$known_hosts" > "$known_hosts.pub"
test "$(wc -l < "$known_hosts.pub")" -eq 1
test "$(awk 'NR == 1 { print $2 }' "$known_hosts.pub")" = "$expected_fingerprint"
ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes root@hl-node-00 'set -eu; systemctl reboot'
ping -c 3 10.15.4.6
ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes root@hl-node-00 'set -eu; ! findmnt -M /var/lib/telemetry; systemctl --failed --no-legend | grep -q . && exit 1 || :; for backend in prometheus loki tempo grafana; do ! systemctl is-active --quiet "$backend"; done; systemctl is-active opentelemetry-collector comin cloudflared'
ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes root@hl-node-00 'curl -fsS http://127.0.0.1:4243/metrics >/dev/null'
```

Until telemetry initialization receives separate destructive approval and is
completed, skip backend readiness, ingestion, retention, quota, alert,
dashboard, backup, and restore acceptance. Do not initialize or format the
SSD merely because its exact tuple is pinned. Confirm
connector 1 is healthy without displaying its credential.

Current-cluster connection and the backup/restore rehearsal remain postponed
with backend acceptance. After storage is separately approved and accepted,
connect the cluster only through its approved telemetry agent/scrape
configuration, then follow `docs/runbooks/backup-restore.md`.

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
