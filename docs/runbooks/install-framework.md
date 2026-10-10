# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Published artifacts built before the hl-node-02 disk-identity update still contain `UNRESOLVED` and refuse installation; rebuild after publishing the verified facts. hl-node-03 and hl-node-04 identities remain unresolved. The installer requires the exact by-id link to resolve to a whole block device whose canonical path, decimal major/minor number, model, serial, and 512-byte sector count all match. Its tiny outer entrypoint always enters a fresh mount namespace with recursively private propagation before executing the store-path installer. The inner installer verifies from `/proc/self/mountinfo` that `/` and every mounted `/dev` hierarchy lack shared or slave propagation before authorization, settles udev, and holds the verified device FD open under an exclusive lock. Inside that namespace only, it bind-mounts the held device onto its exact `/dev/nvmeXnY` canonical node, revalidates the bound node's decimal major/minor, and gives Disko that pinned canonical path. Both named NIC members' permanent hardware MACs (from `ethtool -P`) and the integrated GPU must also match verified facts; a bond-shared current MAC is not physical identity evidence. Missing or unverified permanent MACs refuse installation.

Read-only Talos inspection of `minastas-home-cluster-w1` (`10.15.4.5`) on October 9, 2026 UTC observed `/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S59CNM0W713317D_1 -> ../../nvme0n1`. The disk resource and sysfs independently confirm model `Samsung SSD 970 EVO Plus 2TB`, serial `S59CNM0W713317D`, 3,907,029,168 512-byte sectors, and current device number `259:0`. The earlier assessment incorrectly treated these links as unavailable; they were also present in the saved disk-resource capture. `lib/fleet-topology.nix` now pins the observed namespace-qualified link for hl-node-02. This required no reboot or disk write and does not authorize installation. Revalidate the link, disk/NIC/GPU facts and mount state on the installation media before destructive authorization; never infer a link from a serial or fabricate physical evidence. Do not install if it is absent or inconsistent.

Live installer inspection on October 9, 2026 verified hl-node-02's permanent
MACs as `enp0s13f0u1 = 9c:bf:0d:00:23:fe` and
`enp0s13f0u2 = 9c:bf:0d:00:25:5d`. The older inventory captured both current
addresses after bonding, not two identical hardware identities. The corrected
host and ISO use permanent-MAC selectors and active-backup bonding with 100 ms
link monitoring. Networkd alone manages the ISO's static networking; the minimal
live image's NetworkManager is disabled to prevent competing DHCP configuration.
hl-node-03/04 permanent MACs remain unverified; their installers refuse even if
disk identity is later resolved. Their existing unverified boot selectors are
retained until measured, not reclassified as permanent hardware observations.

The old hl-node-02 ISO that boots successfully still has incorrect NIC matching
and preflight checks. Do not bypass them or run its installer. Publish the
reviewed correction, obtain a new CI-cleared revision-bound artifact and repeat
the checksum/media handoff before installation. An adapter disappeared during
the physical boot test and returned after reseating; the hardware/driver cause
remains unproven. Recheck stability and perform physical failover acceptance
on the corrected media; successful reseating is not long-term reliability proof.

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
4. Disko creates GPT/EFI plus separate LUKS2 root and data volumes through the namespace-local canonical bind while the locked source FD stays open. The script discovers each PARTLABEL only beneath the held parent, opens both exact child block devices, checks each opened FD's decimal major/minor and kernel sysfs parent, keeps both FDs open, and gives cryptenroll only their `/proc` FD paths.
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
