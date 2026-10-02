# Sanitized host inventory

Captured read-only on 2026-10-02. Approved management addresses are operational, non-secret facts and are retained.

| Target | Address | Architecture | Observed source facts | Installation blockers |
|---|---|---|---|---|
| `framework-01` | `10.15.4.5` | x86_64 | worker 1; 8 CPU; 31.1 GiB RAM; `bond0` declared over four USB NICs; install path `/dev/nvme0n1` | stable disk model/serial/WWN, member interface/MAC map, GPU PCI ID, measured destination free bytes |
| `framework-02` | `10.15.4.7` | x86_64 | worker 2; 20 CPU; 31.0 GiB RAM; `bond0` declared over two USB NICs; install path `/dev/nvme0n1` | stable disk model/serial/WWN, member interface/MAC map, GPU PCI ID, measured destination free bytes |
| `framework-03` | `10.15.4.9` | x86_64 | worker 3; 8 CPU; 31.1 GiB RAM; `bond0` declared over two USB NICs; install path `/dev/nvme0n1` | stable disk model/serial/WWN, member interface/MAC map, GPU PCI ID, measured destination free bytes |
| `services-pi` | `10.15.4.4` | aarch64 | current control-plane Pi 8; 4 CPU; 15.7 GiB RAM | stable system-disk identity, interface/MAC map, measured destination free bytes |
| `observability-pi` | `10.15.4.6` | aarch64 | approved address and role; host not online | telemetry SSD model/serial/WWN/capacity, interface/MAC map, measured destination free bytes |

Kubernetes Node capacity and allocatable ephemeral storage are **not** filesystem free-space measurements and are not accepted by the readiness gate. A device path is not a stable installer identity. A read-only `talosctl get disks` attempt failed because TCP/50000 was unreachable, so no missing identity was inferred.

Run the following on each machine from a trusted maintenance environment and transfer only the listed non-secret facts:

```sh
lsblk --json -b -o NAME,PATH,MODEL,SERIAL,WWN,SIZE,TYPE,MOUNTPOINTS
for i in /sys/class/net/*; do printf '%s ' "$(basename "$i")"; cat "$i/address"; done
ip -br link
ip -d link show bond0 2>/dev/null || true
ip route
lspci -Dnn | grep -Ei 'vga|3d|display' || true
findmnt -bno SOURCE,TARGET,FSTYPE,AVAIL / /var/lib /var/lib/telemetry 2>/dev/null
df -B1 --output=source,target,avail / /var/lib /var/lib/telemetry 2>/dev/null
```

Match the mounted destination filesystem to the stable `lsblk` identity before recording free bytes. The machine-readable typed blockers and per-fact commands are in `services.md`.
