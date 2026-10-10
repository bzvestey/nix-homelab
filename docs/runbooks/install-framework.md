# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Published artifacts built before the hl-node-02 disk-identity update still contain `UNRESOLVED` and refuse installation; rebuild after publishing the verified facts. hl-node-03 and hl-node-04 identities remain unresolved. The installer requires the exact by-id link to resolve to a whole block device whose canonical path, decimal major/minor number, model, serial, and 512-byte sector count all match. Its tiny outer entrypoint always enters a fresh mount namespace with recursively private propagation before executing the store-path installer. The inner installer verifies from `/proc/self/mountinfo` that `/` and every mounted `/dev` hierarchy lack shared or slave propagation before authorization, settles udev, and holds the verified device FD open. A separate root-only lock file under `/run/framework-installer-locks`, keyed by device number, serializes cooperating installers before recovery-key creation. Never hold an exclusive flock on the disk across Disko: udev needs its own shared whole-disk flock to process partition events, so that would deadlock its settle operation. The retained device FD and namespace-local bind, not the advisory lock, pin device identity. Inside that namespace only, it bind-mounts the held device onto its exact `/dev/nvmeXnY` canonical node, revalidates the bound node's decimal major/minor, and gives Disko that pinned canonical path. Both named NIC members' permanent hardware MACs (from `ethtool -P`) and the integrated GPU must also match verified facts; a bond-shared current MAC is not physical identity evidence. Missing or unverified permanent MACs refuse installation.

Read-only Talos inspection of `minastas-home-cluster-w1` (`10.15.4.5`) on October 9, 2026 UTC observed `/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S59CNM0W713317D_1 -> ../../nvme0n1`. The disk resource and sysfs independently confirm model `Samsung SSD 970 EVO Plus 2TB`, serial `S59CNM0W713317D`, 3,907,029,168 512-byte sectors, and current device number `259:0`. The earlier assessment incorrectly treated these links as unavailable; they were also present in the saved disk-resource capture. `lib/fleet-topology.nix` now pins the observed namespace-qualified link for hl-node-02. This required no reboot or disk write and does not authorize installation. Revalidate the link, disk/NIC/GPU facts and mount state on the installation media before destructive authorization; never infer a link from a serial or fabricate physical evidence. Do not install if it is absent or inconsistent.

Live installer inspection on October 9, 2026 verified hl-node-02's permanent
MACs as `enp0s13f0u1 = 9c:bf:0d:00:23:fe` and
`enp0s13f0u2 = 9c:bf:0d:00:25:5d`. The older inventory captured both current
addresses after bonding, not two identical hardware identities. These path names
describe that observation, not stable identities. On the corrected host and ISO,
physical-interface `.link` rules assign `lan0` to permanent MAC
`9c:bf:0d:00:23:fe` and `lan1` to `9c:bf:0d:00:25:5d`, regardless of USB
controller/port enumeration. Network matching and installer preflight use those
stable names and still require the exact permanent MACs. The installer must
refuse if either stable name is absent or has a different permanent identity;
do not bypass its checks or substitute an adapter. The USB hub's separate
Ethernet NIC is not an enrolled member and stays outside the bond.
The bond uses active-backup mode with 100 ms link monitoring.
Networkd alone manages the ISO's static networking; the minimal
live image's NetworkManager is disabled to prevent competing DHCP configuration.
hl-node-03/04 permanent MACs remain unverified; their installers refuse even if
disk identity is later resolved. Their existing unverified boot selectors are
retained until measured, not reclassified as permanent hardware observations.

The previously flashed hl-node-02 ISO still requires historical USB-path names
in addition to permanent MACs. During its physical boot test the `23:fe` adapter
enumerated as `enp0s20f0u1` on USB 2.0 instead of `enp0s13f0u1`; the operator
confirmed it had not moved. Requiring the old name excluded it from the bond.
The reason for USB 2.0 enumeration remains unproven; stable naming does not
repair or prove USB 3.x performance. Do not bypass preflight or run that
installer. Publish the reviewed stable-name correction, obtain a new CI-cleared
revision-bound artifact and repeat the checksum/media handoff before installation.
An adapter also disappeared during an earlier test and returned after reseating;
its hardware/driver cause remains unproven. Recheck stability, USB bus speeds
and physical failover on corrected media. A successful simulated VM failover
does not establish physical adapter reliability.

## Bootstrap-only publication and media handoff

For hl-node-02, the default host must import `hosts/hl-node-02/bootstrap.nix`.
This is **bootstrap-only, not shadow production**: workload, database, runner,
Caddy and backup services/timers are masked, and production NFS is removed.
SSH, telemetry, enrollment tools and signature-enforcing comin remain available.
Verify effective masks, absence of the production mount/automount, and no
workload listeners at the reviewed revision; missing secrets alone are not a
bootstrap boundary.

Before any boot, the bootstrap policy must be signed, published to the exact
branch comin will switch from, and CI-cleared. A safe ISO followed by comin
switching to production-enabled `main` is unacceptable. Set
`fleet.comin.enableMirror = false` for GitHub-only bootstrap until the mirror
publishes the same safe policy. Every fallback must be equally bootstrap-safe
or disabled. Record the allowed signer, branch, signed commit and CI run;
recheck remote heads immediately before boot. Do not weaken signature checks.

