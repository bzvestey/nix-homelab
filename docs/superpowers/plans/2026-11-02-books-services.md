# Books Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The operator must review this plan and select execution before implementation.

**Goal:** Add Chaptarr and Audiobookshelf with a shared TrueNAS books library and native Tailscale Services, without disrupting existing media applications.

**Architecture:** Run Chaptarr on hl-node-04 and Audiobookshelf on hl-node-03 using digest-pinned Podman containers. Keep state local, mount the new books dataset through existing fail-closed NFS, and advertise HTTPS Services through the hosts' existing Tailscale daemons. Separate repository implementation from explicitly approved shared-infrastructure activation.

**Tech Stack:** NixOS modules, Nix flake checks, Podman, systemd, SQLite, TrueNAS ZFS/NFS, Tailscale Serve Services, jj.

**Spec:** `docs/superpowers/specs/2026-11-02-books-services-design.md` (approved in this thread).

## Global Constraints

- Chaptarr uses SQLite, not PostgreSQL.
- Create dataset `spinners-1/books` at `/mnt/spinners-1/books`, a sibling of `spinners-1/videos`.
- Declare `fleet.storage.nfsMounts.book-library`, targeting `/mnt/bulk/book-library`, mounted as `/books` in both containers.
- Chaptarr gets read/write access; Audiobookshelf gets read-only access.
- Preserve Kavita's separate `spinners-1/Computer/books` library and `/mnt/bulk/books` mount.
- Use Sonarr's existing Deluge and SABnzbd; preserve their paths, jobs, credentials, and Deluge VPN isolation.
- Imports across datasets must copy; retain torrent seeding files.
- Expose only `svc:chaptarr` and `svc:audiobookshelf` on HTTPS 443, using existing host daemons, not migrated service identities or Funnel.
- Tailscale service hosts must be tagged; upstream minimum client version is v1.86. Clients before v1.94 may require route acceptance.
- Use `America/Los_Angeles`; daily stopped-state backups at 06:00 in that timezone.
- No credentials in Git, documentation, the Nix store, command arguments, logs, or review artifacts.
- Use jj for version control and jj workspaces for isolation. Do not modify unrelated changes or push/deploy without explicit authorization.

## Review Focus

1. Existing unrelated Serve configuration must survive apply, repeat apply, restart, update, and removal (Task 1).
2. A logged-out daemon or pending/denied Service advertisement must not be reported as a working endpoint (Tasks 1 and 5).
3. A missing NAS mount must block consumers; Kavita must retain its original dataset and mounts (Tasks 2 and 3).
4. Cross-dataset torrent imports must copy without deleting seeding data, and ebook/audiobook routing must not alter Sonarr (Task 5).
5. Bootstrap and rollback must suppress new advertisements without resetting the host daemon or removing library data (Tasks 1, 4, and 5).

## File Ownership and Execution Setup

The current default workspace is based on an older revision than local `main`.
Local `main` already has newer NFS readiness handling. Do not implement by
rewriting this workspace's parent or using its older storage implementation.

- [ ] Load the workspace-isolation skill and create a jj workspace from current local `main`; inspect divergence from the configured remote before choosing any newer base. Do not fetch-and-rebase unrelated changes automatically.
- [ ] Transfer only this plan and the approved books spec into that workspace using supported jj file restore or file copying. Preserve all existing telemetry documents and changes in the source workspace.
- [ ] Read applicable guidance and re-read the files below on the execution base. Run the existing targeted checks before editing; distinguish pre-existing failures from regressions.
- [ ] Resolve official Chaptarr and Audiobookshelf images to immutable digests for x86_64-linux. In disposable, isolated containers, verify effective user settings, database filenames/provider, ports, authentication/setup behavior, and state size. Record versions/digests and non-secret findings in the runbook; remove scratch state afterward.

Ownership map:

| Files | Responsibility |
| --- | --- |
| New `modules/fleet/tailscale-services.nix` | Native Service declarations and scoped lifecycle |
| `flake.nix` | Import fleet module and register its check |
| `modules/fleet/bootstrap.nix` | Suppress native advertisement units in bootstrap |
| New `checks/tailscale-services.nix` | Observable native lifecycle and configuration contracts |
| New `modules/services/chaptarr/default.nix` | Chaptarr container, state, mounts, backups, Service |
| `modules/services/media-automation.nix`, `checks/media-automation.nix` | Media role integration and app-specific contract |
| New `modules/services/audiobookshelf/default.nix` | Audiobookshelf container, state, mounts, backups, Service |
| `modules/services/storage-applications.nix`, `checks/storage-applications.nix` | Storage role integration and app-specific contract |
| `checks/remaining-batch.nix` | Bootstrap coverage for native advertisement units |
| New `docs/runbooks/books-services.md` | Versions, activation, acceptance, recovery, rollback |
| `docs/inventory/nfs-mappings.md`, `docs/runbooks/media-automation.md` | New mapping and shared-downloader cross-reference |

