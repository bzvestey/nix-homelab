# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Every current ISO deliberately refuses: no stable Framework `/dev/disk/by-id/...` value has been observed, so each recorded value is `UNRESOLVED`. After physical capture and rebuild, the installer will require that exact by-id link to resolve to a whole block device whose canonical path, decimal major/minor number, model, serial, and 512-byte sector count all match. Its tiny outer entrypoint always enters a fresh mount namespace with recursively private propagation before executing the store-path installer. The inner installer verifies from `/proc/self/mountinfo` that `/` and every mounted `/dev` hierarchy lack shared or slave propagation before authorization, settles udev, and holds the verified device FD open under an exclusive lock. Inside that namespace only, it bind-mounts the held device onto its exact `/dev/nvmeXnY` canonical node, revalidates the bound node's decimal major/minor, and gives Disko that pinned canonical path. Both named NIC members and the integrated GPU must also match the recorded facts.

Task 2 could not observe `/dev/disk/by-id`. Before physical cutover, boot the final media, capture `ls -l /dev/disk/by-id` plus `lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS`, record the exact whole-device by-id in `flake.nix`, and rebuild. Do not install if it is absent or inconsistent.

Build on x86_64 Linux:

```console
nix build .#images.framework-01
nix build .#images.framework-02
nix build .#images.framework-03
```

## Authorized physical procedure (pending Task 11)

Physical flashing and installation are **not authorized by this task**.

1. Verify the ISO digest and by-id acceptance evidence, then boot the matching host's ISO.
2. Verify static networking and SSH. Run `install-framework-NN` locally on a trusted console.
3. The script creates one recovery key from `/dev/urandom` in mode-0700 tmpfs under `/run`. It is never embedded in the image, Nix store, command line, shell history, or normal output. **Before the first destructive command**, it displays the key on `/dev/tty`; copy it to approved offline escrow, independently read it back, and only then type the exact acknowledgement. Refusing or interruption before that point leaves the disk untouched. After Disko starts, partial disk state is possible, but the already escrowed recovery key remains available.
4. Disko creates GPT/EFI plus separate LUKS2 root and data volumes through the namespace-local canonical bind while the locked source FD stays open. The script discovers each PARTLABEL only beneath the held parent, opens both exact child block devices, checks each opened FD's decimal major/minor and kernel sysfs parent, keeps both FDs open, and gives cryptenroll only their `/proc` FD paths.
5. Before destruction, the installer reads the EFI `SecureBoot` variable and reports `ENABLED`, `DISABLED`, or `UNAVAILABLE`/`UNKNOWN`. It requires an exact acknowledgement that PCR 7 binds **that current policy state**. This does not enable, configure, or establish Secure Boot, and PCR 7 alone is not an authenticity claim. Physical PCR stability and auto-unlock acceptance remain pending.
6. After Disko destructive mode has started, one EXIT cleanup attempts Disko filesystem unmount. It separately removes a successfully created namespace-local device-node bind and shreds/removes the recovery-key file while preserving an earlier failure status. Failures before Disko starts never call Disko cleanup. An unmount failure is itself fatal after otherwise successful work and prints a manual-recovery instruction; the installer never reports the target unmounted unless both cleanup stages succeeded. The host mount namespace is never modified.

## Acceptance after authorization

- Prove TPM2 auto-unlock after a cold boot.
- Disable/bypass TPM unlock on nonproduction media and prove the escrowed recovery key unlocks both volumes.
- Confirm `/etc/ssh/ssh_host_ed25519_key` and its fingerprint survive reboot; run `fleet-enroll` only in the authorized enrollment procedure and prove the same host key is retained.
- Verify the expected static address, SSH access, and comin status before workload migration.

TPM enrollment, recovery-key escrow, destructive installation, and these boot tests remain pending physical acceptance.
