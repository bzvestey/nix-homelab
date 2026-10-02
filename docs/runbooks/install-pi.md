# Raspberry Pi 5 bootstrap images

Both host-specific AArch64 images use the pinned `nixos-hardware.nixosModules.raspberry-pi-5` profile and nixpkgs' pinned `sd-image-aarch64.nix`: Raspberry Pi firmware loads U-Boot, which loads the generic extlinux configuration. Build them only on native ARM64 Linux:

```console
nix build .#images.observability-pi
nix build .#images.services-pi
```

Physical flashing is pending Task 11. After authorization, verify the image digest, flash nonproduction media, and prove the host-specific static address and SSH access. `observability-pi` deliberately keeps comin disabled while its NIC MAC is unresolved; bootstrap networking still requires exactly one Ethernet link. `services-pi` uses its recorded `end0` MAC and has **no data-disk formatter**.

## Observability telemetry SSD

Only the observability image contains `initialize-telemetry-ssd`. Its expected model, serial, and capacity are deliberately `UNRESOLVED`, so the shared guard always refuses—even if an operator types every confirmation. It cannot select an arbitrary disk. Zero matches, multiple matches, any tuple mismatch, unresolved identity, or incorrect hostname all stop before `mkfs`.

Task 11 must collect trusted sysfs/JSON identity for the >=2 TB telemetry SSD, update the image's pinned tuple, rebuild it on native ARM64, and rerun safety checks before the initializer may be used. Do not weaken the guard or substitute a device name.
