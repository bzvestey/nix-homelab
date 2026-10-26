# Uptime Kuma Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution method requires operator selection before implementation.

**Goal:** Maintain Kuma's node and service monitors from evaluated fleet configuration without losing history or modifying unmanaged monitors.

**Architecture:** Generate a non-secret desired manifest at Nix evaluation time. A dedicated Python Socket.IO client on the observability host reads the full Kuma inventory, builds a deterministic plan and, only when explicitly enabled, applies bounded changes using private ownership state. Keep Kuma on HAOS and the telemetry collector unchanged.

**Tech Stack:** NixOS, Python 3, python-socketio/Engine.IO, systemd credentials and timers, a locked real Kuma 2.5.6 test fixture.

**Spec:** [Managed Uptime Kuma reconciliation](../specs/2026-10-26-uptime-kuma-reconciliation-design.md).

## Global Constraints

- The module is disabled by default; enabled mode defaults to dry-run. Do not enable it on hl-node-00 during implementation.
- No publication, deployment, production writes, new credentials, application restarts or HAOS exposure changes are authorized by this plan.
- Preserve existing monitor IDs, history, notification assignments, pause/maintenance state and unmanaged configuration. Never delete, pause, resume or garbage-collect monitors.
- Nodes use `fleetTopology.nodes`, canonical names, LAN addresses and group `nix-homelab`; sites use enabled ingress routes and longest dot-delimited domain matching.
- Keep current groups `nix-homelab`, `tailbc181.ts.net`, `minastas.xyz`, `minastas.social` and their nesting. Initial counts are five nodes and 23 sites: 18/3/2 across the site groups.
- Do not change the topology's existing exact-five-node constraint. Test fleet growth using synthetic generator input.
- No ownership tags, direct database access, Supervisor credentials, Docker socket or SSH in the runtime reconciler.
- Kuma compatibility initially means exactly 2.5.6. Real-server acceptance, not mocks alone, establishes the management API contract.
- New checks: 60s interval, 10s timeout and two retries at 30s; HTTP additionally uses GET, verified TLS, maximum ten redirects and accepted 200–299. Existing checks do not inherit these defaults.
- Keep the separate local proxy-trust fix and regression check intact. Publishing/deploying it is a separate approval and not a task here.
- Use jj for version control and jj workspaces for any additional isolation. Do not create commits merely to record task iterations; commit/push only with appropriate authorization.

## Review Focus

1. A paused manual monitor or duplicate group has the same desired identity: block, do not silently adopt/create (Tasks 1, 3).
2. Remote creation succeeds but its acknowledgement or local state write is lost: stop and never duplicate on retry (Task 4).
3. Editing a full monitor payload clears an unrelated setting or pause state: retain current unmanaged fields and validate the result (Tasks 1, 4).
4. A manually edited configuration changes between planning and application: reject detectable drift and document the remaining non-atomic gap (Tasks 3, 4).
5. A new node/domain or a lookalike suffix is mishandled: include new nodes, create configured groups first, reject unknown/lookalike domains (Tasks 2, 3).

## File and interface boundaries

- `lib/kuma-inventory.nix`: pure desired-manifest generation from projected topology/routes and reviewed overrides.
- `packages/kuma-reconciler/{default.nix,client.py,reconcile.py}`: locked package, bounded real API transport, and planning/state/CLI respectively. Do not split each operation into another module.
- `modules/fleet/kuma-reconciler.nix`: disabled-by-default options, credentials, private state and serialized timer/service.
- `checks/{kuma-inventory.nix,kuma-reconciler.py,kuma-reconciler.nix}`: generator, public CLI/behavior tests and real-server/module integration.
- `checks/fixtures/kuma-2.5.6.nix`: hash-locked isolated upstream server fixture; not a production service or an editable database snapshot.
- `flake.nix`: project fleet data into the observer module; expose package and checks on existing systems.
- `modules/roles/observability-node.nix`: import the module, leaving its defaults disabled. No live host or SOPS declarations in these tasks.
- `docs/runbooks/uptime-kuma-reconciliation.md`: commands, ownership recovery and separately approved rollout steps.

Data contracts are JSON-compatible dictionaries, not a class hierarchy. The
desired document has `schemaVersion`, `groups`, `checks`, `adoptions`, `policy`
and a canonical digest. Groups carry `key`, `name`; checks carry `key`, `type`,
`name`, `parentKey` and `target` (`url` or `hostname`). `adoptions` maps keys to
expected live ID/type/name/target; node and site keys are `node:<id>` and
`site:<hostname>`. Explicit overrides may retain a stable key across renames.
Ownership state maps keys to IDs/types and includes pending mutation intents;
it never stores raw monitor objects or credentials. A plan has schema/version,
desired digest, relevant-live fingerprint, ownership fingerprint and ordered
operations (`adopt`, `create`, `update`, `report-removed`), plus blocking conflicts.
Hash normalized configuration fields, not heartbeat/runtime values. Never serialize
unmanaged authentication/notification payloads into the plan.

