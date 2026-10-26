# Uptime Kuma reconciliation

## Status and authority

The reconciler is **disabled** on hl-node-00. No production HTTPS management
origin or management credential is provisioned by this change. Commands below
are procedures for separately authorized work, not authorization to execute it.
See the [design](../superpowers/specs/2026-10-26-uptime-kuma-reconciliation-design.md)
for the reviewed identities and safety requirements.

Only Kuma **2.5.6** is supported. The locked client uses the internal authenticated
Socket.IO API, not a stable public API. Accept new versions against a real server
before upgrading; a version refusal is not a reason to bypass the gate.
The observer remains Kuma on HAOS; the job runs centrally on hl-node-00.

## Separate delivery gates

Keep each approval/evidence record distinct:

1. **Proxy-trust fix publication and deployment/restart:** the local Prowlarr,
   Radarr and Sonarr fix trusts only the observed Podman gateway `10.88.0.1/32`.
   Inspect the generated environment for the exact installed releases; retain
   pinned images, authentication and loopback-only port publication. After an
   approved deployment, follow each original HTTPS root URL through its entire
   redirect chain from Kuma's actual network context: all hops must remain HTTPS
   and reach the protected login page. An SSH add-on probe is not equivalent.
   Do not open port 80, broaden trust, disable TLS verification or accept a broken
   redirect chain. Reverting this fix is a separate deployment and may restore
   the known defect; it is not reconciler rollback.
2. **Management HTTPS exposure:** agree and provision an exact private HTTPS
   origin reachable from hl-node-00, including WebSocket upgrade support and a
   verified certificate. There is no documented existing live endpoint to reuse.
   Do not fall back to diagnostic HTTP inside HAOS, public forwarding or Funnel.
3. **Private credential provisioning:** privately establish a supported login
   flow and runtime secret delivery as below. Do not weaken Kuma authentication.
4. **Dry-run installation:** only after 2–3 and architecture acceptance, authorize
   a reviewed Nix configuration with `enable = true`, `mode = "dry-run"`.
   This installs authenticated readers, not bootstrap or ongoing write approval.
5. **Exact bootstrap writes:** approve the full management inventory, explicit
   adoptions, notification policy and exact fresh plan in an edit-free window.
   Starting the manual bootstrap service is an independent write authorization.
6. **Production acceptance, then ongoing apply:** verify original IDs, history,
   settings, notifications, pause/maintenance state, group nesting and unmanaged
   checks; confirm every new monitor's actual heartbeat from Kuma's context,
   healthy filtered metrics collection, and a subsequent no-op. Only then approve
   `mode = "apply"` and unattended writes. ARM evaluation is not ARM execution:
   hl-node-00 needs authorized native ARM runtime/host acceptance before enablement.

Local pinned-server fixtures establish API and failure contracts, not production
reachability, notification delivery, real credentials or complete live inventory.
Do not make deployment success depend on Kuma availability.

## Configuration, identity and secrets

Options live under `fleet.observability.kumaReconciler` in
`modules/fleet/kuma-reconciler.nix`. Defaults are `enable = false`,
`mode = "dry-run"`, `endpoint = null`, `credentialFile = null`, and
`notificationPolicy = null`. Enabling requires an exact `https://host[:port]`
origin, without path, userinfo, query or fragment, and an absolute private runtime
credential path. The path must not be in `/nix/store`, contain whitespace, `..`
components or systemd `%` specifiers. Provision it through approved private
SOPS/runtime delivery; this change declares no secret. Keep its source root-only
(0600); systemd loads it as `management.json` in each service's credential mount.

Credential JSON contains `origin` matching the canonical endpoint origin, and **either**
`loginToken` **or** `username` plus `password`, never both forms. Optional `caFile`
is the path to a trusted CA bundle; otherwise system trust is used. Certificate
validation cannot be disabled. A private CA bundle must be readable by the
dedicated service UID inside its sandbox, outside protected homes/private root
directories. No proxy-environment inheritance or cross-origin redirects are used.

Canonical origins use HTTPS, lowercase hostname, no trailing slash and omit
default port 443; nondefault ports remain significant (IPv6 uses brackets).
The client derives the snapshot's `origin` from the configured endpoint after
credential/TLS/version verification, not server-reported metadata. Plans and
ownership use **schemaVersion 2**, with required `origin`; the desired inventory
and independent `mutation.pending` marker remain schemaVersion 1. Exact approval
includes origin and origin-bound live/state digests. Every ID claim and mutation
requires the same origin as persistent ownership/bootstrap policy. Credentials
can be rotated at that same origin without changing ownership or reapproval.