Keep `modules/fleet/tailscale-service-proxy.nix` unchanged. Do not add these
Services to `fleet.ingress.routes` or the migrated-identity enrollment mechanism.
No shared storage helper changes are expected; consume the current contract.

## Task 1: Native Tailscale Service Lifecycle

**Files:** Create `modules/fleet/tailscale-services.nix` and `checks/tailscale-services.nix`; modify `flake.nix` and `modules/fleet/bootstrap.nix`.

**Interfaces:**
- Produces `fleet.tailscaleServices.services`, an attribute set keyed by bare Service name (for example `chaptarr`). Each value has `upstream` (loopback HTTP URL string) and `serviceUnit` (application systemd unit string).
- Produces `tailscale-service-<name>.service`, using the main daemon/socket, and `checks.<system>.tailscale-services`.
- Empty declarations produce no units. Names accept lowercase letters, digits, and hyphens; reject invalid names and non-loopback origins.

- [ ] **Write failing configuration tests:** evaluate a fixture declaring `fixture` → `http://127.0.0.1:18081`, dependent on `fixture-app.service`. Assert the unit exists, uses the main daemon, and no migrated identity, secret seed, public ingress route, or open LAN app port is created. Assert invalid names and a `http://10.15.4.9:18081` target fail evaluation.
- [ ] **Run the check before implementation:** `nix build .#checks.x86_64-linux.tailscale-services --no-link -L`; confirm it fails because the check/module interface is missing, not a syntax error in the test.
- [ ] **Implement the minimal module:** typed declarations, per-Service systemd units, bounded daemon/enrollment readiness, retry on transient failure, scoped HTTPS endpoint apply, and reapplication on daemon restart/configuration change. Require the existing Tailscale daemon to be enabled; do not enable or enroll a second daemon.
- [ ] **Define scoped shutdown semantics:** drain the owned Service before endpoint removal. Do not wait indefinitely for clients; preserve in-flight connections according to the pinned CLI's drain behavior and document intentional-removal sequencing. Never issue global reset/`set-config --all` or clear other Services. Ensure normal daemon restart can reapply/advertise after recovery.
- [ ] **Extend the lifecycle test:** seed a distinct unrelated endpoint, apply fixture twice, restart the daemon, change fixture origin to port 18082, drain/remove fixture, and compare unrelated configuration before/after. Assert each origin returns a different fixed response to catch stale-target errors. Simulate failed enrollment and verify bounded failure/retry rather than successful readiness.
- [ ] **Exercise the pinned client:** use the repository's isolated NixOS-test pattern. A fake CLI may validate orchestration failures, but cannot establish real Serve compatibility; also run the actual pinned CLI/daemon with an isolated local API/control-plane fixture supporting Services. Verify persisted Service configuration and target forwarding. If a real control plane is required, retain automated local coverage and record control-plane checks as pending Task 5, not as a passing end-to-end test.
- [ ] **Add bootstrap suppression:** include all `tailscale-service-<name>` units in bootstrap workload masking, without disabling the main daemon. Test a bootstrap fixture has neither running advertisement units nor new persisted Serve declarations.
- [ ] **Run verification:** build the native check again, inspect its result/logs, and confirm unrelated endpoint preservation and bounded failure behavior. No production tailnet commands are used in this task.

## Task 2: Chaptarr and Media Role Integration

**Files:** Create `modules/services/chaptarr/default.nix`; modify `modules/services/media-automation.nix` and `checks/media-automation.nix`.

**Interfaces:**
- Consumes Task 1's `fleet.tailscaleServices.services.chaptarr` declaration.
- Produces `services.fleet.chaptarr.enable`, container `chaptarr`, `podman-chaptarr.service`, and backup `chaptarr-state`.