### Task 1: Establish the pinned real-server API boundary

**Files:** Create `packages/kuma-reconciler/client.py`, `packages/kuma-reconciler/default.nix`, `checks/fixtures/kuma-2.5.6.nix`, `checks/kuma-reconciler.py`, `checks/kuma-reconciler.nix`; modify `flake.nix` package/check declarations.

**Interfaces:** `KumaClient(endpoint: str, credential_file: str)` with `snapshot() -> dict` (server version plus complete monitor list), `get_monitor(id: int) -> dict`, `create_monitor(payload: dict) -> int`, `edit_monitor(payload: dict) -> None`, `close() -> None`. Connection and acknowledgement deadlines are each 10s, reconnection disabled for mutations. API errors expose a bounded category, not the server payload.

- [ ] Inspect Kuma 2.5.6's exact server source for authentication, initial `info`/`monitorList` events, `getMonitor`, `add`, `editMonitor`, and history reads. Register event handlers before connection; do not infer complete inventory from initial heartbeat messages. Record exact payload/ack conventions beside the contract tests.
- [ ] Lock an isolated real Kuma 2.5.6 server source/image and all fixture/client dependencies by content hash using existing Nix packaging patterns. Use disposable test state/accounts and no production values. Expose only local/VM test ports; clean disposable processes/state after tests.
- [ ] Write `test_snapshot_includes_paused_monitor`, `test_server_version_and_auth_fail_closed`, and `test_edit_preserves_unrelated_fields_and_history`. Against the fixture, assert active and paused objects are both present; version mismatch/auth failure permits zero mutations; editing only a name retains ID, notifications, pause state and recorded history. Run through `nix build -L .#checks.x86_64-linux.kuma-reconciler`; the missing client/behavior must fail before implementation.
- [ ] Implement the client and packaging. Credential JSON supports either `loginToken` via `loginByToken` or username/password login without changing MFA policy; never fall back between credential forms. An MFA-required interactive account fails unattended login unless an operator supplies a valid login token through the private credential file. Reject non-HTTPS origins, userinfo, query/fragment and unconfigured origins; fixture TLS uses an explicit test CA, never `verify=False`. Disable verbose HTTP/Socket.IO logging.
- [ ] Run the same tests GREEN, including transport timeout and invalid TLS controls. Verify a group creation/edit, an HTTP check and a ping check against the real fixture. If the pinned server lacks a required contract, stop and revise the spec before implementing downstream code; do not replace this gate with a mocked success.

### Task 2: Generate inventory from evaluated fleet data

**Files:** Create `lib/kuma-inventory.nix`, `checks/kuma-inventory.nix`; modify `flake.nix` check declarations.

**Interfaces:** `import ./lib/kuma-inventory.nix { inherit lib; }` returns a function taking `{ nodes, routesByHost, domainZones, overrides, adoptions, notificationPolicy }` and returning the desired document above. Project nodes to ID/address only and routes to host/hostname/exposure; no whole host configurations, secrets or options enter the output.

- [ ] Write Nix assertions for five-node baseline plus a synthetic sixth node, changed address, disabled/removed service route, wildcard exclusion, explicit alias exclusion, unknown zone, nested tailnet name and `evilminastas.xyz`. Expect the extra node under `nix-homelab`, address changes without key changes, and rejection of unknown/lookalike zones. Register `checks.<system>.kuma-inventory`; run it RED before the generator exists.
- [ ] Implement generation with stable sorting, duplicate key/target validation and longest dot-boundary suffix selection. Default HTTPS roots; overrides supply names and Grafana `/dashboard/api/health`/Homarr `/api/health/live`. Exclude `pds.minastas.social` and literal wildcard PDS routes; do not introduce the alternate Deluge proxy or optional TCP checks.
- [ ] Encode the reviewed adoption IDs from the spec as initial expected identities, including all five node addresses and four groups. Keep existing Matrix/PDS root URLs unless explicitly selected later. Add explicit display-name overrides matching current adopted names, avoiding an incidental rename during adoption.
- [ ] Run generator checks GREEN. Assert baseline 23 site checks plus five nodes and four groups, groups 18/3/2, and NAS IDs 8/12 absent from owned inventory. A new configured domain creates a desired group before child resolution; an unconfigured domain errors. Verify no credentials, upstream secret paths or entity data occur in the rendered manifest.

