# Canonical Node Identities Design

## Context

The fleet currently identifies machines by hardware or workload names such as
`observability-pi` and `framework-01`. Those names make hardware replacement
and role movement unnecessarily invasive because machine identity, hardware
facts, service placement, deployment targets, and telemetry labels are mixed
together.

The fleet needs stable, generic node identities. Hardware and service roles
must be independently replaceable or movable without renaming a machine.

## Goals

- Give every machine a hostname matching `hl-node-[0-9]{2}`.
- Preserve each node's current static IP when hardware or roles change.
- Separate stable node facts from movable role assignments.
- Give movable services role-based aliases that follow their assigned node.
- Remove operational dependencies on the legacy hardware- and role-based
  hostnames.
- Migrate the deployed observability node without rotating its SSH host key or
  age recipient and without weakening Comin signature enforcement.

## Non-goals

- Renumbering static IPs.
- Moving any service role during this change.
- Rotating SSH host keys, age recipients, or encrypted credentials.
- Initializing the telemetry SSD before a powered USB 3 hub is available.
- Introducing host-side 802.1Q tagging; VLAN 4 remains an untagged access-port
  segment.
- Building a separate physical-asset registry. Hardware facts remain attached
  to a node and can be replaced in place.

## Canonical mapping

| Canonical node | Previous identity | Static IP | Initial role |
|---|---|---:|---|
| `hl-node-00` | observability Raspberry Pi | `10.15.4.6` | observability |
| `hl-node-01` | services Raspberry Pi | `10.15.4.4` | lightweight services |
| `hl-node-02` | Framework 01 | `10.15.4.5` | Framework workload 1 |
| `hl-node-03` | Framework 02 | `10.15.4.7` | Framework workload 2 |
| `hl-node-04` | Framework 03 | `10.15.4.9` | Framework workload 3 |

The canonical node ID is the hostname, NixOS configuration output name,
installer target, image output name, Comin machine identity, per-node testing
branch suffix, telemetry `host.name`, SOPS policy label, host directory name,
and documentation identity.

## Configuration model

A single canonical node registry is keyed by `hl-node-00` through
`hl-node-04`. Each entry owns stable machine-level data:

- Nix system architecture;
- static address;
- NIC names and MAC addresses;
- installation-disk identity and geometry;
- hardware-specific modules and facts; and
- image/installer type.

A separate role-assignment map associates roles with canonical node IDs. Role
modules are selected from this map rather than inferred from a hostname or
hardware class. The initial assignments preserve all current placement.

The flake derives NixOS configurations and image outputs from these two
sources. Host-specific files may remain when they contain genuinely unique
machine configuration, but their paths and identities use canonical node IDs;
role configuration remains under role modules.

Registry validation rejects:

- a node ID outside `hl-node-[0-9]{2}`;
- missing or duplicate canonical IDs;
- duplicate static IPs;
- duplicate NIC identities where uniqueness is required;
- a role assigned to an unknown node; and
- duplicate singleton-role assignments or alias collisions.

## Role aliases

Movable services use role aliases rather than node hostnames. The observability
gateway is addressed as `observability`, initially resolving to `10.15.4.6`.
The role-assignment map generates deterministic `/etc/hosts` entries on every
fleet node so internal service discovery does not depend on DHCP registration
or router DNS.

Aliases identify services, not machines. The old machine names are not kept as
compatibility aliases. External clients that need a role alias must receive an
equivalent DNS record through their owning network system in a later,
explicitly managed change; this repository does not silently mutate external
DNS.

When a role moves, its alias target and role assignment change together. Node
hostnames and static IPs do not change.

## Secrets and deployment identity

Renaming a node does not change its cryptographic identity. The deployed
`hl-node-00` retains its existing SSH host keys and age recipient. SOPS anchor
and path labels change to the canonical node ID, while recipient bytes remain
identical. Encrypted files are rewrapped only if SOPS metadata actually needs
to change; plaintext secret values are never printed or committed.

Comin continues to track signed `main` from the bootstrap GitHub remote and
retains strict SSH signature verification. Its machine identity and testing
branch become canonical-node based. Existing Comin deployment history may
remain as historical state, but the first canonical deployment must accept the
same signed revision format and report the canonical node identity.

## Live migration of `hl-node-00`

The rename is delivered as one coordinated, signed revision after tests and
independent review. The migration sequence is:

1. Build the exact `hl-node-00` closure without activation.
2. Verify its hostname, static network, role aliases, SOPS recipient, Comin
   policy, telemetry revision, and fail-closed observability storage settings.
3. Activate the pinned `hl-node-00` output explicitly over strict SSH.
4. Confirm the unchanged IP, MAC, SSH fingerprint, decrypted credential file,
   Comin acceptance, OTel agent, Cloudflare connector, boot configuration, and
   absence of failed units.
5. Reboot and repeat acceptance against the booted generation.

The prior boot generation remains the rollback path and may show the previous
hostname when selected. That historical rollback identity is not an active
configuration or compatibility alias.

The telemetry SSD remains absent and observability backends must continue to
skip cleanly through their mount-point conditions. SSD identity capture,
formatting, quota setup, and backend acceptance resume only after safe powered
USB storage is available.

## Validation

Automated checks must prove:

- the exact canonical node set is `hl-node-00` through `hl-node-04`;
- every evaluated hostname equals its configuration attribute name;
- current architecture, static IP, NIC, disk, and role placement survive the
  mapping exactly;
- every NixOS configuration and installer/image output uses a canonical ID;
- role aliases resolve to their assigned nodes and no alias collides;
- telemetry exports canonical `host.name` values and uses role aliases for
  service endpoints;
- Comin uses canonical machine/testing identities while retaining signed-main
  enforcement;
- SOPS rules grant the unchanged recipients only their intended canonical
  host and role scopes;
- operational configuration and current runbooks do not depend on legacy
  hostnames;
- both Pi closures evaluate/build natively and all Framework closures
  evaluate/build on x86; and
- missing telemetry storage, missing secrets, ambiguous hardware, and unsafe
  installation targets still fail closed.

Physical acceptance for `hl-node-00` must verify after reboot:

- hostname `hl-node-00`;
- address `10.15.4.6/24`, wired MAC `2c:cf:67:72:a7:20`, and gateway
  `10.15.4.1`;
- unchanged strict SSH fingerprint;
- active SOPS, Comin, OTel agent, and Cloudflare connector behavior;
- signed Comin polling of the deployed revision;
- no failed units; and
- inactive observability backends with no telemetry mount while the powered
  hub is unavailable.

Historical telemetry carrying old host labels remains immutable history. New
signals start a new canonical host-label series; no historical rewrite is
attempted.
