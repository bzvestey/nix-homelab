# Sanitized host inventory

Captured read-only through 2026-10-03. Approved management addresses are operational, non-secret facts and are retained. All hosts are intended for VLAN 4 on untagged access ports; no 802.1Q host interface or LLDP VLAN-membership claim is configured without confirmed, coordinated switch trunks.

| Target | Address | Architecture | Observed source facts | Installation blockers |
|---|---|---|---|---|
| `hl-node-02` | `10.15.4.5` | x86_64 | worker 1; 8 CPU; 31.1 GiB RAM; NIC members `enp0s13f0u1`, `enp0s13f0u2` at `9c:bf:0d:00:23:fe`; Samsung SSD 970 EVO Plus 2TB, serial `S59CNM0W713317D`, 2,000,398,934,016 bytes; GPU `0000:00:02.0` `8086:9a49` | verified `/dev/disk/by-id` install path, measured destination free bytes |
| `hl-node-03` | `10.15.4.7` | x86_64 | worker 2; 20 CPU; 31.0 GiB RAM; NIC members `enp0s13f0u3`, `enp0s13f0u4` at `9c:bf:0d:00:0d:3c`; Samsung SSD 980 1TB, serial `S64ANS0RB36721W`, 1,000,204,886,016 bytes; GPU `0000:00:02.0` `8086:4626` | verified `/dev/disk/by-id` install path, measured destination free bytes |
| `hl-node-04` | `10.15.4.9` | x86_64 | worker 3; 8 CPU; 31.1 GiB RAM; NIC members `enp0s13f0u3`, `enp0s13f0u4` at `9c:bf:0d:00:20:37`; Samsung SSD 980 1TB, serial `S64ANL0T801753P`, 1,000,204,886,016 bytes; GPU `0000:00:02.0` `8086:9a49` | verified `/dev/disk/by-id` install path, measured destination free bytes |
| `hl-node-01` | `10.15.4.4` | aarch64 | current control-plane Pi 8; 4 CPU; 15.7 GiB RAM; `end0` at `2c:cf:67:ed:27:ed`; `mmcblk0` GE4S5, serial `0x3a0a638a`, CID `1b534d4745345335303a0a638aa16a00`, 256,355,860,480 bytes | stable installer identity requirements, measured destination free bytes |
| `hl-node-00` | `10.15.4.6` | aarch64 | booted at `10.15.4.6/24` through `10.15.4.1`; wired `end0` at `2c:cf:67:72:a7:20`; Wi-Fi `wld0` at `2c:cf:67:72:a7:21` is down; boot card `/dev/mmcblk0`, 128,177,930,240 bytes, stable ID `/dev/disk/by-id/mmc-ED2S5_0xb13669d3`; VLAN 4 is the intended untagged access-port segment | powered USB 3 hub; separate >=2 TB telemetry SSD model/serial/WWN/capacity and measured destination free bytes; host tagging deferred until switch trunk coordination |

The 2026-10-02 hardware observations came read-only through existing kube-proxy containers' host `/sys` mounts; no cluster resource was created or modified. Source references retain only the Kubernetes node and sysfs file class, not raw output or credentials. `/dev/disk/by-id` was not exposed, so Framework install disks remain blocked despite retaining safe model, serial, and capacity facts for installer preflight. The Services Pi disk also remains blocked because stable installer identity requirements are incomplete.

The observability boot-media candidate was observed directly on the migration
controller with `lsblk`. Its 128,177,930,240-byte capacity is below the decimal
2 TB telemetry minimum, so it is explicitly rejected as telemetry storage. It
may be flashed only after the complete immediate boot-media revalidation in
`wave-1-hl-node-00.md`; this observation is not flash evidence.

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

Every target declares whether install-disk, NIC, and GPU evidence is required or optional, and all three fact slots are mandatory even when optional. The Pi GPU slots are explicitly `optional` with an observed `not-required` role declaration; Framework GPU identities remain required blockers. Observed facts require a stable ID, an ISO date, and a typed evidence source.
