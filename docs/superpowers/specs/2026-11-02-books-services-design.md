# Chaptarr and Audiobookshelf with native Tailscale Services

## Status and intended outcome

The operator approved this architecture for specification: Chaptarr on
hl-node-04, Audiobookshelf on hl-node-03, a new TrueNAS books dataset, and
native Tailscale Services advertised by the existing host daemons. This spec
requires review before an implementation plan is written. It does not authorize
deployment, NAS writes, tailnet policy changes, or service activation.

Chaptarr manages audiobook and ebook acquisition using the same Deluge and
SABnzbd instances as Sonarr. Audiobookshelf serves the resulting library.
Chaptarr uses SQLite, not PostgreSQL. Both applications have stable, private
HTTPS Service addresses independent of host placement.

## Evidence and boundaries

- `modules/services/media-automation.nix` enables Sonarr, Deluge, and SABnzbd
  through the developer-media-services role on hl-node-04. Containers use
  Podman, digest-pinned images, local state, and loopback published ports.
- `modules/services/storage-applications.nix` enables the storage applications
  on hl-node-03. Kavita already uses `/mnt/bulk/books` for the separate
  `spinners-1/Computer/books` library; do not reuse that mount name or target.
- Existing ingress creates migrated, per-application Tailscale identities.
  Native Services must not enter that mechanism or require identity seed files.
- Existing storage modules bind consumers to NFS mounts, preventing local
  fallback writes. Bootstrap configurations disable workloads and NAS mounts.
- Upstream Chaptarr documents container port 8789, `/config`, PUID/PGID, and
  default SQLite storage. Audiobookshelf documents container port 80 and
  separate `/config` and `/metadata`; its configuration must be local.
- Tailscale requires tagged service hosts and administrative Service definition
  and host approval. Actual hl-node-03/04 tags, client versions, existing Serve
  state, NAS exports, and downloader settings have not been inspected live.

## Architecture and alternatives

Use each host's existing `tailscaled` to terminate HTTPS and proxy to its local
application. Add a focused fleet module for native Service declarations; keep
the migrated-identity module unchanged. Application modules own their Service
name and loopback target.

Dedicated tagged daemons would isolate enrollment and state, but add secrets,
identity backups, and additional processes without a requirement for that
isolation. Separate migrated identities would not implement the requested
Tailscale Services feature. Neither alternative is selected.

| Application | Host | Container origin | Tailscale Service | User URL |
| --- | --- | --- | --- | --- |
| Chaptarr | hl-node-04 | `127.0.0.1:8789` → container 8789 | `svc:chaptarr` | `https://chaptarr.tailbc181.ts.net` |
| Audiobookshelf | hl-node-03 | `127.0.0.1:13378` → container 80 | `svc:audiobookshelf` | `https://audiobookshelf.tailbc181.ts.net` |

Check port availability and DNS/Service-name collisions before activation.
Neither app has a public route, Funnel endpoint, LAN listener, Caddy site, or
separate Tailscale node. Preserve all existing application routes and identities.

## TrueNAS storage and permissions

Create dataset `spinners-1/books` at `/mnt/spinners-1/books`, a sibling of
`spinners-1/videos`. Create `audiobooks/` and `ebooks/` beneath it. Do not move,
merge, rename, or delete existing video, download, or Kavita data.

Export the dataset over NFS to the two consumers using
`nas.tailbc181.ts.net:/mnt/spinners-1/books`. Authorize only the required host
identities/addresses under the existing NAS policy. Match the existing media
UID/GID 1000 ownership and grant the Chaptarr writer access without broadening
permissions on unrelated datasets. Verify actual NFS identity mapping, not just
the configured numeric IDs. Include the dataset in NAS snapshot/retention
protection; application backups do not duplicate bulk library content.

