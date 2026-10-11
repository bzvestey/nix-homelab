# Remaining Fleet Batch Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independently
> owned service groups; the controller integrates shared host/installer files.

**Goal:** Prepare all remaining services, bootstrap media and activation paths
as one batch, minimizing work and builds during sequential hardware cutovers.

**Architecture:** Preserve the existing Podman, local PostgreSQL, SOPS,
Tailscale service proxy and fleet backup/restore boundaries. Add missing
role-owned service modules, then integrate quarantined bootstrap outputs and
runtime secret contracts without deploying or quiescing source services.

**Tech Stack:** NixOS flakes, Podman, PostgreSQL, SOPS/age, restic, Tailscale,
Cloudflare, Comin and jj.

**Spec:** `docs/superpowers/specs/2026-10-11-remaining-fleet-batch-design.md`

## Global constraints

- Corrected placement in the spec is authoritative; Manyfold is excluded.
- No live writes, source stops, deployments, disk operations or publication in
  service implementation tasks. Read-only source inspection is allowed.
- Pin source-compatible images by digest. Preserve keys, OIDC settings and
  public URLs. Do not silently upgrade databases or use NFS for databases.
- Secrets are runtime files, never Nix literals, plaintext scratch or outputs.
- Workers edit disjoint files and leave version-control integration to the
  controller. Use jj for version-control operations.
- Reuse `lib/application-backups.nix` and `fleet.localPostgres`; keep existing
  hl-node-02 applications running unchanged.

## Review focus

- Installed hosts must not automatically enable un-restored workloads through
  Comin; bootstrap services and Comin are masked.
- ARM image selection must be independently supported, not inferred from the
  architecture of the running source container.
- Downloader VPN failure must not expose Deluge through the normal host route.
- Database/state restore includes identity files and consistent WAL state.
- Last-worker evacuation cannot strand OIDC, Forgejo or public ingress.

### Task 1: Lightweight applications

**Files:** `modules/services/lightweight-applications.nix`,
`modules/roles/lightweight-services.nix`,
`docs/runbooks/lightweight-applications.md`.

**Interface:** `services.fleet.lightweightApplications.enable`, default false.
Enabling defines six runtime-secret-gated applications, local state, ingress,
backup jobs and telemetry. Runtime secret paths live under `/run/secrets`.

- [ ] Check live versions/ARM64 support and inspect legacy application YAML.
- [ ] Add a failing contract check for expected services, local database paths,
  preserved URLs and hourly database backup coverage.
- [ ] Implement modules using the existing service/backup conventions.
- [ ] Run formatting and focused evaluation; document secret and restore keys.

### Task 2: Storage applications

**Files:** `modules/services/storage-applications.nix`,
`modules/roles/storage-services.nix`, `docs/runbooks/storage-applications.md`.

**Interface:** `services.fleet.storageApplications.enable`, default false.
Jellyfin/Kavita keep source-compatible containers, local config and Intel GPU
access; Vikunja uses local PG17. NAS videos/books use Tailscale NFS.

- [ ] Inspect source versions, settings, mounts and PostgreSQL contract.
- [ ] Add failing checks for library paths, loopback ports, database locality
  and stopped-state/database backup coverage.
- [ ] Implement the three services and role imports; preserve source URLs.
- [ ] Format and evaluate focused configurations; document restore mappings.

### Task 3: Media automation applications

**Files:** `modules/services/media-automation.nix`,
`modules/roles/developer-media-services.nix`,
`docs/runbooks/media-automation.md`.

**Interface:** `services.fleet.mediaAutomation.enable`, default false.
Seven apps plus VPN/forwarding sidecars preserve source path relationships,
runtime settings and local state. Private publication images require runtime
registry authentication rather than credentials in Nix.

- [ ] Inspect exact source application contracts and pinned live versions.
- [ ] Add failing checks for download/library path coherence, private state,
  backup jobs and fail-closed VPN networking.
- [ ] Implement and validate the role-owned services; no bulk-media copying.
- [ ] Document required runtime secrets, restore and VPN acceptance probes.

### Task 4: Remaining application-host prerequisites

**Files:** `modules/services/remaining-applications.nix`,
`docs/runbooks/remaining-hl-node-02-applications.md`.

**Interface:** `services.fleet.remainingApplications.enable`, default false.
Forgejo, Foundry, Tangled Knot and Tranquil PDS use separate ports/state and
local databases. Do not import or enable them in the active host yet.

- [ ] Inspect source containers/configuration and database versions.
- [ ] Add failing checks for identities, distinct ports, PG locality and
  backup/restore coverage.
- [ ] Implement source-compatible runtime-gated modules and documented
  capture/restore contracts; preserve existing node-02 services.
- [ ] Format and run isolated configuration evaluations.

### Task 5: Batch integration and bootstrap media

**Files:** `lib/fleet-topology.nix`, remaining `hosts/*/default.nix`,
`flake.nix`, `modules/fleet/bootstrap.nix`, image workflow/packaging fixtures,
`docs/runbooks/remaining-fleet-cutover.md`, new batch contract checks.

- [ ] Pin observed Framework namespace-qualified by-id links and permanent
  MACs; assign lan0/lan1 in both real host and installer configurations.
- [ ] Generalize bootstrap masking to services from all prepared roles and
  disable bootstrap Comin. Expose active and temporary-hosting closures.
- [ ] Define application/backup/identity secret mappings and enrollment
  procedure without fabricated ciphertext or host recipients.
- [ ] Prepare offline source capture/restore sequencing, temporary Pi staging,
  shared ingress evacuation and per-host activation commands.
- [ ] Package all three image artifacts with revision manifests/checksums.
- [ ] Run combined focused checks and closure evaluations, review the diff,
  then build/package the batch when all physical/runtime inputs are resolved.

## Execution record

The operator explicitly approved starting implementation after correcting
placement. Preserve that execution authorization; do not add another design
approval round. The current jj workspace is already isolated from main.

Service tasks 1–4 are implemented and their contracts are registered in the
combined `remaining-services` check. Task 5 configuration integration is
implemented: observed Framework disk/MAC facts, quarantined bootstrap targets,
active/staging variants, runtime secret mappings, HTTP/TCP service identities,
identity backups, sequential cutover runbook and three-image batch selection.
The image workflow packages Pi 01 as well as the existing Pi 00 artifact;
closure CI prebuilds the two preparation variants.

Validation: focused remaining-services/remaining-batch/common-host/topology/CI
checks built successfully; formatting, deadnix and Framework packaging fixtures
passed. Flake evaluation passed; all three image derivations and both prepared
variant closures evaluated. No image or full system build is claimed.
The operator subsequently authorized clearing CI blockers and starting image
builds. Latest published CI failures were both Statix repeated-key violations
in `hosts/hl-node-02/cutover.nix` and `checks/storage.nix`. Grouping those
declarations without changing values cleared Statix. Formatting, deadnix,
focused installer/secrets/migration checks and all-system flake evaluation pass.

Remaining delivery: publish the batch and run the grouped image/closure build. Actual host
recipient enrollment, consistent first-source captures/restores and runtime
acceptance remain cutover steps. Nothing was deployed, stopped, restored or
written to a physical disk during this preparation.
