# hl-node-02 Batched Restore Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare dormant application-secret mappings, repeatable offline rehearsal tooling, and scoped CI in one locally verified batch.

**Architecture:** Preserve the installed host's bootstrap policy. Reuse the existing two-VM service rehearsal rather than create a production-capable host generation. A shared CI selector chooses architecture, closure and image matrices, conservatively expanding validation when change discovery is incomplete.

**Tech Stack:** Nix flakes, NixOS tests, sops-nix, Python standard library, Bash, GitHub Actions, jj.

**Spec:** `docs/superpowers/specs/2026-10-10-hl-node-02-restore-preparation-design.md`

## Global Constraints

- Use jj for local version control; retain the published preparation commit as an ancestor.
- Do not update `flake.lock`, publish, launch the private-data rehearsal, transfer private data, restore production data, change routes, mount production NFS, unmask host services, or activate host backups/runners. Synthetic test VMs are permitted for validation.
- Keep application ciphertext absent until real approved inputs exist; never create placeholder production credentials.
- Runtime application/backup mappings are root-owned mode `0600`; Tailscale bootstrap remains separate.
- Keep `/mnt/bulk/immich` and its production NFS units absent from bootstrap.
- Retain the existing KVM/non-KVM distinction and report omitted VM coverage honestly.
- Local commits may separate reviewable responsibilities; publication remains one batch after explicit approval.

## Review Focus

- A multi-commit push changes a host early, then only docs: select the host from the complete range, not just the last commit (Task 3).
- Renamed or deleted infrastructure files: classify both old and new paths, conservatively retaining affected builds (Task 3).
- API truncation, denied access or an invalid baseline: select full validation rather than quietly returning empty matrices (Task 3).
- A symlinked or unencrypted rehearsal directory: reject before starting the driver or creating private outputs (Task 2).
- Credentials are installed under bootstrap: no application, database, runner, Caddy or backup becomes startable (Task 1).

## Ownership and Execution

Preserve the user's selected subagent-driven execution method. Task 1 and Task 3 have independent write sets and may be dispatched together. Keep `flake.nix` integration, Task 2 and combined verification with the parent agent; do not give concurrent workers ownership of `flake.nix`. Review returned diffs and evidence before integration. Use the current checkout or a jj workspace, not a separate orb with missing local preparation commits.

### Task 1: Dormant Application and Backup Secret Mappings

**Files:**
- Create: `hosts/hl-node-02/application-secrets.nix`
- Modify/test: `checks/hl-node-02-bootstrap.nix`
- Modify: `docs/runbooks/wave-2-hl-node-02.md`
- Parent integration only, if needed: `flake.nix`

**Interfaces:**
- Consumes: `hlNode02ApplicationSecretsFile`, a required module argument containing the reviewed SOPS YAML path; synthetic input supplies it in tests.
- Produces: six `sops.secrets` mappings and `fleet.backup.s3CredentialsFile`; no default-host import, restart requests or service enable overrides.

- [ ] **Write failing mapping assertions.** Extend the real-host evaluation using `extendModules`, importing sops-nix and the prospective mapping with a fixture file argument. Assert the following literal key/path pairs, root ownership, mode `0600`, and empty `restartUnits`:

  ```text
  immich-env             /run/secrets/immich.env
  mealie-env             /run/secrets/mealie.env
  tuwunel-config         /run/secrets/tuwunel.toml
  restic-repository      /run/secrets/restic-repository
  restic-password        /run/secrets/restic-password
  restic-s3-credentials  /run/secrets/restic-s3-credentials
  ```

  Assert backup shared credentials point to the last runtime path. Reuse the existing bootstrap assertions and credential-present VM test for masks and NFS absence. Produce synthetic encrypted fixture input using a disposable test recipient, never the fleet recipients. Mapping evaluation may disable SOPS validation to avoid building the fixture during evaluation; do not claim decryption coverage from these assertions.
