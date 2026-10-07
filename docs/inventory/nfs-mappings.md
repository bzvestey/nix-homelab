# TrueNAS NFS mappings

Only retained bulk data is mounted from TrueNAS. Application configuration,
embedded databases, PostgreSQL data, and all other write-sensitive state stay
on local filesystems.

| Dataset | TrueNAS source | NixOS target | Hosts | Classification | Consumers |
| --- | --- | --- | --- | --- | --- |
| `shared-video-library` | `10.15.4.101:/mnt/spinners-1/videos` | `/mnt/bulk/videos` | `hl-node-03`, `hl-node-04` | bulk, shared-retained | Deluge, Jellyfin, Radarr, SABnzbd, Sonarr, Whisparr |
| `kavita-library` | `10.15.4.101:/mnt/spinners-1/Computer/books` | `/mnt/bulk/books` | `hl-node-03` | bulk, shared-retained | Kavita |
| `immich-library` | `10.15.4.101:/mnt/spinners-1/kube-store/immich` | `/mnt/bulk/immich` | `hl-node-02` | bulk, shared-retained | Immich server |

The source facts come from the read-only legacy OpenTofu configuration:
`opentofu/modules/pv/main.tf` identifies `tns-1` as the TrueNAS server and
`/mnt/spinners-1/` export root; the retained service variable files map the
relative `videos`, `Computer/books`, and `kube-store/immich` paths. Immich's
placement follows approved spec section 4.2, not the superseded local-copy
classification. Its old combined 77,778,008,026-byte library/database
observation is not a measured new local database size. NAS snapshots protect
the library; the PG16 cluster is exclusively local. The export still contains
the old `postgres` subtree: do not delete it during this implementation or
mistake it for the destination database.

Each target is a systemd automount backed by an NFS mount unit. The bare
mountpoint is root-owned mode `0555`. A service module consuming one of these
paths must add its unit name to that mount's `dependentUnits`; the storage
module then adds both `RequiresMountsFor` startup ordering and `BindsTo` the
mount unit. Consequently a failed mount blocks startup and a stopped/lost
mount stops the service rather than exposing writable local storage.