A different management origin is a different ownership namespace even if IDs,
names or credentials overlap. Legacy unbound ownership (including empty saved
state), null origin, and foreign-origin state fail closed; a missing state file
alone supplies a pristine in-memory unbound bootstrap state, never ongoing
authorization. Do not edit the origin, delete state/barriers, or rerun bootstrap
to bypass a mismatch. Stop invocation, retain the full private state/approval
evidence and obtain an explicit reviewed migration and fresh exact approval.
Prove the destination objects' identities/history and review mappings/policy
under the common lock before any separately authorized state migration. There
is no automatic migration/reset/bypass command. No live migration is required
for this disabled, never-provisioned implementation. Origin binding cannot
detect a replaced database served at the same origin; validate provenance on
restores/replacements rather than treating origin as a stable server UUID.

For MFA accounts, privately obtain/rotate a supported login token using the
approved authenticated flow; the unattended password flow does not submit an MFA
challenge response. Do not disable MFA, change auth settings, reuse a metrics key
or use Supervisor credentials. Token expiry/revocation is an operational failure
requiring private renewal, not blind retries. The client does not persist sessions.

Management credentials are powerful, not assumed read-only even in dry-run.
Never put raw credentials in Nix options/store, argv, environment, Git, plans,
logs, telemetry or shell history. Do not paste full monitor or notification
payloads into tickets. `desired`, overrides, adoptions and notification options
are non-secret configuration in the closure; do not hide secrets in them.

Apply requires the explicitly approved shape
`notificationPolicy = { notificationIDList = { "123" = true; }; };`, where
`123` is illustrative, not an approved real notification ID. Keys must be positive
decimal IDs and values booleans. An explicitly reviewed empty map is permitted;
`null` is not approval. Verify actual delivery separately. Existing assignments
are preserved, not replaced by this creation-only policy.

## Desired inventory versus full management inventory

The flake projects `fleetTopology.nodes` LAN addresses and evaluated enabled
`fleet.ingress.routes` into a non-secret, digested schemaVersion 1 manifest in the
deployed closure. Runtime never evaluates a checkout or fetches a repository.
Current desired inventory is five pings and 23 sites: 18 under
`tailbc181.ts.net`, three under `minastas.xyz`, two under `minastas.social`, plus
the four groups including `nix-homelab`. Preserve current group nesting.

Metrics originally showed only ten application checks, five pings, four groups
and two NAS checks. Metrics omit paused/unexported objects and do not prove parent
relationships or ownership. Review the **complete authenticated management
inventory**, including paused checks, before adoption. The CLI deliberately emits
bounded summaries, not a full inventory dump; inspect full objects privately in
the authenticated management UI and compare the private plan. NAS IDs 8 and 12
remain unmanaged. Never infer ownership from metrics, tags, names or targets.

`lib/kuma-inventory.nix` contains explicit bootstrap adoption anchors; confirm
their IDs/types/normalized targets against live management data rather than
treating old observations as proof. Overrides/adoptions merge with these defaults;
review the evaluated manifest, not just your override fragment. An unowned
matching target (even paused), duplicate group/name/target or missing owned ID
blocks writes. Resolve ambiguity by explicit reviewed adoption, not takeover.
From the reviewed checkout, inspect its proposed non-secret manifest with
`nix eval --json .#nixosConfigurations.hl-node-00.config.fleet.observability.kumaReconciler.desired`.
For an installed plan, use the exact `--desired` file in that unit's ExecStart:
the checkout might not match the active closure.
Missing-owned-ID recovery requires proving the replacement object's identity and
history, then reviewing the ownership mapping and adoption policy together; merely
adding an adoption option does not override a missing ID already in ownership.
If provenance cannot be proven, leave reconciliation blocked.

New nodes derive canonical `node:<node-id>` keys, names and LAN pings from topology
under `nix-homelab`. Admission must first deliberately update the existing
exact-five topology constraint; this work does not relax it. New sites derive
`site:<hostname>` and HTTPS roots from enabled routes. Wildcards and the reviewed
PDS/Deluge duplicate aliases are excluded; SMTP/SSH/Deluge RPC are out of scope.
Overrides can specify display name, health path, exclusion and explicit stable-key
continuity for a hostname rename; do not infer continuity from name or port.
Existing Matrix/PDS health-path changes remain opt-in.

