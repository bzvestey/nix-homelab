# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Their installer refuses unless the operator types the exact hostname, exactly one whole block device has the recorded sysfs model, serial, and byte capacity, both named NIC members have the recorded MAC, and the integrated GPU has the recorded PCI ID. It does not parse human `lsblk` output. Refusal occurs before key generation, Disko, partitioning, formatting, or installation.

Task 2 could not observe `/dev/disk/by-id`. Before physical cutover, boot the final media, capture `ls -l /dev/disk/by-id` plus `lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS`, and verify the by-id link resolves to the sole tuple-matched device. Record that acceptance evidence; do not install if it is absent or inconsistent.

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
3. The script creates one recovery key from `/dev/urandom` in mode-0700 tmpfs under `/run`. It is never embedded in the image, Nix store, command line, shell history, or normal output. Copy it from `/dev/tty` directly to approved offline escrow and independently read it back before typing the exact escrow acknowledgement.
4. Disko creates GPT/EFI plus separate LUKS2 root and data volumes. The script generates and preserves target SSH host keys, installs only this repository's bootstrap NixOS closure, then enrolls both volumes in the local TPM2.
5. On any error or signal, the trap unmounts the target, removes the temporary device link, shreds/removes the recovery-key file, and prints failure. Only the final explicit message means completion.

## Acceptance after authorization

- Prove TPM2 auto-unlock after a cold boot.
- Disable/bypass TPM unlock on nonproduction media and prove the escrowed recovery key unlocks both volumes.
- Confirm `/etc/ssh/ssh_host_ed25519_key` and its fingerprint survive reboot; run `fleet-enroll` only in the authorized enrollment procedure and prove the same host key is retained.
- Verify the expected static address, SSH access, and comin status before workload migration.

TPM enrollment, recovery-key escrow, destructive installation, and these boot tests remain pending physical acceptance.
