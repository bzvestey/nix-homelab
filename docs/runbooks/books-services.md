# Books services: preparation, activation, and recovery

## Delivery boundary

The repository defines Chaptarr on hl-node-04 and Audiobookshelf on hl-node-03.
The operator created the NAS dataset/share and native Tailscale Services, then
explicitly authorized deployment. Both hosts were activated on 2026-11-02;
see production execution below. No NAS or tailnet policy was changed by this
deployment. Future changes to shared resources require separate approval.
Review the books spec and implementation plan under `docs/superpowers/`.

## Pinned releases and local validation

Images resolved and exercised as amd64 on 2026-11-02:

| App | Release | Image digest |
| --- | --- | --- |
| Chaptarr | 0.9.965.0-Release-chaptarr-dev-chaptarr | `docker.io/chaptarr/chaptarr@sha256:bb00d67cbe1485d1cd61ef178362a29b42aa08f86b290841aab4b115ad2647a6` |
| Audiobookshelf | 2.37.2 | `ghcr.io/advplyr/audiobookshelf@sha256:37c2057e150694970442579815c646fe6bdc01c95b9d1547c4c9068be8844ef3` |

Chaptarr starts with PUID/PGID 1000 and SQLite databases `chaptarr.db`,
`logs.db`, `cache.db`, and `staging.db` under `/config`. No PostgreSQL variables
are supplied. Initial local state measured approximately 2.2 MiB.