Domain assignment uses longest dot-delimited matching, never substring matching
or a catch-all `ts.net` group. Unknown/lookalike domains fail validation. Under
ongoing approval, additions are allowed only within the accepted groups, node
parent policy, adoptions and creation/notification policy. New configured domains,
changed adoptions or policy require a new reviewed plan/bootstrap authorization,
not automatic policy expansion. Groups are created before children.

Only new checks receive 60s interval, 10s timeout, two retries at 30s; new HTTP
checks use GET, verified TLS, at most ten redirects and accepted 200–299. Existing
checks retain their settings. Owned identity/name/target/intended parent can be
updated while preserving IDs/history, unmanaged fields, notifications and pause
state. Removed desired objects are reported only: **no delete, pause, resume,
garbage collection or destructive rollback**. Unmanaged children remain untouched.

## Plan, exact bootstrap and ongoing operation

Use the installed manual systemd units, not a root CLI with differently owned
state. All three services execute as `kuma-reconciler`, with the same credential
mechanism and flock on `/var/lib/kuma-reconciler/lock`. State directory is 0700;
ownership and barrier files are private. The separate private
`/var/lib/kuma-reconciler-review/plan.json` is review output, **not** ownership.
Plan output inside the state directory is rejected.

After separately approved dry-run installation, inspect actual commands:

```sh
sudo systemctl cat kuma-reconciler.service kuma-reconciler-plan.service kuma-reconciler-bootstrap.service
sudo systemctl status kuma-reconciler.timer
sudo systemctl start kuma-reconciler-plan.service
sudo cat /var/lib/kuma-reconciler-review/plan.json
sudo journalctl -u kuma-reconciler-plan.service --no-pager
```

Review that file privately; it contains management-derived baselines. Check
`valid`, `origin`, conflicts, removals, operations and digests together with the exact
desired manifest's explicit adoption map and every ID/parent/target against the
full inventory. A failed plan start may leave an old
output file: never approve it without a successful fresh invocation. Planning
makes no remote writes or ownership claims. It may refuse to run while a recovery
barrier exists. CLI exit 0 is valid/success, 2 is invalid plan/manifest or version
refusal, and 1 is runtime/auth/lock/state/transport failure; consult the bounded
category, not raw upstream payloads.

After exact-plan approval and an agreed edit-free window:

```sh
sudo systemctl stop kuma-reconciler.timer
# Separately authorized remote mutation; do not run merely to test installation.
sudo systemctl start kuma-reconciler-bootstrap.service
sudo journalctl -u kuma-reconciler-bootstrap.service --no-pager
sudo systemctl start kuma-reconciler-plan.service
```

Do not edit the generated plan to force acceptance. Apply compares the fresh
desired/state/live baselines with the exact approval file and refuses stale or
changed artifacts. A partially completed bootstrap needs outcome review and a
**fresh reviewed plan** against confirmed progress, not replay of a stale file.
After acceptance, restart the timer in the approved mode; changing to apply is a
separate reviewed configuration publication/activation, not implied by bootstrap.

For auditing, the actual packaged operations are:

```text
kuma-reconciler plan COMMON --output /var/lib/kuma-reconciler-review/plan.json
kuma-reconciler apply COMMON --plan-file /var/lib/kuma-reconciler-review/plan.json
kuma-reconciler reconcile COMMON --authorize-ongoing
```

`COMMON` denotes the actual arguments from the installed unit, not a shell
variable: `--desired /nix/store/…-kuma-desired.json --endpoint HTTPS_ORIGIN
--state-dir /var/lib/kuma-reconciler --credential-file %d/management.json`.
`%d` is expanded by systemd only. Do not copy that literal into an interactive
shell or invent an endpoint. The package is built with
`nix build .#kuma-reconciler --no-link`; it is not installed globally by the module.
The timer runs `plan` in dry-run or `reconcile --authorize-ongoing` in apply, two
minutes after boot and every five minutes. Ongoing mode requires successful
bootstrap and accepted policy; it is not a shortcut around exact initial approval.

## Failure, backup and recovery

On any ambiguous create/edit, stop unattended invocation and retain evidence:

