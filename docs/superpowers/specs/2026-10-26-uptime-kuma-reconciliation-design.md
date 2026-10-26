# Managed Uptime Kuma reconciliation

## Status and outcome

The operator approved a dedicated reconciler on hl-node-00, managed fleet nodes,
domain groups, existing-ID adoption, and a separate local proxy-trust correction.
This spec is for review before implementation planning. It does not authorize
publication, deployment, application restarts, credentials provisioning or Kuma
writes. The reconciler itself is not implemented by this document.

Keep Kuma's service list current from the enabled Nix configuration while keeping
Kuma on HAOS as an independent availability observer. New admitted fleet nodes and
new service routes must not require copying their addresses into a second list.
Preserve monitor IDs, history, existing check settings and notification choices.
Do not collect entity/sensor states or extend the telemetry collector's privileges.

## Observed baseline and separate prerequisite fix

HAOS runs community app 0.19.4, packaging Kuma 2.5.6. Its authenticated metrics
export currently contains 10 application checks, five node pings, four groups and
two NAS checks. This is not the full configured inventory: paused/unexported
monitors and actual parent relationships require authenticated management reads.

The repository has 23 selected web-service targets after excluding PDS wildcard
and duplicate aliases. Ten match current checks; 13 are proposed additions.
Optional SMTP/SSH/Deluge RPC checks are not selected for this first implementation.

Prowlarr, Radarr and Sonarr accept HTTPS but redirect to HTTP login pages. The
unserved HTTP port, not their initial HTTPS listener, produces connection refusal.
Their exact installed releases support `<APP>__SERVER__TRUSTEDNETWORKS`.
The separate local fix sets only `10.88.0.1/32`, their observed Podman gateway;
it preserves loopback-only port publication, image pins and authentication.
Live redirect-chain acceptance remains blocked until deployment/restart approval.
Do not hide that defect by accepting redirects without following them, opening
port 80, disabling TLS verification, or silently checking only the login page.

## Architecture and alternatives

Recommended: a small Python reconciliation package, one central Nix module, and a
serialized systemd oneshot/timer on hl-node-00. Generate a non-secret desired
manifest from evaluated fleet configuration; read/write Kuma through its
authenticated Socket.IO interface over Tailscale. No direct database access,
Supervisor credential, Docker socket or SSH is required by the runtime job.

Direct database edits bypass application invariants and are rejected. A separate
Terraform/provider stack would add state/tooling without removing dependence on
Kuma's internal API; do not introduce it for this scope. Manual exports remain
useful for review but cannot provide ongoing reconciliation.

Kuma's internal management API is not a stable third-party contract. Package a
locked Socket.IO client compatible with the installed server and test the actual
management event/payload contract against Kuma 2.5.6. Gate unsupported server
versions before writes; upgrades require compatibility acceptance rather than
blind retries. Dependency locks and this runtime version gate are both required.

## Desired inventory and grouping

The flake passes the authoritative `fleetTopology.nodes` and each host's evaluated
`fleet.ingress.routes` into the module. Do not independently evaluate a checkout or
fetch the repository at runtime. The desired manifest belongs to the deployed
Nix closure, with an inventory digest for planning and diagnostics.

- Nodes: stable key `node:<node-id>`, ping the topology's LAN address, display the
  canonical node ID, parent group `nix-homelab`. Include every configured node.
  The existing topology's exact-five-node validation is unchanged here; fleet
  expansion must update that constraint before a sixth node can be evaluated.
- Sites: default stable key `site:<hostname>` and HTTPS root URL from the enabled
  ingress route. A small override map supplies display names, health paths,
  alias exclusions and explicit stable-key continuity for a hostname rename.
  Do not infer a renamed service solely from display name or upstream port.
- Exclude literal wildcard routes and the currently reviewed PDS/Deluge duplicate
  endpoints. Optional non-HTTP proxies remain out of scope unless selected later.