- [ ] **Extend the failing media contract:** assert the media role enables Chaptarr; port list equals `[ "127.0.0.1:8789:8789" ]`; the image has a verified digest; timezone is `America/Los_Angeles`; no PostgreSQL environment variables or Chaptarr PostgreSQL cluster exist.
- [ ] **Assert storage behavior:** volumes include `/var/lib/media-automation/chaptarr:/config`, `/mnt/bulk/book-library:/books`, `/mnt/bulk/videos:/videos`, and `/mnt/bulk/deluge-downloads:/downloads`. All three NFS mounts list Chaptarr as dependent, and the generated unit binds to the actual mount units. Assert no new downloader container or changes to existing VPN contracts.
- [ ] **Run the contract and observe failure:** `nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); in import ./checks/media-automation.nix { config = f.nixosConfigurations.hl-node-04.config; lib = f.inputs.nixpkgs.lib; }'`; expect an assertion failure for missing Chaptarr.
- [ ] **Implement Chaptarr:** follow the existing Sonarr module's ownership and enablement patterns, use the verified official image, PUID/PGID 1000, local mode-0700 state, and native Service upstream `http://127.0.0.1:8789`. Add the new books NFS source exactly as specified; merge existing video/download mount dependencies without changing sources.
- [ ] **Add the backup contract:** complete local stopped-state capture, daily `*-*-* 06:00:00 America/Los_Angeles`, database class, restrictive permissions, integrity checks for the verified SQLite files, measured payload headroom, and health check compatible with authentication. Do not invent secret enrollment or a restored-state sentinel for this fresh install.
- [ ] **Adjust legacy app lists narrowly:** existing hourly-backup and environment-file assertions apply only to the migrated apps. Include Chaptarr in enablement/digest/loopback checks but test its daily backup and no-artificial-secret behavior separately. Update the expected published-port count from 8 to 9 if that contract still exists on the chosen base.
- [ ] **Run the media contract again:** expect `true`; run the existing media tests unchanged except for deliberate new-app expectations. In isolation, initialize the pinned container and verify SQLite state, UID/GID, and readable downloader mounts. Do not contact or modify live downloaders.

## Task 3: Audiobookshelf and Storage Role Integration

**Files:** Create `modules/services/audiobookshelf/default.nix`; modify `modules/services/storage-applications.nix` and `checks/storage-applications.nix`.

**Interfaces:**
- Consumes Task 1's `fleet.tailscaleServices.services.audiobookshelf` declaration.
- Produces `services.fleet.audiobookshelf.enable`, container `audiobookshelf`, `podman-audiobookshelf.service`, and backup `audiobookshelf-state`.

- [ ] **Extend the failing storage contract:** assert role enablement, port list `[ "127.0.0.1:13378:80" ]`, pinned image, local state mounts `/var/lib/audiobookshelf/config:/config` and `/var/lib/audiobookshelf/metadata:/metadata`, and `/mnt/bulk/book-library:/books:ro`. Assert Kavita retains its original books source and target, and the new source is `nas.tailbc181.ts.net:/mnt/spinners-1/books`.
- [ ] **Run the contract and observe failure:** `nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); in import ./checks/storage-applications.nix { host = f.nixosConfigurations.hl-node-03; lib = f.inputs.nixpkgs.lib; }'`; expect the missing-Audiobookshelf assertion to fail.
- [ ] **Implement Audiobookshelf:** use the verified image's actual non-root user mechanism with local writable state and shared library read access; timezone `America/Los_Angeles`; native upstream `http://127.0.0.1:13378`; no podcasts mount, inherited media GPU setup, migrated identity, empty env-file gate, or restore sentinel.
- [ ] **Implement stopped-state backup:** capture the whole `/var/lib/audiobookshelf` root, including both config and metadata. Use the same daily schedule/backup class as Task 2, verified database integrity checks, restrictive ownership, and measured payload headroom. Preserve progress, covers, users, and authentication state.
- [ ] **Run the storage contract again:** expect `true`. In isolated container validation, scan a small legal audiobook/ebook fixture through the mounted library, confirm metadata/state is writable locally, and verify writes to `/books` fail. Retain behavior tests only where they catch a plausible regression; remove scratch fixtures.

## Task 4: Whole-Fleet Safety, Recovery, and Runbook

**Files:** Modify `checks/remaining-batch.nix`, `docs/inventory/nfs-mappings.md`, and `docs/runbooks/media-automation.md`; create `docs/runbooks/books-services.md`; extend `checks/tailscale-services.nix` if required for cross-host contracts.

**Interfaces:** Consumes both application modules and the native-Service module. Produces tested normal/bootstrap configurations and an operator activation/recovery runbook.