```sh
sudo systemctl stop kuma-reconciler.timer
sudo systemctl stop kuma-reconciler.service kuma-reconciler-plan.service kuma-reconciler-bootstrap.service
sudo journalctl -u 'kuma-reconciler*' --no-pager
```

For maintenance, coordinate with other operators so nobody starts a manual unit.
Take a consistent private backup of the **whole state directory** under the same
OS lock, after stopping units. For example, after choosing a private backup path
outside the store/repository and setting shell variable `BACKUP` to it:

```sh
sudo flock -x /var/lib/kuma-reconciler/lock sh -c 'umask 077; tar -C /var/lib -cpf "$1" kuma-reconciler' sh "$BACKUP"
```

Retain both `ownership.json` **and `mutation.pending` if present**, along with
reviewed plan/outcome evidence stored privately. Record absence too. Preserve
UID, modes and contents; never restore half of a pair or delete/recreate the lock
inode while another process could hold it. A backup predating remote writes is
not automatically safe to restore. Revalidate remote IDs/history before enabling
anything. This module does not configure an automatic off-host state backup.

`ownership.json` holds the canonical management origin, confirmed IDs, accepted
policy and unresolved intents; backups and reviewed recovery must preserve that
origin binding. Missing/unbound legacy state is not implicitly upgraded.
`mutation.pending` is a separate durability barrier, not an ownership hint: a
regular, single-link, non-symlink 0600 file owned by the service UID, with exact
content `{"schemaVersion":1}` plus newline. Corrupt/unsafe markers fail closed too.
All filesystem-backed modes, **including plan**, refuse this barrier. Empty
visible intents or an apparently confirmed mapping do **not** justify clearing it.

There is intentionally no automatic recovery command. A knowledgeable operator
must, under the same OS flock and with all invocations disabled:

1. Retain/backup both files before changing either. Inspect the reviewed operation,
   its baseline, complete remote object/ID/history and any acknowledgement to
   establish the outcome. Do not resend a create to discover whether it succeeded.
2. Resolve remaining intent only from proven outcome/explicit reviewed adoption;
   durably write and verify the reviewed ownership mapping, including **file
   fsync, atomic replacement and directory fsync**, while retaining the barrier.
   Use service-owned private regular files; do not relax validation or use direct
   database edits, tag changes, deletion or auth weakening as repair.
3. Only after outcome **and confirmation durability** are established, remove the
   barrier and fsync its directory. If either is uncertain, **leave it in place**.
   A post-replace failure can show empty intents while still requiring this step.
4. Release the lock, generate a fresh plan as the service UID, review it and obtain
   any required new bootstrap authorization before re-enabling invocation.

Rollback means disabling the module (`enable = false`) through an approved
configuration deployment, or immediately stopping the timer/services as above.
Switching to dry-run is another reviewed option, but remains authenticated network
access. Neither action deletes checks/history/state or repairs unresolved intent.
Do not roll back state independently of remote outcomes. Proxy rollback is separate.

## Operational limits

The common lock serializes local timer/manual processes, not arbitrary UI users.
The client re-reads baselines before writes, merges latest unmanaged fields and
stops on detectable drift. Kuma has no verified server-side compare-and-swap:
an unavoidable final read/write gap (and concurrent-create collision gap) remains.
Bootstrap requires an edit-free window; afterward name/target/parent are
controller-owned. Edit unrelated settings outside short apply windows. No claim
of atomic protection against arbitrary concurrent UI edits is made.

The client has bounded connection/ack deadlines and a 120s total run budget;
systemd enforces a 150s oneshot activation limit with a 5s stop timeout and 256MiB
memory ceiling, killing the control group. RuntimeMaxSec alone does not bound
oneshot activation. Long/slow inventories can leave partial progress and require
review. There are no blind mutation retries. The dedicated UID and local
filesystem are trusted; another process with that UID can subvert private state.

Each five-minute read opens an authenticated session and reads full inventory;
writes add per-object reads and durable local fsyncs. Existing monitors retain
their polling load; added monitors add their own checks/retries. Local fixtures
are not production CPU/network/latency measurements: measure actual service and
HAOS overhead before ongoing authorization. Inspect bounded counts/categories in
journald and existing failed-systemd-unit alerts (`SystemdUnitFailed`); missing
or stale data is unknown, not success. Failure must not roll back a deployment.