- Group sites by the longest dot-delimited match in configured domain zones:
  `tailbc181.ts.net`, `minastas.xyz`, `minastas.social`. Never derive `ts.net` as
  the tailnet's group. An unknown zone fails inventory validation until explicitly
  configured; a new configured zone generates one desired group before children.
- Keep existing group nesting. Manage intended child membership only; never edit
  unmanaged children simply because they share a managed group.

Current approved adoption candidates:

| Kind | Stable identity | Existing ID |
| --- | --- | --- |
| Group | nix-homelab | 5 |
| Group | tailbc181.ts.net | 19 |
| Group | minastas.xyz | 20 |
| Group | minastas.social | 21 |
| Node | hl-node-00 / 01 / 02 / 03 / 04 | 15 / 6 / 7 / 11 / 13 |
| Site | Foundry / Pocket ID / Matrix | 1 / 10 / 14 |
| Site | Kavita / Publication Manager / Tranquil PDS | 17 / 18 / 22 |
| Site | Tangled Knot / Donetick / Forgejo / Jellyfin | 23 / 24 / 25 / 26 |

Verify IDs, types and normalized targets in the complete management inventory
before adopting. For HTTP identity, normalize only hostname case, default port
and empty root path; preserve scheme, non-root path and query. Group identity
also requires the expected name/type and no ambiguous duplicate. Node identity
requires the canonical name, ping type and exact expected topology address.
Current NAS IDs 8 and 12 remain unmanaged. Final desired child counts are five
node pings, 18 tailnet sites, three minastas.xyz sites and two minastas.social sites.

## Ownership, diff and failure behavior

Keep a private persistent mapping of stable keys to adopted/created Kuma IDs in
`/var/lib/kuma-reconciler/`, with atomic writes and a single-writer lock. Initial
adoptions are explicit reviewed mappings, not automatic name/URL takeovers.
Do not add Kuma tags for ownership: that needlessly changes the metrics tag schema.
Do not use the filtered telemetry export as management inventory or ownership.

Each invocation validates the desired manifest, authenticates, waits for the full
monitor inventory, checks server compatibility and builds a deterministic diff.
Validate all identity conflicts before the first write. A monitor with matching
target but no ownership/adoption record blocks creation for review, including a
paused manual monitor. Missing owned IDs also block rather than silently recreating
objects with lost history. Group creation precedes child creation.

New checks use the reviewed defaults: 60s interval, 10s request timeout, two retries
with 30s retry interval, verified TLS and up to ten redirects for HTTP, accepting
200–299. New checks receive an explicitly approved notification policy; the initial
policy must be configured before apply is enabled. Future automatic additions use
that policy without another per-node approval. Existing notification assignments,
check settings, pause/maintenance state and status pages are preserved.

For owned existing objects, update only changed desired identity targets/display
names and intended parent membership. Adopting an object alone does not reset it
to new-check defaults. Health-path improvements for existing Matrix/PDS monitors
remain opt-in overrides, not an automatic part of adoption. Removals are reported;
there is no deletion, pause/resume, or garbage-collection action.

Before each write, re-read the affected object and compare the planning baseline.
Abort on concurrent change rather than overwrite it. Stop on the first failed or
ambiguous mutation, retaining acknowledgements already recorded; there is no
destructive rollback. Bound connection/ack deadlines and the overall run. Never
blindly retry creation after a lost acknowledgement: re-read inventory and record
the unresolved intent for review if ownership cannot be proven. Persist creation
intent before sending and confirmed IDs atomically after acknowledgement. A crash
between remote success and local persistence must not produce a duplicate on retry.

Kuma does not provide a verified compare-and-swap contract. Re-reading detects
baseline drift but cannot eliminate edits in the final read/write gap. Bootstrap
requires an operator-agreed edit-free window. During ongoing operation, the
declared target/name/parent fields are controller-owned; manual edits to other
fields should occur outside the short apply window. Document this limitation,
rather than claiming atomic protection against arbitrary concurrent UI writes.

