# Canonical Node Identities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardware- and role-derived hostnames with stable `hl-node-00` through `hl-node-04` identities while making service roles independently movable.

**Architecture:** A pure topology registry owns stable node facts and a separate role-assignment map. Flake outputs derive host closures and images from that topology, host modules contain only node-specific hardware/network configuration, and role modules provide workload placement plus generated service aliases.

**Tech Stack:** Nix flakes, NixOS modules, sops-nix, Comin, OpenTelemetry Collector, GitHub Actions, Jujutsu.

**Spec:** `docs/superpowers/specs/2026-10-04-canonical-node-identities-design.md`

## Global Constraints

- Canonical hostnames must match `hl-node-[0-9]{2}`.
- The exact current node set is `hl-node-00` through `hl-node-04`.
- Preserve addresses exactly: node 00 `.6`, node 01 `.4`, node 02 `.5`, node 03 `.7`, and node 04 `.9` on `10.15.4.0/24`.
- Preserve every current NIC, disk, GPU, architecture, and image-type fact under its mapped canonical node.
- Node hostnames and static IPs stay fixed when roles move.
- Role aliases follow role assignments; `observability` initially resolves to `10.15.4.6`.
- Do not retain previous machine names as compatibility aliases.
- Preserve SSH host keys, the deployed node's exact age recipient, encrypted credential values, and strict Comin SSH signature enforcement.
- Do not introduce host-side 802.1Q tagging; VLAN 4 remains an untagged access-port segment.
- Do not initialize or format telemetry storage until a powered USB 3 hub is available and a separate destructive-action approval is given.
- Use Jujutsu for all version-control operations.

## Review Focus

- A malformed or incomplete topology must fail evaluation rather than silently omit a node; Task 1 adds exact-set, naming, uniqueness, and unknown-role tests.
- Moving a singleton role must update its alias and modules together without changing either node's IP; Tasks 1 and 3 add asymmetric reassignment fixtures.
- Legacy names must not survive in executable configuration, CI targets, SOPS rules, or current runbook commands; Task 4 adds a bounded source scan.
- Renaming SOPS labels must not rotate or broaden recipient bytes; Task 3 asserts exact recipient sets before and after the policy rename.
- The live cutover must not strand Comin between old and new machine identities; Task 5 verifies pinned activation, signed polling, rollback, and reboot behavior.

---

### Task 1: Canonical fleet topology and validation

**Files:**
- Create: `lib/fleet-topology.nix`
- Create: `checks/fleet-topology.nix`
- Modify: `flake.nix`

**Interfaces:**
- Produces: `mkFleetTopology { nodes ? defaultNodes, roleAssignments ? defaultRoleAssignments, roleAliases ? defaultRoleAliases } -> topology`, plus its default instance as `fleetTopology`.
- Produces: `fleetTopology.nodes :: attrsOf node`, `fleetTopology.roleAssignments :: attrsOf nodeId`, `fleetTopology.roleAliases :: attrsOf aliasName`, `fleetTopology.nodeIds :: listOf string`, `fleetTopology.rolesForNode nodeId :: listOf roleName`, and `fleetTopology.aliasAddresses :: attrsOf (listOf aliasName)` keyed by IP address.
- Node fields: `system`, `address`, `hardwareClass`, `imageType`, `nic`, and Framework-only `installDisk`/`gpuPciId` facts.
- Role assignments: `observability = "hl-node-00"`, `lightweight-services = "hl-node-01"`, `application-services = "hl-node-02"`, `storage-services = "hl-node-03"`, and `developer-media-services = "hl-node-04"`.
- Role aliases: `observability = "observability"`; alias generation resolves it through `roleAssignments` to the assigned node address.
- Consumed by: Tasks 2–4 for host/image generation, role selection, aliases, inventory, tests, and CI matrices.

- [ ] **Step 1: Add failing topology contract tests**

In `checks/fleet-topology.nix`, assert the exact five IDs, canonical-name regex, exact mapping values, unique addresses, valid role targets, singleton role ownership, and alias uniqueness. Exercise `mkFleetTopology` with one override at a time for duplicate IP, unknown role target, alias collision, and a moved `observability` role whose alias resolves to the destination node without changing either node address.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `nix build .#checks.x86_64-linux.fleet-topology --no-link`

