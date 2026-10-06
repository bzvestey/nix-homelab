# Raspberry Pi 5 bootstrap images

Both host-specific AArch64 images use the pinned `nixos-hardware.nixosModules.raspberry-pi-5` profile and nixpkgs' pinned `sd-image-aarch64.nix`: Raspberry Pi firmware loads U-Boot, which loads the generic extlinux configuration. Build them only on native ARM64 Linux:

```console
nix build .#images.hl-node-00
nix build .#images.hl-node-01
```

Pi 5 stores its firmware in EEPROM and does not use the external `start*.elf`
or `fixup*.dat` variants required by older models. The shared Pi 5 module omits
only those files while retaining device trees, overlays, and `bootcode.bin`.
New bootstrap images allocate 128 MiB to the firmware partition. This does not
resize an already-flashed installation; the managed activation can remediate
an existing 30 MiB partition by removing stale Pi firmware immediately before
installing the managed files. If an update was interrupted, do not reboot until
activation succeeds.

The observability Pi first boot established `end0` at `2c:cf:67:72:a7:20`, so its normal configuration now matches that exact interface/MAC and enables comin. `hl-node-01` uses its recorded `end0` MAC and has **no data-disk formatter**. Both addresses are on the intended VLAN 4 untagged access-port segment; do not add an 802.1Q interface or describe LLDP as advertising VLAN membership until switch ports are confirmed and coordinated as trunks.

## Observability telemetry SSD

The `hl-node-00` observability image and the `initialize-telemetry-ssd` package output contain the same initializer. It pins `/dev/disk/by-id/ata-Samsung_SSD_970_EVO_Plus_2TB_S6S2NS0W226715A`, model `Samsung SSD 970 EVO Plus 2TB`, serial `S6S2NS0W226715A`, and exactly 3,907,029,168 512-byte sectors (2,000,398,934,016 bytes). The `hl-node-01` identity remains unresolved and that image has no data-disk formatter. The ATA by-id is preferred over the observed USB bridge ID because it binds the physical SSD rather than the enclosure. Zero matches, multiple matches, any tuple mismatch, unresolved identity, or incorrect hostname stop before `mkfs`; the initializer repeats the full guard at the format boundary.

Read-only inspection on 2026-10-06 found the SSD unmounted on a powered USB 3/UAS path, with SMART overall passed, 0 critical warning, 37 C, 100% spare, 0% used, and no media/data-integrity or logged errors. It still contains about 826 GB of old data in Windows recovery, Microsoft data, and EFI partitions. The pinned identity does **not** authorize erasure: obtain separate explicit destructive approval immediately before running the initializer, review the old-data warning, and type both interactive confirmations. Do not pipe confirmations, weaken the guard, substitute a device name, or use mutable partition identifiers.