Do not clear Kuma pause/maintenance state during later runs. Writes of a complete
monitor object must merge the latest unmanaged fields, not construct a replacement
from incomplete defaults. Contract tests must cover this internal-API hazard.

## Modes, scheduling and security

The Nix module is disabled by default and defaults to dry-run when enabled.
Dry-run performs authenticated reads and emits the diff without remote writes or
ownership claims. Apply requires a separate explicit configuration choice. An
approved initial plan includes the inventory digest and reviewed adoption map;
refuse it if either the inventory or relevant live objects have changed.

After initial acceptance and authorization of ongoing reconciliation, run the
oneshot after boot and every five minutes; the next run naturally uses any newly
activated closure. A systemd lock prevents overlapping manual/timer runs. Subsequent
inventory-driven additions are automatic only within the approved ownership,
domain and notification policy. No deployment workflow waits for or depends on
Kuma availability; reconciliation failure must not roll back a deployment.

Use a dedicated service user, private state directory, bounded runtime and memory,
and only required network/state access. Load management authentication through
runtime SOPS/systemd credentials, never the Nix store, argv, telemetry collector
options, committed files, logs or the read-only metrics key. Kuma management access
is powerful and is not assumed to have granular read/write scopes. Validate its
HTTPS certificate and constrain the endpoint to the configured Kuma origin.
Do not persist login sessions unless necessary; any session state is credential
material with the same protection. Never disable MFA or modify Kuma auth settings
to make unattended login work; resolve the supported credential flow privately
before activation. Report authentication failure without dumping API payloads.

Current diagnostic access uses HTTP within HAOS; an externally reachable HTTPS
management origin has not been established. Provisioning that origin and the
management credential are explicit rollout prerequisites, not assumed existing
facilities. Do not install an enabled job or fall back to plaintext management
traffic to work around either missing prerequisite.

Emit bounded counts, stable operation keys and failure categories in journald;
never full monitor objects, URLs with credentials, notification payloads or tokens.
Failed runs integrate with the existing failed-systemd-unit monitoring. Do not add
an HTTP management listener, extra dashboard, or broad new metrics subsystem.

## Verification and rollout gates

1. Validate manifest generation from evaluated enabled/disabled hosts, node
   addition/address changes, service overrides and explicit alias exclusions.
   Exercise a newly admitted synthetic node without modifying production topology.
2. Test dry-run makes no writes, repeated apply is idempotent, stable IDs/history
   survive updates, correct domain boundaries/group creation order, and preservation
   of unmanaged monitors, notifications, pause state and group children.
3. Cover paused collisions, duplicate names/targets, missing owned IDs, incompatible
   versions, concurrent edits, timeout/lost acknowledgement and restart recovery.
   Use the real pinned Kuma server for event/payload and persistence acceptance,
   including creation after a simulated ambiguous response; mocks alone are not
   sufficient to establish this unsupported API contract.
4. Review the initial full-inventory dry-run before any write. Provision management
   credentials privately only when needed. Check reachability in Kuma's own network
   context during live acceptance; an SSH-add-on probe is not equivalent.
5. Separately authorize publication/deployment of the proxy fix, then confirm each
   original HTTPS root URL follows only HTTPS redirects and reaches its login page
   without losing authentication protection. Inspect actual generated environment
   and reject broader trusted ranges or public port publication.
6. Separately authorize reconciler installation and the exact bootstrap apply.
   Verify existing IDs/settings/history and groups remain intact, new monitors
   actually report heartbeats, metrics collection stays healthy, and a second
   reconciliation produces no further changes. Only then enable unattended apply.

Rollback disables the reconciler timer/apply mode without deleting checks or
history. Restore its ownership state only from a verified backup and revalidate
IDs before enabling it again. Reverting the proxy-trust setting is a separate
deployment that may restore the known redirect defect; do not silently combine it
with reconciler rollback.