On both hosts declare `fleet.storage.nfsMounts.book-library`, targeting
`/mnt/bulk/book-library`. Mount that directory as `/books` in both containers.
Chaptarr gets read/write access; Audiobookshelf gets read-only access. Configure
Chaptarr root folders `/books/audiobooks` and `/books/ebooks`, and corresponding
separate Audiobookshelf libraries. Chaptarr owns media organization; library
rewrites, embedded-tag editing, and media-file manipulation in Audiobookshelf
are outside this read-only serving setup. Covers and server metadata stay local.

Use the existing fail-closed mount contract for both consumers. Do not create
library subdirectories with host tmpfiles rules under an unmounted NFS path.
Preserve hard NFS mounts and stop dependents when mounts stop; do not claim a
hard-mounted server outage instantly stops blocked I/O.

## Shared downloaders and import flow

Do not deploy additional downloaders or change Deluge's Gluetun/VPN isolation.
Chaptarr connects to the existing downloader HTTPS tailnet endpoints, using
their existing credentials. Confirm those endpoints work from the Chaptarr
container rather than assuming its loopback reaches the host.

Inspect actual completed-download locations, Sonarr remote-path mappings, and
downloader categories before configuring Chaptarr. Preserve existing jobs and
Sonarr settings. Use distinct `chaptarr-audiobooks` and `chaptarr-ebooks`
categories/labels where supported by the pinned Chaptarr/download-client
versions; verify each media type is routed correctly without changing Sonarr's
categories. If a client only supports a single Chaptarr category, use
`chaptarr` and let Chaptarr select the final root by media type.

Give Chaptarr the existing `/mnt/bulk/videos:/videos` mount and
`/mnt/bulk/deluge-downloads:/downloads` mount so it can read both documented
download locations with identical container paths. Register it as a dependent
of each consumed NFS mount. Add remote-path mappings only for actual path
differences observed at runtime. Existing downloader write paths remain
unchanged; downloaders do not need access to the final books dataset.

Downloads and the final library are separate ZFS datasets: imports must copy,
not rely on hardlinks or atomic cross-filesystem renames. Preserve torrent
seeding data and configure Chaptarr's import behavior accordingly. Account for
the temporary duplicate storage. Do not relocate download directories to gain
hardlinks in this change.

## Application state, packaging, and authentication

Add focused `modules/services/chaptarr/default.nix` and
`modules/services/audiobookshelf/default.nix` modules following existing service
enablement patterns. Enable Chaptarr in the media role and Audiobookshelf in
the storage role. Resolve supported upstream images to immutable digests and
verify the target architecture; do not copy moving tags into the final config.
Use `America/Los_Angeles` for both applications.

Chaptarr state is `/var/lib/media-automation/chaptarr`, mounted at `/config`,
owned 1000:1000 with restrictive permissions. Use the image's PUID/PGID
mechanism. Do not set PostgreSQL variables or provision a PostgreSQL service.
Verify SQLite database filenames and effective database provider against the
pinned release before defining integrity checks.

Audiobookshelf state is `/var/lib/audiobookshelf`, with separate local
`config/` and `metadata/` directories mounted at `/config` and `/metadata`.
Verify the pinned image's supported user mechanism and run it with access to
these state directories and read access to the library; do not assume it
honors LinuxServer PUID/PGID variables. Podcasts are not part of this setup.

Keep application authentication enabled. Create initial administrators through
a restricted setup session before granting ordinary users access. Downloader
passwords/API keys remain in application state or existing encrypted runtime
secret enrollment, never in the Nix store or documentation. Do not introduce
empty secret files as an artificial startup prerequisite for these fresh apps.

## Native Tailscale Service lifecycle

Provide a small, typed fleet declaration mapping native Service names to
loopback HTTP origins. Reconcile only each declared Service's HTTPS 443
endpoint using the pinned Tailscale CLI's supported `serve --service=svc:...`
interface. Never use a global Serve reset, replace all Service configuration,
change host enrollment, or touch migrated service identity state.

Use systemd units ordered after the host daemon, its enrollment, and the
application. Bound CLI calls/readiness waits and retry transient failures.
Reapply configuration following daemon restart and relevant configuration
changes. On intentional removal or host relocation, drain only the affected
Service before removing its endpoint; preserve all unrelated Serve settings.
Do not report advertisement as proof of control-plane approval or application
health. A temporarily unavailable origin must not trigger a global reset.

