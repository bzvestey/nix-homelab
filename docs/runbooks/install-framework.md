# Framework bootstrap installation

## Safety boundary

The three ISOs are host-specific. Every current ISO deliberately refuses: no stable Framework `/dev/disk/by-id/...` value has been observed, so each recorded value is `UNRESOLVED`. After physical capture and rebuild, the installer will require that exact by-id link to resolve to a whole block device whose canonical path, major/minor number, model, serial, and 512-byte sector count all match. It settles udev, holds an exclusive open-device lock, and revalidates the complete token immediately before Disko. Both named NIC members and the integrated GPU must also match the recorded facts.

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
4. Disko creates GPT/EFI plus separate LUKS2 root and data volumes. The script discovers each PARTLABEL only among children of the exact guarded parent and rejects missing, duplicate, or wrong-parent results. It never uses global by-partlabel links.
5. Both exact partitions are enrolled with the recovery key and explicit PCR 7 policy. PCR 7 measures Secure Boot policy and is stable across normal systemd-boot generation changes, unlike PCRs that bind a specific kernel/initrd. Physical validation against the final installed firmware/Secure Boot configuration, TPM auto-unlock, and recovery-key unlock remains mandatory and pending.
6. On any error or signal, the EXIT cleanup unmounts the target, shreds/removes the recovery-key file, and prints failure. Only the final explicit message means completion.

## Acceptance after authorization

- Prove TPM2 auto-unlock after a cold boot.
- Disable/bypass TPM unlock on nonproduction media and prove the escrowed recovery key unlocks both volumes.
- Confirm `/etc/ssh/ssh_host_ed25519_key` and its fingerprint survive reboot; run `fleet-enroll` only in the authorized enrollment procedure and prove the same host key is retained.
- Verify the expected static address, SSH access, and comin status before workload migration.

TPM enrollment, recovery-key escrow, destructive installation, and these boot tests remain pending physical acceptance.