- [ ] **Run red:** `nix build --no-link .#checks.x86_64-linux.hl-node-02-bootstrap`. Confirm failure comes from the missing module/mappings, not an unrelated error.
- [ ] **Implement the module.** Destructure `config`, `lib` and `hlNode02ApplicationSecretsFile`; declare only the six mappings and shared-credentials option. Do not import it in `hosts/hl-node-02/default.nix`. Do not create `applications.yaml`. Document the future import and file argument, required keys, and separate credential enrollment gate in the existing runbook.
- [ ] **Run green:** the bootstrap check must pass with synthetic credentials and all masks intact. Verify the evaluated default host still contains only the Tailscale mapping; inspect the existing sops-nix runtime directory policy without changing shared directory permissions.
- [ ] **Commit locally:** `feat(secrets): prepare dormant hl-node-02 application mappings`. Return the diff, red/green results, and any gaps; do not publish.

### Task 2: Reusable Offline Rehearsal Target and Guarded Launcher

**Files:**
- Modify: `flake.nix`
- Create: `packages/hl-node-02-rehearsal.nix`
- Create/test: `checks/rehearsal-launcher.nix`
- Modify: `docs/runbooks/wave-2-source-rehearsal.md`

**Interfaces:**
- Consumes: `self.checks.x86_64-linux.hl-node-02-services.extend`, retaining pinned images and native database contracts.
- Produces: `packages.x86_64-linux.hl-node-02-rehearsal-driver`, `apps.x86_64-linux.hl-node-02-rehearsal`, and `checks.x86_64-linux.rehearsal-launcher`.
- Launcher usage: `nix run .#hl-node-02-rehearsal -- /absolute/encrypted/scratch`. It opens the driver interactively but never invokes `run_tests()` or `test_script()` automatically.

- [ ] **Write failing rejection tests.** Execute the launcher against a nonexistent directory, relative path, symlinked directory and ordinary unencrypted build scratch. Assert nonzero exit and no driver execution/output creation. A successful-path probe may use only a disposable encrypted filesystem and synthetic data; do not relax production guards to make it pass.
- [ ] **Run red:** `nix build --no-link .#checks.x86_64-linux.rehearsal-launcher` must fail before implementation.
- [ ] **Implement the driver package.** Reuse the exact extension already built: application guest disk `65536` MiB, rehearsal NAS disk `131072` MiB, `virtualisation.restrictNetwork = true` on both, and all four job timers plus `fleet-backup-check` disabled. Publish the `.driver` output only, not the VM test result. Declare this package/app only on x86.
- [ ] **Implement the launcher.** Verify canonical scratch path, ownership and restrictive permissions; use `findmnt` and `lsblk` to establish an active `crypt` ancestor of the filesystem, rejecting ambiguous/non-block backing. Require KVM access. Create a short private runtime directory on the same filesystem only after guards pass. Set private TMPDIR, XDG runtime and disabled history. Execute in a user/network namespace with only loopback and no IPv4/IPv6 default route; preserve the runbook's separate guest-isolation checks. Use explicit tool paths and clean up empty temporary runtime directories on early failure, not private guest data on driver exit.
- [ ] **Run green:** launcher rejection tests and `nix build --no-link .#hl-node-02-rehearsal-driver` pass; verify the driver executable exists. Do not launch it against real data. Update the runbook to use the new target and explain that build success is not isolation proof or launch authorization.
- [ ] **Commit locally:** `feat(rehearsal): package isolated hl-node-02 restore driver`.

### Task 3: Conservative Changed-File CI Selection

**Files:**
- Create: `.github/scripts/ci-scope.py`
- Create/test: `.github/tests/ci-scope.py`
- Modify: `.github/workflows/checks.yml`, `.github/workflows/images.yml`
- Modify: `README.md` (CI scope and manual image usage)
- Parent integration only: register the selector fixtures as a non-KVM flake check in `flake.nix`.