Before activation, verify that each host is tagged and runs a supported client
(upstream minimum v1.86). If tags are missing, propose a narrowly scoped tag
change for approval instead of silently changing device ownership. Define
`svc:chaptarr` and `svc:audiobookshelf` with TCP 443 endpoints and approve the
correct host advertisements. Use existing authorized administrator access; no
new broad API token is required for routine host operation.

Keep client access within the tailnet's existing intended user population and
require grants to these Services on 443. Do not widen access to all members by
default. Preserve existing policy rules. Manual host approval is the baseline;
adding auto-approval policy is unnecessary. Ensure tailnet HTTPS is enabled.
Clients before v1.94 may need route acceptance; document this compatibility
requirement rather than changing unrelated client routing preferences.

Bootstrap must disable native Service advertisement units as well as the app
containers and NFS mounts. No new advertisements may escape quarantine.

## Backups and recovery

Use existing fleet state backup/restore helpers. For the initial deployment,
take complete stopped-state captures to avoid guessing either application's
database layout or snapshot consistency across databases and metadata. Schedule
daily at the established 06:00 America/Los_Angeles window; declare service
interruption explicitly and restart only previously active units.

Capture all Chaptarr configuration/databases and Audiobookshelf config/metadata
under their respective local state roots. Preserve credentials, user progress,
library definitions, covers, and ownership. Set realistic payload limits from
measured initial state with growth headroom. Do not include `/books`, `/videos`,
or `/downloads`. Use database backup classification and restrictive archive and
restore permissions. Validate discovered SQLite files with integrity checks
and rehearse restore before calling recovery ready.

Native Service definitions/approvals belong to the tailnet control plane;
endpoint declarations are reproducible from Nix. Preserve the existing host
daemon state and its recovery process; do not invent separate service identity
backup files. Rollback must not delete the dataset or imported files. Disable
new consumers and drain their Services while preserving existing workloads.

## Verification and delivery

Implementation extends existing media/storage contract checks and adds focused
native-Service coverage. Check image digests, enablement, SQLite/no PostgreSQL,
loopback-only origins, distinct library mounts, NFS dependencies, backups,
absence of migrated identity enrollment, and bootstrap suppression.

Exercise reconciliation in isolation: first apply, repeat apply, daemon restart,
failed enrollment, endpoint change, and scoped drain/removal. A pre-existing
unrelated Serve endpoint must survive every operation. A denied or pending
Service must not be presented as reachable. Test supported CLI behavior using
the pinned client, not only command-string assertions.

After separately approved activation, verify dataset/export permissions and
mount failure behavior, then test each Service from another tailnet device.
Confirm TLS hostname, authentication, denied access for an unauthorized client,
Audiobookshelf streaming/seeking and progress persistence. Exercise both book
types through each configured downloader using operator-provided legal test
content; verify final paths, copy-based imports, continued torrent seeding, and
unchanged Sonarr operation. Confirm read-only Audiobookshelf media access and
successful backup/restore rehearsal. Inspect representative rendered setup and
library states if UI configuration is part of activation.

Repository checks alone establish configuration correctness, not a created NAS
dataset, approved Service, or working live deployment. Report those delivery
states separately. Shared NAS and tailnet changes and deployment require
specific approval after implementation is reviewed.

## References

- Chaptarr deployment and SQLite: <https://github.com/Chaptarr/chaptarr>
- Audiobookshelf configuration/storage: <https://www.audiobookshelf.org/docs/>
- Tailscale Services requirements and lifecycle:
  <https://tailscale.com/kb/1552/tailscale-services>
- Existing repository contracts: `modules/fleet/storage.nix`,
  `modules/fleet/prepared-applications.nix`, `modules/fleet/bootstrap.nix`,
  `lib/application-backups.nix`, and `docs/runbooks/media-automation.md`.