### Task 3: Implement a read-only deterministic planner

**Files:** Create `packages/kuma-reconciler/reconcile.py`; extend `checks/kuma-reconciler.py` and packaging.

**Interfaces:** `build_plan(desired: dict, live: dict, ownership: dict) -> dict`, pure and without client calls. `normalize_target(monitor: dict) -> tuple` preserves scheme, non-root path and query while normalizing hostname/default port/empty root. `main(argv: list[str] | None = None) -> int` initially implements `plan --desired FILE --credential-file FILE --endpoint ORIGIN --state-dir DIR [--output FILE]`.

- [ ] Write planner/public CLI tests for `test_paused_unmanaged_collision_blocks_all_writes`, `test_duplicate_group_blocks_adoption`, `test_missing_owned_id_is_not_recreated`, and `test_adoption_preserves_id_and_settings`. Assert blocking conflicts rather than takeovers; correct operation sets/order; no default resets, deletes, pauses or resumes. Run RED with missing planner behavior.
- [ ] Implement manifest/state validation, compatible-server check, deterministic operations and relevant-object fingerprints. Check identity conflicts for the whole inventory before permitting any operation. Keep creation and adoption distinct. Owned target/name/parent changes may update; disappeared desired keys are report-only. Preserve existing group nesting.
- [ ] Complete `plan` using Task 1's full snapshot. Dry-run may take a lock and write an explicitly requested review plan, but must not mutate Kuma or persist ownership claims. Terminal logs print bounded operation keys/counts/categories, not full objects, credentials or private payloads. Exit 0 for a valid plan, 2 for conflicts/stale input, 1 for transport/auth/state errors.
- [ ] Run GREEN with non-root path/query distinctions, HTTP-vs-HTTPS and port asymmetry, changed node address, shuffled snapshot order and unsupported server version. Assert deterministic output and no create collision against any exported or paused live object. Verify sensitive sentinel values from unrelated monitor/notification fields never occur in stdout/stderr/plan.

### Task 4: Apply plans with durable ownership and ambiguous-write safety

**Files:** Extend `packages/kuma-reconciler/reconcile.py`, `checks/kuma-reconciler.py` and real-server integration.

**Interfaces:** `apply_plan(plan: dict, desired: dict, client: KumaClient, state_dir: Path) -> dict`. Add CLI `apply` with the same inputs plus `--plan-file FILE`; add `reconcile` for an already bootstrapped state and explicitly enabled ongoing policy. A bootstrap marker records the accepted adoption/inventory policy. No automatic bootstrap in `reconcile`.

- [ ] Write real-fixture tests `test_second_reconciliation_has_no_changes`, `test_lost_create_ack_does_not_duplicate_after_restart`, `test_state_persist_failure_blocks_next_write`, `test_stale_plan_refuses_apply`, and `test_latest_unmanaged_fields_survive_edit`. Deliberately let the fixture commit a creation before dropping its acknowledgement. Assert only one monitor exists on subsequent invocation and the unresolved intent blocks further mutation. Run RED.
- [ ] Implement a filesystem lock covering manual/timer processes, 0700 state directory and atomic 0600 state writes with file/directory synchronization. Persist an intent before mutation and confirmed ID after acknowledgement. Reject unsafe state files, corrupt/unknown state schema and pending unresolved intent before further writes. Do not treat state loss as permission to take over matching manual objects.
- [ ] Verify plan/desired/ownership/live fingerprints before bootstrap apply and relevant-object baseline immediately before each mutation. Create groups before children. Merge edits into the latest full live configuration, changing only declared fields. Never send a blind second create on transport failure, roll back acknowledged creations destructively, or overwrite unrelated settings with defaults. Stop on first error; retain prior confirmed progress.
- [ ] Implement ongoing reconciliation only after bootstrap, using approved ownership/domain/notification policy for future automatic additions. Existing missing IDs, unexpected matches and ambiguous writes stop for review. Removed nodes/sites remain report-only. Bound the entire run to 120s; a killed run must leave recoverable state, not an implicit retry allowance.
- [ ] Run GREEN against actual Kuma persistence/history and fixture-controlled failure windows, including a local-state failure after remote acknowledgement, concurrent relevant edits, stale invocation of an approved plan and a newly added synthetic node. Assert zero delete/pause/resume/tag operations. Document the unpreventable final read/write race; bootstrap uses an edit-free window and managed fields remain controller-owned afterward.

### Task 5: Wire disabled-by-default NixOS integration

