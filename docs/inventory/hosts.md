# Sanitized host inventory

Captured read-only on 2026-10-02. Private addresses and MAC addresses are not published here.

| Target | Current node | Architecture | CPU | RAM | Local capacity/free | Stable install disk | Intended NIC | GPU |
|---|---|---:|---:|---:|---:|---|---|---|
| framework-01 | worker 1 | x86_64 | 8 | 31.1 GiB | 1.95 TB / 1.80 TB | **BLOCKED**: exact model/serial | `bond0` over four USB NICs; **BLOCKED**: MACs | **BLOCKED**: PCI ID |
| framework-02 | worker 2 | x86_64 | 20 | 31.0 GiB | 975 GB / 898 GB | **BLOCKED**: exact model/serial | `bond0` over two USB NICs; **BLOCKED**: MACs | **BLOCKED**: PCI ID |
| framework-03 | worker 3 | x86_64 | 8 | 31.1 GiB | 975 GB / 898 GB | **BLOCKED**: exact model/serial | `bond0` over two USB NICs; **BLOCKED**: MACs | **BLOCKED**: PCI ID |
| services-pi | control-plane Pi 8 | aarch64 | 4 | 15.7 GiB | 248 GB / 228 GB | current system disk identity **BLOCKED** | **BLOCKED**: interface/MAC | none expected; not asserted |
| observability-pi | not online | aarch64 | **BLOCKED** | **BLOCKED** | telemetry SSD **BLOCKED** | telemetry SSD model/serial/capacity **BLOCKED** | **BLOCKED** | none expected; not asserted |

Kubernetes Node status supplied CPU, memory, architecture, and ephemeral-storage capacity. The source Talos template identifies `/dev/nvme0n1` as the worker install path and the bond members, but a path is not a stable disk identity. A read-only `talosctl get disks` attempt against all four nodes failed because TCP/50000 was unreachable from the discovery host. Therefore model, serial, NIC MAC, GPU PCI ID, and the offline Pi telemetry SSD are deliberately not invented. Before any installation, collect `lsblk --json -o NAME,PATH,MODEL,SERIAL,SIZE`, `/sys/class/net/*/address`, and `lspci -nn` from a trusted maintenance environment and replace every BLOCKED value.