**Interfaces:**
- `select_scope(paths: list[str], complete: bool = True) -> dict`: pure selection with deterministic sorted matrices; include both paths for renames.
- CLI: `python3 .github/scripts/ci-scope.py --event "$GITHUB_EVENT_PATH" --output "$GITHUB_OUTPUT"`. Use `GITHUB_TOKEN` for read-only GitHub REST change discovery; no shell interpolation of branch names or credential logging.
- Output keys: `checks`, `closures`, `framework_images`, `pi_images` (compact JSON `include` matrices) and `has_checks`, `has_closures`, `has_framework_images`, `has_pi_images` (lowercase boolean strings). Runner/architecture/host fields match existing workflow matrices.

- [ ] **Write failing observable-output tests.** Run the selector on controlled inputs and assert matrices, not source text. Required cases: docs-only → empty builds; hl-node-02-only → x86 checks and its closure, no images; hl-node-01 secret-only → ARM checks and its closure, no images; shared module/lockfile/CI → both architectures/all closures; unknown path/incomplete discovery → full checks/closures/images; Framework installer → all Framework images; Pi installer/hardware module → both Pi images; mixed host+docs → host retained; renames/deletions → old path retained. Test manual image selection for one host/all and reject invalid names.
- [ ] **Test range discovery.** Mock only the GitHub HTTP boundary with realistic paginated responses. Push uses `before...after`; a new branch uses repository default branch as baseline when available. PR uses its changed-files endpoint, including renamed filenames. Detect compare-file limits, unreachable baselines, inconsistent counts and pagination truncation and mark discovery incomplete. Tests must show a multi-commit push cannot lose earlier changes, and error fallback is broad rather than empty. Keep rate limits and tokens out of logs.
- [ ] **Run red:** `python3 .github/tests/ci-scope.py`; failures must identify missing selection behavior.
- [ ] **Implement selector and workflow integration.** Add a small selection job to each workflow, with read-only contents/pull-request permissions as required. Guard empty jobs before matrix expansion and use `fromJSON` for matrices. Preserve existing build commands, failure summaries, image packaging and upload provenance. Keep full architecture check commands for selected architectures; do not silently reduce their individual check sets. Shared changes select broader closures but do not automatically build images unless installer-related; incomplete/unknown discovery selects all images conservatively.
- [ ] **Add manual image workflow input.** `workflow_dispatch` accepts `all` or an exact canonical node ID; select the matching image family. Explicit manual dispatch may build application-changed images even when automatic selection would skip them. Do not dispatch it during implementation.
- [ ] **Run green:** selector tests, existing packaging fixtures, and actionlint against both workflows. Use available project tools or pinned Nix packages; do not alter the lockfile to obtain a linter. Document skipped-image meaning and one-push milestone batching.
- [ ] **Commit locally:** `ci: select affected host builds and on-demand images`. Return test results and the selection table; do not publish.

### Task 4: Integrate and Verify the Single Batch

**Files:** `flake.nix` integration plus the preceding tasks' complete diff.

- [ ] **Integrate returned changes and inspect ownership.** Ensure only the parent changes `flake.nix`; register selector fixtures on both architectures and launcher fixtures on x86. Reconfirm default host bootstrap imports and masks are unchanged.
- [ ] **Run formatting and linting:** `nix fmt -- --check .`, `statix check .`, `deadnix --fail .`; fix only batch-related findings.
- [ ] **Run the complete local x86 suite:** `nix flake check --no-update-lock-file --show-trace --option max-jobs 1`. Report omitted ARM execution and any unrelated failures. Run bootstrap readiness separately and build the rehearsal driver without starting it.
- [ ] **Review `jj diff` across the batch.** Check ciphertext absence, no new live secret import, unchanged lockfile, no production activation, and correct CI fallback/empty matrices. Record fresh validation evidence without credentials.
- [ ] **Handoff:** report local delivery state, independent preparation completed, remaining credential/data/approval gates, and request one signed preparation-branch publication. Do not move `main` or trigger workflows manually without approval.