**Files:** Create `modules/fleet/kuma-reconciler.nix`; modify `flake.nix`, `modules/roles/observability-node.nix`, `checks/kuma-reconciler.nix` and `checks/kuma-inventory.nix`.

**Interfaces:** `fleet.observability.kumaReconciler` options: `enable=false`, `mode="dry-run"` (`dry-run`/`apply`), nullable `endpoint`/`credentialFile`, `domainZones`, `overrides`, `adoptions`, nullable `notificationPolicy`. `endpoint` is an HTTPS origin only, not an HA ingress subpath; no live default hostname is invented. `credentialFile` is a runtime absolute path, read through systemd `LoadCredential`.

- [ ] Write module assertions RED: disabled creates no service, timer, user, firewall rule or secret declaration; enabled defaults dry-run; apply requires explicit notification policy; credentials are referenced by path but their contents are absent from generated manifest/argv/environment. Unknown endpoint/unsafe origin/invalid credential path fails evaluation before service creation. Runtime apply without a completed bootstrap fails before mutations.
- [ ] Import the module in the observability role only. In `flake.nix`, pass a lazily projected fleet inventory to that role through module arguments; never force another host's whole configuration. Generate the manifest using Task 2. Check actual observer evaluation avoids self-recursion, including its own Grafana route. Leave host enablement and all SOPS declarations unchanged.
- [ ] Create dedicated `kuma-reconciler` user/group, private `/var/lib/kuma-reconciler`, hardened oneshot and timer after boot/every five minutes. Use Task 4's common lock; enforce `RuntimeMaxSec=150`, `MemoryMax=256M` and stop behavior compatible with atomic state. Dry-run calls `plan`; apply calls only `reconcile`, refusing an unbootstrapped state. Initial bootstrap is a separately authorized manual `apply --plan-file` while the timer remains dry-run. Only after live acceptance and separate approval may mode change to `apply`. Never emit management credentials into process arguments or environment. No network listener or new telemetry collector privilege.
- [ ] Run module tests GREEN on enabled/disabled synthetic configurations and actual fleet evaluation; assert no production enablement or secrets were added. A VM with the real test server exercises dry-run then explicitly test-authorized bootstrap, repeats no-op reconciliation, checks preserved settings/history, and verifies a failed service is observable through existing failed-unit monitoring. Test lock contention and process timeout recovery, not only unit text.

### Task 6: Operator handoff and whole-change validation

**Files:** Create `docs/runbooks/uptime-kuma-reconciliation.md`; modify `README.md` only for its runbook link; extend existing tests where gaps from Tasks 1–5 remain.

- [ ] Document exact packaged CLI commands for planning, approval-file apply and disabled rollback. Explain state backup, unresolved creation intents, missing-owned-ID recovery through explicit reviewed adoption, MFA/login-token handling and full inventory versus metrics. A partially completed bootstrap needs a fresh reviewed plan against confirmed progress; replaying its stale artifact is not recovery. Never recommend database edits, tag changes, auth weakening or a retry that could duplicate a monitor.
- [ ] Document separate approvals for HTTPS management exposure, private credential provisioning, proxy-fix publication/deployment, reconciler dry-run deployment, bootstrap writes and ongoing automatic apply. Do not execute those steps. Live Kuma-context heartbeats and complete inventory remain acceptance gates, not claims made by fixture tests.
- [ ] Run `nix fmt -- --check <affected-nix-files>`, scoped Statix/Deadnix, `nix build -L .#checks.x86_64-linux.kuma-inventory .#checks.x86_64-linux.kuma-reconciler`, and `nix flake check --no-build --all-systems`. Then run the repository's `nix flake check -L` for the native system, recording exact failures or environmental blockers without claiming skipped builds passed. No remote build host is implicitly authorized.
- [ ] Check the installed package and module evaluate for aarch64 as well as x86_64. Build/run ARM acceptance only with an available authorized native executor; evaluation alone is not runtime proof. Keep production mode disabled if actual-host/runtime acceptance remains outstanding.
- [ ] Read the complete jj diff and self-review against every spec section and five Review Focus cases. Confirm the existing local trust fix remains unchanged, no secrets/scratch fixtures escaped into tracked files, no production configuration was enabled and no external writes occurred. Request independent final review when permitted by the chosen execution method and resolve important findings before delivery.

## Execution handoff

This plan does not select an execution method or authorize implementation by
itself. Ask the operator to review it and choose Native (controller implements
the tasks) or Subagent-driven (fresh implementer/reviewer gates by task). Prefer
Native for these tightly shared planner/state/transport interfaces; independent
review should focus on mutation safety before any production apply is proposed.
No task grants permission to push or deploy, even if local validation succeeds.
