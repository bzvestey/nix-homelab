# Raspberry Pi 5 bootstrap images

Both host-specific AArch64 images use the pinned `nixos-hardware.nixosModules.raspberry-pi-5` profile and nixpkgs' pinned `sd-image-aarch64.nix`: Raspberry Pi firmware loads U-Boot, which loads the generic extlinux configuration. Build them only on native ARM64 Linux:

```console
nix build .#images.observability-pi
nix build .#images.services-pi
```

The observability Pi first boot established `end0` at `2c:cf:67:72:a7:20`, so its normal configuration now matches that exact interface/MAC and enables comin. `services-pi` uses its recorded `end0` MAC and has **no data-disk formatter**. Both addresses are on the intended VLAN 4 untagged access-port segment; do not add an 802.1Q interface or describe LLDP as advertising VLAN membership until switch ports are confirmed and coordinated as trunks.

## Observability telemetry SSD

Only the observability image contains `initialize-telemetry-ssd`. Its expected model, serial, and capacity are deliberately `UNRESOLVED`, so the shared guard always refuses—even if an operator types every confirmation. The initializer invokes the substituted, mode-0444 guard through Bash and therefore reaches that explicit refusal rather than failing with status 126. It cannot select an arbitrary disk. Zero matches, multiple matches, any tuple mismatch, unresolved identity, or incorrect hostname all stop before `mkfs`.

Task 11 must collect trusted sysfs/JSON identity for the >=2 TB telemetry SSD, update the image's pinned tuple, rebuild it on native ARM64, and rerun safety checks before the initializer may be used. Do not weaken the guard or substitute a device name.