Before separately authorizing an empty hl-node-02 bootstrap installation, run
`nix run .#bootstrap-readiness-hl-node-02` in the reviewed repository. This
static check compares observed hardware against installer pins and requires
the quarantine above. Also retain fresh source evacuation, backup/rollback,
physical disk/mount and network acceptance evidence; the command does not probe
the machine or authorize erasure. Full `nix run .#inventory-readiness` remains
mandatory before production data restore/activation, not before creating the
empty destination filesystems needed to measure their real free space.
Never substitute ISO tmpfs free bytes for installed root/data free bytes.

Inventory/check/runbook-only corrections do not require replacing accepted
media when its installer, hardware pins and bootstrap configuration remain
unchanged. Keep using the original signed, CI-cleared artifact with its exact
manifest/checksum, and verify that its embedded target is still bootstrap-safe.
The flake stamps telemetry with the source revision, so a dirty/new revision
can change output paths even without a runtime policy change. Compare old and
new outputs at the same revision label to isolate that difference; this is an
offline equivalence check, not permission to relabel a new artifact as the old
commit or overwrite provenance. Rebuild/reflash if installer behavior, pins,
inputs or target policy actually change. Do not publish a new comin switch
revision without separate approval and CI clearance.

The operator needs a **downloadable Framework ISO**, SHA256 checksum and
revision manifest, not just a successful build or store path. The Framework
job in `.github/workflows/images.yml` packages and uploads
`hl-node-02-bootstrap-<full-commit>` with `hl-node-02-bootstrap.iso`,
`hl-node-02.sha256` and `hl-node-02.manifest` (seven-day retention).
The manifest records commit/output/store path and `installation_ready=false`;
artifact existence is not acceptance. A successful published run and actual
downloadable artifact remain gates. An approved publisher must supply the
revision-bound artifact URL/ID, host ID, full
signed commit, flake.lock identity, CI run ID/result, Nix output and ISO store
path/name, and checksum. No download URL or digest is claimed here. Download
the matching bundle, verify its provenance against the reviewed signed
revision and successful CI, then verify SHA256 locally before flashing; reject
expired/missing artifacts, host mismatches or unbound checksums.

Build on x86_64 Linux:

```console
nix build .#images.hl-node-02
nix build .#images.hl-node-03
nix build .#images.hl-node-04
```

## Separately authorized physical procedure (pending acceptance)

Physical flashing and installation are **not authorized by this task**.

1. Complete the source evacuation gate in [Wave 2](wave-2-hl-node-02.md) before taking over hl-node-02's disk or `10.15.4.5`. Retain source disks/PVCs, backups and rollback evidence. Verify the published bootstrap revision, ISO digest and by-id acceptance evidence, then boot the matching host's ISO only under separate approval.
2. Verify static networking and SSH without an address collision. Run `install-hl-node-02` locally on a trusted console for hl-node-02 (other hosts use their matching `install-hl-node-NN` binary).
3. The script creates one recovery key from `/dev/urandom` in mode-0700 tmpfs under `/run`. It is never embedded in the image, Nix store, command line, shell history, or normal output. **Before the first destructive command**, it displays the key on `/dev/tty`; copy it to approved offline escrow, independently read it back, and only then type the exact acknowledgement. Refusing or interruption before that point leaves the disk untouched. After Disko starts, partial disk state is possible, but the already escrowed recovery key remains available.
4. Disko creates GPT/EFI plus separate LUKS2 root and data volumes through the namespace-local canonical bind while the source identity FD stays open and the separate installer lock remains held. The script discovers each PARTLABEL only beneath the held parent, opens both exact child block devices, checks each opened FD's decimal major/minor and kernel sysfs parent, keeps both FDs open, and gives cryptenroll only their `/proc` FD paths.
5. Before destruction, the installer reads the EFI `SecureBoot` variable and reports `ENABLED`, `DISABLED`, or `UNAVAILABLE`/`UNKNOWN`. It requires an exact acknowledgement that PCR 7 binds **that current policy state**. This does not enable, configure, or establish Secure Boot, and PCR 7 alone is not an authenticity claim. Physical PCR stability and auto-unlock acceptance remain pending.
6. After Disko destructive mode has started, one EXIT cleanup attempts Disko filesystem unmount. It separately removes a successfully created namespace-local device-node bind and shreds/removes the recovery-key file while preserving an earlier failure status. Failures before Disko starts never call Disko cleanup. An unmount failure is itself fatal after otherwise successful work and prints a manual-recovery instruction; the installer never reports the target unmounted unless both cleanup stages succeeded. The host mount namespace is never modified.

## Acceptance after authorization

- Prove TPM2 auto-unlock after a cold boot.
- Disable/bypass TPM unlock on nonproduction media and prove the escrowed recovery key unlocks both volumes.
- Confirm `/etc/ssh/ssh_host_ed25519_key` and its fingerprint survive reboot; run `fleet-enroll` only in the authorized enrollment procedure and prove the same host key is retained.
- Verify the expected static address, SSH access, telemetry, comin signature enforcement and GitHub-only policy. Prove the deployed generation remains bootstrap-only after polling/reboot; workload/database/runner/Caddy/backup units must remain masked and production NFS absent. Capture the real host public key and fingerprint privately for enrollment, never fabricate them.

Enrollment, isolated restore and production activation are separate gates in
[Wave 2](wave-2-hl-node-02.md); installation does not authorize any of them.

TPM enrollment, recovery-key escrow, destructive installation, and these boot tests remain pending physical acceptance.