Expected: FAIL because the check and `fleetTopology` output do not exist.

- [ ] **Step 3: Implement the pure topology registry**

Create `lib/fleet-topology.nix` with the exact constructor, default instance, helpers, and mappings above. Keep validation pure and force it from `checks/fleet-topology.nix`; do not import NixOS modules or derive role placement from names, hardware classes, or addresses.

- [ ] **Step 4: Export and check the topology**

Import the registry once in `flake.nix`, expose the default as `lib.fleetTopology`, expose the constructor as `lib.mkFleetTopology`, and add `checks.${system}.fleet-topology` on both supported systems.

- [ ] **Step 5: Verify the topology contract**

Run:

```bash
nix build .#checks.x86_64-linux.fleet-topology --no-link
nix eval .#checks.aarch64-linux.fleet-topology.drvPath
nix eval --json .#lib.fleetTopology.nodeIds
```

Expected: the native check PASSES, the ARM check evaluates for its native CI builder, and topology evaluation returns exactly `hl-node-00` through `hl-node-04` in numeric order.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(fleet): add canonical node topology"
jj new
```

### Task 2: Derive hosts and images from canonical nodes

**Files:**
- Move: `hosts/observability-pi/` → `hosts/hl-node-00/`
- Move: `hosts/services-pi/` → `hosts/hl-node-01/`
- Move: `hosts/framework-01/` → `hosts/hl-node-02/`
- Move: `hosts/framework-02/` → `hosts/hl-node-03/`
- Move: `hosts/framework-03/` → `hosts/hl-node-04/`
- Create: `modules/roles/observability-node.nix`
- Create: `modules/roles/lightweight-services.nix`
- Create: `modules/roles/storage-services.nix`
- Create: `modules/roles/developer-media-services.nix`
- Modify: `flake.nix`
- Modify: `checks/evaluation.nix`
- Modify: `checks/common-host.nix`
- Modify: `checks/pi-firmware.nix`
- Modify: `checks/installers.nix`
- Modify: `checks/installer-safety-tests.sh`
- Modify: `installers/rpi-image.nix`

**Interfaces:**
- Consumes: Task 1 `fleetTopology.nodes`, `nodeIds`, and `roleAssignments`.
- Produces: `nixosConfigurations.${nodeId}`, `images.${nodeId}`, and internal `piImageConfigurations.${nodeId}` for every canonical node.
- Produces: role module lookup keyed by the exact role names from Task 1; flake composition selects these modules through `roleAssignments`.
- Preserves: all existing hardware/network facts and destructive installer guards under their mapped canonical IDs.

- [ ] **Step 1: Rewrite evaluation expectations first**

Change `checks/evaluation.nix`, `checks/common-host.nix`, `checks/pi-firmware.nix`, and installer checks to require the exact canonical output set, canonical hostname equality, and the approved old-to-new hardware/address mapping. Assert no legacy NixOS or image output remains.

- [ ] **Step 2: Run focused checks and verify failure**

Run:

```bash
nix build .#checks.x86_64-linux.evaluation --no-link
nix build .#checks.x86_64-linux.common-host --no-link
nix build .#checks.x86_64-linux.installers --no-link
```

Expected: FAIL because the flake still exports legacy identities.

- [ ] **Step 3: Move node-specific files without changing behavior**

Move all five host directories to canonical paths. Keep boot, disk, NIC, MAC, address, and gateway settings byte-equivalent except for path/name references. Remove workload imports and NFS workload declarations from node files; leave only machine-specific hardware, boot, disk, and network configuration.

- [ ] **Step 4: Extract current workload placement into role modules**

Move observability enablement, Cloudflare credential binding, and public routes to `observability-node.nix`; move node 01 Cloudflare/public-route enablement to `lightweight-services.nix`; move the node 03 videos/books NFS declarations to `storage-services.nix`; move the node 04 videos NFS declaration to `developer-media-services.nix`. `application-services` initially has no extra module and must not receive a one-use empty file.

- [ ] **Step 5: Generate closures and images from topology**

Refactor `flake.nix` so `nixosConfigurations`, Framework facts, Pi image configurations, and `images` are generated from Task 1 data. Select hardware composition by `hardwareClass`, image construction by `imageType`, and workload modules only through `roleAssignments`. Preserve corrected Comin, shared fleet modules, Disko, and Raspberry Pi module composition.

- [ ] **Step 6: Rename installer-facing identity safely**

Update Framework typed confirmations, generated installer names, target closure references, Pi image filenames, and the observability-only telemetry initializer selection to canonical IDs. Preserve every destructive-device tuple and refusal path exactly; update expected strings in the owning tests.

- [ ] **Step 7: Verify host and installer behavior**

Run:

```bash
nix build .#checks.x86_64-linux.evaluation --no-link
nix build .#checks.x86_64-linux.common-host --no-link
nix build .#checks.x86_64-linux.installers --no-link
nix build .#checks.x86_64-linux.pi-firmware --no-link
nix eval --json .#nixosConfigurations --apply builtins.attrNames
nix eval --json .#images --apply builtins.attrNames
```

Expected: focused checks PASS; both attribute lists contain exactly the five canonical IDs.

- [ ] **Step 8: Commit**

```bash
jj describe -m "refactor(fleet): derive canonical node configurations"
jj new
```

### Task 3: Role aliases, telemetry, Comin, and SOPS identity

**Files:**
- Create: `modules/fleet/role-aliases.nix`
- Modify: `flake.nix`
- Modify: `modules/fleet/telemetry-agent.nix`
- Modify: `modules/fleet/comin.nix`
- Modify: `.sops.yaml`
- Move if present: `secrets/hosts/observability-pi/` → `secrets/hosts/hl-node-00/`
- Modify: `checks/fleet-topology.nix`
- Modify: `checks/common-host.nix`
- Modify: `checks/telemetry-agent.nix`
- Modify: `checks/secrets.nix`

**Interfaces:**
- Consumes: Task 1 topology and Task 2 canonical configurations.
- Produces: `networking.hosts` entries generated from `roleAliases` and `roleAssignments`; initially `10.15.4.6 = [ "observability" ]` on every node.
- Produces: telemetry default gateway `http://observability:4320`.
- Preserves: Comin signed `main`, remotes, polling, retention, and exact SSH allowed signer; testing branch becomes `testing-${canonicalNodeId}`.
- Preserves: deployed node age recipient `age1q38h0k2k08hkp9xevrm9rkfex9nefvnm362xgmtsg376nk0rgv3sgzgrec` under the `hl-node-00` policy label.

