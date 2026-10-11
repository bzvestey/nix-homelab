# Remaining fleet migration batch

## Approved outcome

Prepare hl-node-03, hl-node-04 and hl-node-01 together so each can be replaced
and restored without designing its services or rebuilding its installer during
the outage. Preserve existing application versions, identities and NFS data.
This preparation does not stop source services, erase disks or activate new
writers. The operator approved implementation and the corrected placement.

## Placement

- hl-node-01: Pocket ID, Homarr, Donetick, CommaFeed, Mailrise, Wallos and the
  Cloudflare connector. Embedded databases stay on local storage.
- hl-node-03: Jellyfin, Kavita, Vikunja and one Forgejo runner. Videos/books
  remain on their existing NAS exports over Tailscale; application state and
  Vikunja PostgreSQL are local.
- hl-node-04: Deluge with VPN and port forwarding, Prowlarr, Radarr, Sonarr,
  Whisparr, SABnzbd, publication manager and one Forgejo runner. Preserve
  downloader/media path relationships and never allow Deluge VPN bypass.
- Remaining hl-node-02 prerequisites: Forgejo, Foundry, Tangled Knot and
  Tranquil PDS. Their source services currently survive in Kubernetes and must
  move before the last worker is removed. Existing Immich/Mealie/Matrix remain
  untouched while these configurations are prepared.

## Installation and activation

Reuse the proven Framework disk layout and installer, with remotely observed
whole-disk by-id links and distinct permanent MACs assigning lan0/lan1.
Retain untagged VLAN 4, active-backup networking and packaged RTL8156 firmware.
Generalize the existing node-02 bootstrap split to all remaining nodes. Images
boot a quarantined configuration with workloads, backups and Comin disabled;
active closures are separate outputs, prepared in the same batch. Restoring
state and enrolling secrets must not require reflashing an image.

Do not fabricate host recipients or put private keys in images. Prepare secret
contracts before installation; enrollment adds each actual SSH-derived age
recipient and supplies encrypted application, service-identity and per-host
Garage credentials. Secret-only updates can rebuild a small activation closure
without rebuilding installation media. Preserve migrated Tailscale service
identities using the existing userspace proxy implementation.

## State, ingress and sequencing

Reuse fleet backup/restore contracts. PostgreSQL uses local version-compatible
clusters and logical dumps. Embedded databases use stopped-writer directory
captures including WAL/journal and application identity files. Backups are
automatic after activation, hourly for databases. Bulk NAS exports remain in
place; only application/database state is restored to local storage.

Before worker 3 evacuation, stage the future Pi applications on already
installed NixOS hardware using the same modules and private state directories.
Export the source secrets, identities and final state before Kubernetes becomes
unavailable. Move shared public ingress outside Kubernetes before worker 3 is
removed. Preserve existing DNS/URLs, OIDC identities and encrypted rollback
captures. Move the temporary Pi workloads to hl-node-01 last, using the same
stopped-writer procedure; never run duplicate Tailscale identities or writers.

## Validation and delivery

Use observable configuration/restore tests and focused service checks rather
than repeated full-fleet VM runs. Validate source-compatible image digests,
ARM64 variants, runtime secret boundaries, bootstrap masks, database locality,
NFS mount dependencies, port uniqueness and backup coverage. Build affected
closures and all three image artifacts in one revision-bound batch. Include
Pi image download packaging, checksums and manifests, not only a store path.
Keep actual cutover and destructive hardware steps outside this preparation.
