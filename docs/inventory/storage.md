# Sanitized storage inventory

`docs/inventory/services.md` is the canonical machine-readable inventory. Every dataset has one unique ID, a placement (`local-copy` or `shared-retained`), source paths, target host when copied, and either positive observed bytes with evidence or a typed blocker with an exact collection command.

Each dataset names its owning services. Every durable embedded or external database references one of the service's datasets; that dataset must belong to the same service and target and explicitly attest that its measured bytes include the database. Database versions are numeric dotted versions or typed blockers. `rebuildable-cache` is a distinct database kind and is never used to excuse durable bytes from dataset accounting.

The 31,269,016,911,730-byte video library is one `shared-video-library` dataset referenced by Deluge, Jellyfin, Radarr, SABnzbd, Sonarr, and Whisparr. The 1,722,285,974,181-byte Kavita library is also `shared-retained`. Neither is copied locally or multiplied by consumer count. Local capacity is the sum of unique `local-copy` datasets per target; shared datasets are excluded.

Immich's `immich-library` is also `shared-retained`, mounted at
`/mnt/bulk/immich` and protected by NAS snapshots. The old 77,778,008,026-byte
observation combined its library and PostgreSQL filesystem; it is not a
separate measured local database size. `immich-data` now names only the local
PG16 cluster `/var/lib/postgres-immich` and remains a typed size blocker until
an independent database measurement is recorded. ML cache is disposable.

Deluge config, Publication Manager data/storage, and Tuwunel data remain typed size blockers. They are not represented as zero. Run these read-only commands in the trusted Kubernetes maintenance environment after substituting names discovered with `kubectl get pods -A`; no credentials belong in command arguments or captured output:

```sh
kubectl exec -n <namespace> <deluge-pod> -- du -sb -- /config
kubectl exec -n <namespace> <publication-manager-pod> -- du -sb -- /data /storage
kubectl exec -n <namespace> <tuwunel-pod> -- du -sb -- /var/lib/tuwunel
```

Capacity is accepted only from current byte-accurate `findmnt`/`df -B1` output for the destination filesystem. The readiness gate applies 25% headroom as `sum(local-copy bytes) * 5 <= measured free bytes * 4`.

## Gates

- Schema and consistency (expected green): `nix build .#checks.x86_64-linux.inventory`
- hl-node-02 repository bootstrap checks: `nix run .#bootstrap-readiness-hl-node-02`
- Production migration readiness (expected red now): `nix run .#inventory-readiness`

The schema check intentionally permits well-typed blockers so non-destructive
development can continue. The production readiness command still rejects every
blocker, missing ARM image architecture, and destination with insufficient
measured free bytes. It must pass before restoring production data or activating
workloads. `nix flake check` or the schema check is never migration authorization.

The separate bootstrap check is only for hl-node-02's empty, quarantined NixOS
installation. It requires schema-valid observed disk/NIC/GPU facts matching
installer pins, masked workloads/databases/runner/backups, no production NFS,
and trusted-signature GitHub-only comin. It deliberately does not require
production dataset sizing, destination filesystem free space, or application
restore acceptance: those remain production blockers, not zero or fabricated
observations. Measure the actual installed destination filesystems after a
separately authorized bootstrap install, never the live ISO's tmpfs.

Passing this repository check is not destructive authorization or complete
physical acceptance. The [Framework runbook](../runbooks/install-framework.md)
also requires current evacuation/backup/rollback evidence, matching signed
CI-cleared media, fresh physical identity and mount checks, stable networking,
recovery-key escrow/readback, PCR policy acknowledgement and explicit approval
to erase the exact disk. It does not enroll secrets or start any service.

Both commands use validator and inventory from the immutable flake source in
the Nix store. They do not read `$PWD`; invocation by absolute flake path from
another directory checks this repository rather than ambient files. These are
static repository checks, not live cluster or device probes.