- [ ] **Step 1: Add failing alias and identity assertions**

Assert every canonical closure has exactly the generated role alias, telemetry uses `observability` rather than a node hostname, Comin testing branches use canonical IDs, and SOPS has exact canonical path scopes with unchanged recipient bytes. Use `mkFleetTopology` for an asymmetric fixture moving `observability` to node 04. Assert only `aliasAddresses` and `rolesForNode` move while node 00 and node 04 addresses remain unchanged; then assert the flake's role-module selector consumes `rolesForNode` rather than node names or hardware classes.

- [ ] **Step 2: Run focused checks and verify failure**

Run:

```bash
nix build .#checks.x86_64-linux.fleet-topology --no-link
nix build .#checks.x86_64-linux.common-host --no-link
nix build .#checks.x86_64-linux.secrets --no-link
nix build .#checks.x86_64-linux.telemetry-agent --no-link
```

Expected: FAIL on missing role alias and legacy telemetry/SOPS identities.

- [ ] **Step 3: Implement generated role aliases**

Add `modules/fleet/role-aliases.nix`, pass topology through module arguments, and generate deterministic `networking.hosts` entries from role alias → assigned node → address. Reject unknown targets and alias collisions through Task 1 validation rather than adding fallback behavior.

- [ ] **Step 4: Remove hostname coupling from telemetry and Comin**

