# Sanitized storage inventory

Read-only `du -sb` inside running workload containers and CNPG volume inspection were captured 2026-10-02. Values are point-in-time bytes, not PVC requests. Names of private storage servers, volume handles, IPs, and credentials are omitted.

| Dataset | Bytes | Migration treatment |
|---|---:|---|
| Shared video library (same mounted dataset seen by Jellyfin/Radarr/Sonarr/SABnzbd/Whisparr) | 31,269,016,911,730 | Remains external NAS; do not multiply or copy locally |
| Kavita synchronized library | 1,722,285,974,181 | Remains external NAS |
| Immich library/cache mount | 76,295,716,162 | Copy once with database-consistent cutover |
| Forgejo database filesystem | 95,259,551,875 | `pg_dump` plus verification |
| Forgejo repositories | 30,370,144 | Restic/file copy |
| Kavita config | 53,121,923,548 | SQLite-consistent backup |
| Tranquil PDS PostgreSQL filesystem | 2,570,103,626 | `pg_dump`; CNPG object backup has no successful recovery point |
| Immich PostgreSQL filesystem | 1,482,291,864 | Logical backup and asset-count verification |
| Mealie PostgreSQL filesystem | 786,531,894 | Logical backup |
| Vikunja PostgreSQL filesystem | 841,127,261 | Logical backup |
| Manyfold models / PostgreSQL | 606,461,500 / 623,633,105 | Deferred pending export/archive decision |
| Gitea PostgreSQL | 651,266,197 | Deferred pending export/archive decision |

Exact source sizes for Deluge config, Publication Manager, and Tuwunel remain **BLOCKED**: each read-only container `du` attempt returned no usable result. These zero placeholders in the machine-readable service inventory must be replaced before those services are authorized for migration. PVC requested capacity is not used as a substitute for actual bytes.

The local capacity gate uses each Kubernetes node's reported allocatable ephemeral-storage as conservative free capacity and requires `actualBytes * 1.25 <= freeBytes`. External NAS datasets are explicitly retained in place and are excluded from local-copy bytes.