- [ ] **Write cross-host assertions:** hl-node-04 advertises only the new Chaptarr Service and hl-node-03 only the new Audiobookshelf Service; neither creates `tailscale-chaptarr`/`tailscale-audiobookshelf` migrated proxies, identity backups, or seed secrets. Add native units to the existing quarantine check and assert all are disabled in bootstrap.
- [ ] **Run the expanded checks before any corrective integration edits:** identify exact failures, then adjust imports, bootstrap coverage, or role wiring only as needed. Preserve existing production applications and their database versions.
- [ ] **Exercise missing-mount behavior:** reuse the established storage VM scenario with the new consumers' evaluated dependency contracts. A missing mount blocks startup, stopping a mount stops consumers, and no library files appear on the bare local target. Distinguish a stopped mount from a hard-NFS outage that can block I/O.
- [ ] **Exercise backup/recovery in isolation:** initialize non-empty app state and Audiobookshelf progress/metadata, capture backups, rehearse restore, and compare restored observable state. Verify inactive apps remain inactive and failed capture restarts only previously active writers. NAS files remain outside backup payloads.
- [ ] **Write the runbook:** record pinned versions/digests, user mechanism, database paths, ports, exact mount mapping, download-category compatibility, initial setup, daily interruptions, restore rehearsal commands, scoped Service drain/removal, NAS rollback preservation, and Task 5's approval boundary. Add the new inventory NFS mapping and a link from the existing media runbook; do not rewrite historical source observations.
- [ ] **Run targeted verification:** `nix build .#checks.x86_64-linux.remaining-services .#checks.x86_64-linux.remaining-batch .#checks.x86_64-linux.tailscale-services .#checks.x86_64-linux.storage --no-link -L`.
- [ ] **Run repository checks:** `nix fmt -- --check` (or the formatter's supported check form), `nix run .#statix -- check .`, `nix run .#deadnix -- --fail .`, and `nix flake check --no-build`. Format only changed Nix files if unrelated files are unformatted. Evaluate/build normal hl-node-03/04 and bootstrap closures; do not activate them. Native ARM evaluation is required because the fleet module is shared; run ARM checks on the existing supported runner or report that execution limitation honestly.
- [ ] **Review the final diff:** only scoped implementation/docs files changed; no plaintext secrets or moving image tags; no global Serve reset. Record checks actually executed, failures, and pending live acceptance. Ask for commit/push authorization only when delivery is requested; no automatic push, deployment, or manual workflow trigger.

## Task 5: Separately Approved Infrastructure Activation and Acceptance

**Files:** Update `docs/runbooks/books-services.md` with sanitized observed results only. This task changes shared systems and must not run merely because the plan is approved.

**Interfaces:** Consumes reviewed implementation and built host closures. Produces the NAS dataset/export, approved native Services, configured apps, and explicit live acceptance evidence.

- [ ] **Read-only preflight:** inspect actual host tags/client versions, Serve state, name/port conflicts, current access policy, NAS pool capacity/export/snapshot configuration, downloader completed paths/categories, and existing Sonarr settings. Do not log API keys or full application configs. Capture sanitized comparisons sufficient to prove preservation.
- [ ] **Request specific approval:** present exact NAS creation/export/snapshot changes, any required host tag change, Service definitions/approvals/grants, and activation of the reviewed host revisions. Use existing administrative access; if unavailable, give a private local operator workflow rather than requesting pasted credentials.
- [ ] **Create storage after approval:** create only `spinners-1/books`, `audiobooks/`, and `ebooks/`; set verified UID/GID 1000 mapping; authorize the two host clients and include the dataset in the existing NAS protection policy. Validate capacity and permissions from each consumer before enabling writes. Never recursively change unrelated datasets.
- [ ] **Create and approve Services after approval:** TCP 443 definitions for `svc:chaptarr` and `svc:audiobookshelf`, correct tagged hosts, and grants limited to the existing intended users. Enable tailnet HTTPS if separately approved and required. No global policy replacement, broad new token, or unrequested auto-approval.
- [ ] **Activate reviewed closures and initialize securely:** restrict ordinary users until initial administrator setup completes; configure `/books/audiobooks` and `/books/ebooks`, readonly Audiobookshelf libraries, and downloader credentials through private runtime setup. Verify container-to-downloader HTTPS connectivity. Use separate categories when supported, otherwise the spec's single `chaptarr` fallback; preserve Sonarr categories and queues.
- [ ] **Test positive and negative access:** from another tailnet client verify both TLS hostnames and application login; from a client denied by policy verify access fails. Explicitly verify control-plane host approval, not just local Serve configuration. Compare unrelated Serve endpoint behavior and configuration against preflight.
- [ ] **Test the import matrix:** legal audiobook and ebook content via both configured downloaders; verify correct final root, copied content, retained torrent source/seeding state, and unchanged Sonarr behavior. Verify Audiobookshelf scan, stream/seek, progress persistence after restart, and rejected media-file writes. Inspect final rendered login/library states and retain only sanitized review screenshots.
- [ ] **Verify recovery and report:** run `fleet-restore chaptarr-state --rehearsal` and `fleet-restore audiobookshelf-state --rehearsal`, check backup status and NAS snapshot protection, and report repository delivery, deployment, Service approval, and acceptance separately. For rollback, stop only new consumers and drain only their Services; preserve the dataset and imported content.

## Handoff

Review this plan before implementation. Native execution is recommended because
the fleet lifecycle, bootstrap masking, and two app modules share a small set of
interfaces and require combined verification. Subagent-driven execution remains
an option if the operator prefers per-task independent review. Do not interpret
either execution choice as approval for Task 5's shared-state writes.