Change the telemetry gateway default to `http://observability:4320`. Keep telemetry `host.name` sourced from `networking.hostName`. Keep Comin's branch derivation but verify the now-canonical hostname is its only machine-identity source and strict signed-main behavior is unchanged.

- [ ] **Step 5: Rename SOPS policy labels without rotating keys**

Rename the enrolled anchor and host path rule to `hl-node-00`; rename pending examples to canonical IDs; keep the exact administrator and node 00 recipient strings. Rename any matching host secret directory. Run metadata-only inspection and do not print decrypted values or rewrap connector credentials unless SOPS reports a recipient metadata change is required.

- [ ] **Step 6: Verify identity contracts**

Run:

```bash
nix build .#checks.x86_64-linux.fleet-topology --no-link
nix build .#checks.x86_64-linux.common-host --no-link
nix build .#checks.x86_64-linux.secrets --no-link
nix build .#checks.x86_64-linux.telemetry-agent --no-link
```

Expected: all focused checks PASS and encrypted secret files have no plaintext or unintended recipient changes.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(fleet): decouple role aliases from node identity"
jj new
```

### Task 4: Inventory, CI, and operational documentation

**Files:**
- Modify: `docs/inventory/services.md`
- Modify: `docs/inventory/hosts.md`
- Modify: `docs/inventory/nfs-mappings.md`
- Modify: `checks/inventory.nix`
- Modify: `checks/fixtures/*.json` containing fleet target identities
- Modify: `.github/workflows/checks.yml`
- Modify: `.github/workflows/images.yml`
- Modify: `docs/runbooks/install-framework.md`
- Modify: `docs/runbooks/install-pi.md`
- Modify: `docs/runbooks/enroll-host.md`
- Move: `docs/runbooks/wave-1-observability-pi.md` → `docs/runbooks/wave-1-hl-node-00.md`
- Modify: any current runbook that issues a command against a legacy identity
- Create: `checks/no-legacy-hostnames.sh`
- Modify: `flake.nix`

**Interfaces:**
- Consumes: canonical mappings and output names from Tasks 1–3.
- Produces: machine-readable inventory, native closure/image CI matrices, and active operator commands that use only canonical node IDs and role aliases.
- Historical prose may describe a previous identity only inside the approved design/spec or an explicitly marked migration-history sentence; executable examples and current target fields may not contain legacy identities.

- [ ] **Step 1: Add a failing bounded legacy-name scan**

Create `checks/no-legacy-hostnames.sh` to reject the five legacy identifiers in executable Nix, shell, YAML workflow/policy, current inventory target fields, and active runbook command blocks. Explicitly scope out the design/spec's mapping table and immutable Git history; do not use an unbounded repository-wide ban that prevents documenting migration history.

- [ ] **Step 2: Run the scan and verify failure**

Run: `bash checks/no-legacy-hostnames.sh`

Expected: FAIL with current operational references grouped by file.

- [ ] **Step 3: Rename inventory identities and fixtures**

Apply the exact mapping to target IDs, hardware evidence, dataset destinations, readiness diagnostics, and JSON fixtures. Do not alter measured sizes, paths, backup evidence, architecture sets, or unresolved blockers. Update expected diagnostics in `checks/inventory.nix` only where the target ID is part of the message.

- [ ] **Step 4: Rename CI closure and image matrices**

Use canonical outputs in all five closure jobs and five image builds. Rename observability artifact/checksum/manifest files to `hl-node-00` while retaining revision binding, SHA-256 generation, native ARM execution, bounded diagnostics, and retention behavior.

- [ ] **Step 5: Update active runbooks**

Change build, install, enrollment, SSH, Comin, and recovery commands to canonical node IDs. Refer to `observability` for the movable service endpoint and `hl-node-00` for the machine. Preserve all disk guards, strict known-host behavior, explicit destructive confirmations, VLAN access-port constraints, and the powered-hub telemetry-storage blocker.

- [ ] **Step 6: Wire and run repository checks**

Expose the bounded scan as `checks.${system}.no-legacy-hostnames`, then run:

```bash
bash checks/no-legacy-hostnames.sh
nix build .#checks.x86_64-linux.inventory --no-link
nix build .#checks.x86_64-linux.inventory-fixtures --no-link
nix build .#checks.x86_64-linux.no-legacy-hostnames --no-link
nix fmt -- --check .
nix run .#statix -- check .
nix run .#deadnix -- --fail .
```

Expected: scan, inventory, formatting, and lint checks PASS without changing `flake.lock`.

- [ ] **Step 7: Commit**

```bash
jj describe -m "docs(fleet): adopt canonical node identities"
jj new
```

### Task 5: Integrated verification and `hl-node-00` cutover

**Files:**
- Modify only if verification finds a defect: files owned by Tasks 1–4
- Append evidence: the active Task 11 SDD ledger/report in `/home/bzvestey/dev/new-cluster/.superpowers/sdd/2026-10-01-nixos-fleet-migration/`

**Interfaces:**
- Consumes: the complete canonical-node revision from Tasks 1–4.
- Produces: reviewed signed revision, native CI evidence, and a physically accepted `hl-node-00` deployment.
- External side effects: pushing `main`, activating the Pi, and rebooting require explicit approval immediately before execution.

- [ ] **Step 1: Run complete local verification**

Run serialized checks appropriate to the executor, including:

```bash
nix flake check --show-trace --option max-jobs 1
nix build .#nixosConfigurations.hl-node-00.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.hl-node-01.config.system.build.toplevel --no-link
jj status
jj log -r 'main..@' --no-graph
```

Expected: all available checks PASS, both Pi configurations evaluate/build on native ARM where required, `flake.lock` is unchanged, and only intentional commits remain above `main`.

- [ ] **Step 2: Perform independent whole-change review**

Review against the approved spec with particular attention to topology override tests, role-module selection, SOPS recipient preservation, installer guards, legacy-name scan scope, and rollback. Address every Critical/Important finding through the subagent review loop before release.

- [ ] **Step 3: Sign and verify commits locally**

Use Jujutsu signing for every release commit and verify signatures against the configured SSH signer. Do not rewrite already published history; create forward commits for fixes.

- [ ] **Step 4: Stop for explicit external-action approval**

Present the exact commit range, verification evidence, proposed `main` push, CI workflow impact, and live activation/reboot sequence. Do not push or mutate `hl-node-00` until the user approves those concrete actions.

- [ ] **Step 5: Push and require native CI gates**

After approval, push the signed revision to `main`. Require the native ARM checks, `hl-node-00`/`hl-node-01` closures and images, all three x86 closures/images, and non-KVM checks to pass. Classify any red job from its exact failing assertion before proceeding.

- [ ] **Step 6: Build and inspect the pinned live closure without activation**

On the Pi at `10.15.4.6`, build `github:bzvestey/nix-homelab/<approved-commit>#nixosConfigurations.hl-node-00.config.system.build.toplevel`. Verify hostname, network selector/address, `observability` alias, SOPS path/recipient behavior, Comin policy, corrected package, telemetry endpoint/revision, Pi root filesystem, firmware space, and missing-telemetry mount conditions.

- [ ] **Step 7: Activate and verify before reboot**

Activate the exact pinned closure through strict SSH. Verify current-system path, unchanged SSH fingerprint/MAC/IP/gateway, hostname `hl-node-00`, secret file mode without reading its value, active `comin.service`, `opentelemetry-collector.service`, and `cloudflared-fleet.service`, no failed units, canonical telemetry label, signed Comin acceptance, and cleanly skipped observability backends.

- [ ] **Step 8: Reboot and repeat physical acceptance**

Reboot only after pre-reboot checks pass. Require strict SSH reconnection and verify the booted system equals the canonical closure; repeat network, secrets, Comin, OTel, Cloudflare, failed-unit, root-mount, firmware, and fail-closed storage checks. Exercise selection of the preserved prior generation as the documented rollback path only if acceptance fails.

- [ ] **Step 9: Record evidence and close the rename work**

Append the signed revision, CI URLs, closure path, unchanged SSH fingerprint, before/after hostname mapping, acceptance outputs, and remaining powered-hub blocker to the Task 11 ledger/report. Mark this rename complete while leaving telemetry SSD initialization explicitly pending.
