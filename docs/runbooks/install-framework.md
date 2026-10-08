# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Every current ISO deliberately refuses: no stable Framework `/dev/disk/by-id/...` value has been observed, so each recorded value is `UNRESOLVED`. After physical capture and rebuild, the installer will require that exact by-id link to resolve to a whole block device whose canonical path, decimal major/minor number, model, serial, and 512-byte sector count all match. Its tiny outer entrypoint always enters a fresh mount namespace with recursively private propagation before executing the store-path installer. The inner installer verifies from `/proc/self/mountinfo` that `/` and every mounted `/dev` hierarchy lack shared or slave propagation before authorization, settles udev, and holds the verified device FD open under an exclusive lock. Inside that namespace only, it bind-mounts the held device onto its exact `/dev/nvmeXnY` canonical node, revalidates the bound node's decimal major/minor, and gives Disko that pinned canonical path. Both named NIC members and the integrated GPU must also match the recorded facts.

Task 2 could not observe `/dev/disk/by-id`. Before physical cutover, use separately approved nondestructive media to capture `ls -l /dev/disk/by-id` plus `lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS`, NIC identities and GPU PCI identity. Record the exact whole-device by-id and reviewed disk facts in `lib/fleet-topology.nix`, then rebuild the final media. By-id remains `UNRESOLVED`; never infer it from a serial or fabricate physical evidence. Do not install if it is absent or inconsistent.

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
