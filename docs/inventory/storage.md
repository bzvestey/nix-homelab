# Sanitized storage inventory

`docs/inventory/services.md` is the canonical machine-readable inventory. Every dataset has one unique ID, a placement (`local-copy` or `shared-retained`), source paths, target host when copied, and either positive observed bytes with evidence or a typed blocker with an exact collection command.

Each dataset names its owning services. Every durable embedded or external database references one of the service's datasets; that dataset must belong to the same service and target and explicitly attest that its measured bytes include the database. Database versions are numeric dotted versions or typed blockers. `rebuildable-cache` is a distinct database kind and is never used to excuse durable bytes from dataset accounting.

The 31,269,016,911,730-byte video library is one `shared-video-library` dataset referenced by Deluge, Jellyfin, Radarr, SABnzbd, Sonarr, and Whisparr. The 1,722,285,974,181-byte Kavita library is also `shared-retained`. Neither is copied locally or multiplied by consumer count. Local capacity is the sum of unique `local-copy` datasets per target; shared datasets are excluded.

Deluge config, Publication Manager data/storage, and Tuwunel data remain typed size blockers. They are not represented as zero. Run these read-only commands in the trusted Kubernetes maintenance environment after substituting names discovered with `kubectl get pods -A`; no credentials belong in command arguments or captured output:

```sh
kubectl exec -n <namespace> <deluge-pod> -- du -sb -- /config
kubectl exec -n <namespace> <publication-manager-pod> -- du -sb -- /data /storage
kubectl exec -n <namespace> <tuwunel-pod> -- du -sb -- /var/lib/tuwunel
```

Capacity is accepted only from current byte-accurate `findmnt`/`df -B1` output for the destination filesystem. The readiness gate applies 25% headroom as `sum(local-copy bytes) * 5 <= measured free bytes * 4`.

## Gates

- Schema and consistency (expected green): `nix build .#checks.x86_64-linux.inventory`
- Migration readiness (expected red now): `nix run .#inventory-readiness`

The first command intentionally permits well-typed blockers so non-destructive development can continue. The second rejects every blocker, missing ARM image architecture, and destination with insufficient measured free bytes. Any destructive migration procedure must make the readiness command a prerequisite and stop unless it succeeds; `nix flake check` or the schema check is never migration authorization.

The readiness app imports both validator and inventory from the immutable flake source in the Nix store. It does not read `$PWD`, so invocation by absolute flake path from another directory validates this inventory rather than ambient files.