Audiobookshelf runs as `1000:1000` (the image's `node` user); it does not use
PUID/PGID. Non-root binding to port 80 failed in the isolated probe, so the
module uses supported `PORT=13378` and publishes `127.0.0.1:13378:13378`.
This deliberately differs from the design's default container port 80 without
adding privileges or changing the user-facing origin. The local database is
`/config/absdatabase.sqlite`; initial config/metadata measured under 1 MiB.
The probe verified writable local metadata and rejected writes to `/books`.
Both applications answered HTTP 200 at `/` and `/ping` in isolated containers.
These probes are not live library/import or Tailscale acceptance evidence.

Repository validation passed: `nix flake check -L`, all-system evaluation,
Statix, Deadnix, and changed-file formatting. The native-Service VM exercises
the pinned CLI against a controlled Unix LocalAPI fixture, including scoped
apply/drain/clear, app and daemon restarts, failed enrollment, and automatic
retry after advertisement preference failures. It does not exercise a real
control plane or VPN forwarding. Isolated restore rehearsals passed for both
initialized application states; a deliberately corrupted SQLite database was
rejected. Library scan, playback progress, and downloader imports still need
live acceptance. ARM configurations were evaluated, not executed.

## Storage layout

| Purpose | NAS export | Host path | Container path |
| --- | --- | --- | --- |
| New organized library | `/mnt/spinners-1/books` | `/mnt/bulk/book-library` on both hosts | Chaptarr `/books` RW; Audiobookshelf `/books` RO |
| Existing shared downloads/video | `/mnt/spinners-1/videos` | `/mnt/bulk/videos` on hl-node-04 | Chaptarr `/videos` |
| Existing Deluge downloads | `/mnt/spinners-1/kube-store/deluge/downloads` | `/mnt/bulk/deluge-downloads` on hl-node-04 | Chaptarr `/downloads` |

All exports use `nas.tailbc181.ts.net`. The new library has `audiobooks/` and
`ebooks/`. Kavita's `Computer/books` export and `/mnt/bulk/books` are unchanged.
Downloaders retain their current paths and do not mount the final books library.
Imports cross ZFS datasets and copy; do not enable a hardlink-only workflow or
delete torrent sources that remain in use for seeding.

Local state is `/var/lib/media-automation/chaptarr` and
`/var/lib/audiobookshelf/{config,metadata}`. State belongs to 1000:1000, with
mode-0700 directories. Do not put configuration or SQLite files on NFS. Services
depend on the actual NFS mounts and stop when mounts stop. Hard-mounted NAS
outages may block I/O; they are not instant service-stop signals.

## Read-only preflight and required approval

1. Inspect hl-node-03/04 client versions, host tags, loopback-port availability,
   and existing Serve state. Preserve a restricted comparison of unrelated
   endpoints; do not publish identity keys or full secret-bearing configs.
2. Inspect NAS capacity, datasets/exports, client identity mapping, snapshot
   policy, and current Sonarr/download-client settings without changing them.
3. Confirm the pre-created Services have the intended HTTPS endpoints and
   policy's intended client population. Hosts must have tag-based identities
   and Tailscale v1.86 or newer. The locked repository client is v1.104.2.
4. Reuse the operator-created `spinners-1/books` dataset/export and native
   Services. Obtain approval before activating reviewed host closures or
   changing NAS/tailnet settings. Verify existing snapshot protection, grants,
   and Service host auto-approval rather than replacing them. Any missing host
   tags require specific approval; do not silently change ownership.

Read-only host preflight on 2026-11-02 confirmed both hosts were running with
`tag:nix-homelab`, and neither had existing main-daemon Serve endpoints or
Services. Both clients reported v1.104.2, and ports 8789/13378 were unused on
both hosts. The host tailnet IPv4 addresses are `100.94.96.109` (hl-node-03)
and `100.112.143.27` (hl-node-04); confirm the new NFS export authorizes these
identities rather than assuming their LAN addresses are used.

Both proposed app names already appear in Tailscale's extra DNS records:
Chaptarr at `100.99.187.172` and Audiobookshelf at `100.93.193.48`. HTTPS
connection attempts from the workstation and hl-node-04 timed out. These
observations do not establish ownership, approved hosts, or access policy.
The operator subsequently confirmed these are pre-created native Services for
this deployment and expects host auto-approval. Reuse them; do not recreate
them or change policy. Effective auto-approval and access remain to be verified
when the hosts advertise their endpoints.

The operator also confirmed creation of `spinners-1/books` and its NFS share.
Both hosts reach NAS TCP 2049 and independently report the export
`/mnt/spinners-1/books` authorized for `100.94.96.109`, `100.112.143.27`, and
`100.80.22.54`. Neither host currently mounts the new export. Export discovery
confirms the advertised client list, not successful mount/write access or
UID/GID mapping; those checks remain activation gates.

Sonarr's active download clients are Deluge at `deluge.tailbc181.ts.net:443`
with TLS and category `tv-sonarr`, and SABnzbd at
`sabnzbd.tailbc181.ts.net:443` with TLS and category `tv`. Sonarr has no remote
path mappings. Both downloader HTTPS roots answered 200 from hl-node-04.
Deluge uses `/videos/downloading`, moves completed data to
`/videos/downloaded/deluge`, and has `add_paused=true`. SABnzbd uses the same
incomplete/completed directories and currently defines `*`, `movies`, `tv`,
`audio`, and `software` categories. Preserve these existing settings; new
Chaptarr categories have not been created. Both existing NFS media/download
roots report ownership 1000:1000; this is not proof of the new export's mapping.

NAS authenticated preflight is blocked: available SSH identities were rejected,
the HTTPS API requires authentication, and the existing Kubernetes API endpoint
used to retrieve its CSI credential is unreachable from this workstation.
Capacity, UID/GID mapping, and snapshot policy remain independently unverified.
Dataset/share creation is operator-confirmed and export discovery is verified
above. No credentials were printed and no shared-state changes were made.

## Approved activation sequence

1. Reuse the existing dataset/export. After activation approval, verify both
   consumer mounts, UID/GID 1000 writes, and required read access through actual
   NFS mapping before enabling imports. Create only missing `audiobooks/` and
   `ebooks/` directories within the mounted books dataset. Do not recursively
   change other datasets. Confirm snapshot protection before importing media.
2. Reuse pre-created `svc:chaptarr` and `svc:audiobookshelf` on TCP 443. Preserve
   existing grants and the operator's auto-approval configuration. Do not
   recreate Services or broaden access. Any required policy correction needs
   separate approval; no new broad API token is needed.
3. Activate reviewed closures. `tailscale-service-chaptarr.service` and
   `tailscale-service-audiobookshelf.service` use the existing host socket and
   automatically configure/advertise their individual HTTPS endpoints. Verify
   hl-node-04 is auto-approved for Chaptarr and hl-node-03 for Audiobookshelf.
   If approval is pending, diagnose the existing policy before requesting any
   change. Local CLI success alone does not establish approval or reachability.
4. Keep ordinary-user access restricted while creating initial administrator
   accounts. Enable application authentication before widening access. Enter
   downloader credentials privately, never in Nix, shell arguments, or chat.
5. Set Chaptarr roots `/books/audiobooks` and `/books/ebooks`. Connect to the
   existing Deluge and SABnzbd HTTPS tailnet endpoints; test connectivity from
   inside Chaptarr's container. Host loopback is not container loopback.
6. Inspect the pinned application's per-media download-client category support.
   Prefer `chaptarr-audiobooks` and `chaptarr-ebooks`; if the client exposes only
   one category, use `chaptarr` and select final roots by media type. Preserve
   Sonarr's categories, remote-path mappings, queues, and downloader credentials.
   Map remote paths only where observed paths differ from `/videos`/`/downloads`.
7. Add separate Audiobookshelf audiobook/ebook libraries under the same paths.
   Its media mount is intentionally read-only: media-file rewrites, embedded
   tags, merging, and podcast downloads are not part of this setup.

User URLs are `https://chaptarr.tailbc181.ts.net` and
`https://audiobookshelf.tailbc181.ts.net`. There are no new migrated per-app
Tailscale identities, Caddy sites, Funnel routes, or LAN listeners. Linux clients
before v1.94 may need route acceptance; do not alter unrelated routing globally.

## Acceptance checklist

- From an allowed second tailnet client, validate both certificates, login, and
  application responses; from a denied client, confirm access is rejected.
- Verify the control plane reports the correct approved host for each Service.
  Compare unrelated Serve state and behavior with preflight.
- Import legal audiobook and ebook fixtures through both downloaders. Verify
  final roots, copy semantics, continued torrent seeding, and unchanged Sonarr
  operation. Do not use production downloads as disposable test data.
- Scan the Audiobookshelf libraries, stream/seek, record progress, restart, and
  verify progress survives. Confirm media writes fail and local metadata works.
- In an isolated environment, stop each consumed mount and verify consumer
  shutdown with no local fallback writes. Do not disrupt live shared mounts.
- Verify scheduled backups, restore rehearsals, and NAS snapshot protection.
  Inspect rendered setup/library states if performing UI setup; retain only
  sanitized final screenshots.

## Backups, recovery, and rollback

`chaptarr-state` and `audiobookshelf-state` use full stopped-state captures daily
at 06:00 America/Los_Angeles, so brief application interruptions are expected.
Only previously active units restart. Captures include local credentials,
database state, covers, and metadata, but not NAS media/downloads. Chaptarr uses
the fleet default 1 GiB payload limit; Audiobookshelf has 4 GiB for metadata
growth. Review measured sizes as the library grows. Restore validates SQLite
integrity and restores 1000:1000 ownership, 0600 files, and 0700 directories.

Run `fleet-restore chaptarr-state --rehearsal` on hl-node-04 and
`fleet-restore audiobookshelf-state --rehearsal` on hl-node-03 before declaring
recovery ready. A final restore is a separately coordinated destructive action
against the destination's local state; do not substitute it for rehearsal.

To roll back, stop only the new applications and advertisement units. Unit stop
drains the owned Service but leaves configuration in place for existing sessions.
After sessions have disconnected, intentional decommissioning may use
`tailscale serve clear svc:chaptarr` or `tailscale serve clear svc:audiobookshelf`
on the respective host. Do not use `tailscale serve reset`, replace all Serve
configuration, stop the host daemon, or delete the books dataset/imported files.
Remove only the new declarations when rolling back configuration. Bootstrap
disables both native advertisement units, containers, backups, and NAS mounts;
it is not a decommissioning tool for already-persisted production identities.

## Production execution — 2026-11-02

The operator authorized deployment after confirming pre-created Services and
the books dataset/export. Activated these persistent system closures directly
over trusted SSH, without publishing repository changes:

| Host | Previous system | Deployed system |
| --- | --- | --- |
| hl-node-03 | `/nix/store/c17db9hn4m0cbswmvv5bkihnggsb995h-nixos-system-hl-node-03-26.11.20261027.31ecbac` | `/nix/store/nn597134a6jwk2m8xh11789x1vcig8gf-nixos-system-hl-node-03-26.11.20261027.31ecbac` |
| hl-node-04 | `/nix/store/gq2807nrsw733ch5zjxjbj0706j0dwhy-nixos-system-hl-node-04-26.11.20261027.31ecbac` | `/nix/store/hd4x98r0gwsr1ncll0sf2bn3gvj6x0sx-nixos-system-hl-node-04-26.11.20261027.31ecbac` |

- Scoped private-namespace NFS mounts on both hosts verified actual read/write
  access as UID/GID 1000. Created missing `audiobooks/` and `ebooks/` directories
  as 1000:1000, mode 0755. Temporary probe files and mounts were removed.
- Reviewed dry activations. Secret-removal warnings also occur with the running
  baseline: old and new secret manifests are identical, and SOPS recreates the
  custom-path symlinks. Existing application secret paths remained readable
  after activation. No secret-enrollment changes were needed.
- Both applications and native advertisement units are active. Chaptarr's four
  database files have SQLite headers; both local `/ping` endpoints are healthy.
- Both Service HTTPS roots returned 200 from the workstation over IPv4 and
  IPv6 with certificate verification enabled. Initial timeouts cleared without
  policy changes. Host netmaps assign the Audiobookshelf VIPs/primary routes to
  hl-node-03 and Chaptarr VIPs/primary routes to hl-node-04, confirming effective
  host approval rather than only local advertisement.
- Audiobookshelf can read both library directories, its media write probe fails
  with EROFS, and local config/metadata are writable.
- Existing Jellyfin, Kavita, Vikunja, Sonarr, SABnzbd, and Deluge remain active
  and their HTTPS roots return 200 or the expected 302. Neither host reports
  failed units. Both new backup timers are active; next run is 06:00 Los Angeles
  time (14:00 UTC on this date).
- Comin was suspended only during activation, then resumed on both hosts.
  Both running systems and persistent system profiles match the deployed
  closures. No reboot is required. The operator subsequently authorized signed
  publication of these declarations and this execution record to `main`, so
  GitOps can reproduce the books deployment rather than overwrite it with the
  previous configuration. Direct activation alone did not publish source changes.

## Outstanding live evidence and setup

Initial administrator setup, Chaptarr root folders/download-client credentials
and categories, and Audiobookshelf library configuration remain to be completed
privately. No downloader settings, queues, or credentials were changed during
deployment. Do not widen access before application authentication is configured.

NAS capacity/snapshot protection, denied-client access, downloader imports and
continued torrent seeding, streaming/progress persistence, and production
backup/recovery remain unverified. Active backup timers are not evidence of a
completed production backup. Repository checks and successful HTTPS roots do
not satisfy these remaining acceptance gates.
