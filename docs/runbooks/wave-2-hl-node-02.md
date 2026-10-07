# Wave 2: hl-node-02 photo and personal services

This is an approval-gated migration procedure, not authorization to install,
enroll, write to Kubernetes, change public routes, or delete source data.
Keep source Kubernetes configuration read-only. Never put passwords, client
secrets, registration tokens, or decrypted TOML in command arguments or logs.

## Preflight gates

1. Review and pin the signed local revision; run the focused real-application
   check `nix build .#checks.x86_64-linux.hl-node-02-services`, then the complete
   serialized `nix flake check --show-trace --option max-jobs 1`, formatting,
   Statix and Deadnix. Local fixtures are not evidence of a production restore.
2. Independently verify Framework disk/NIC/GPU identities and installation
   readiness. Use `docs/runbooks/install-framework.md` only after separate
   installer/destructive approval. No reboot or installer is part of Task 13.
3. Measure the source Immich database independently from its library, the
   Mealie database/state, and Tuwunel RocksDB. Record current destination
   `df -B1`/`findmnt` evidence and 25% headroom. The old combined Immich byte
   total is invalid for new local sizing. `nix run .#inventory-readiness` must
   pass before a physical migration; existing typed blockers remain gates.
4. Enroll the genuine host recipient only with separate authorization. Supply
   root-only runtime files `/run/secrets/immich.env` (`DB_PASSWORD`),
   `/run/secrets/mealie.env` (`POSTGRES_PASSWORD`, `OIDC_CLIENT_SECRET`), and
   `/run/secrets/tuwunel.toml`, plus fleet backup and Tailscale credentials,
   through the fleet secret-management policy. Missing files deliberately
   leave applications/databases stopped. Do not create plaintext substitutes.
5. Preserve these exact application pins:
   - Immich server: `79cc1623323d5894922686d8743b4780181428f98eecbfb58ce12c41ef02d1ea`.
   - Immich ML: `60dfcf266a9ef3b7376f5678e8c980d4fb61db5fc48c078fe8a326ab1535d60d`.
   - Mealie: `8b02290f4d1806f02acac6f25f6d48a3c965612fda1f8e914d5af533276f8688`.
   - Tuwunel: `678b7f5350e06a41614444497c587da9dddf66767e4068a27480402f3c1367d0`.

## Placement and compatibility

Immich uses native PG16 on loopback port 5433, socket `/run/postgres-immich`,
and `/var/lib/postgres-immich`, under `postgres-immich`. Mealie uses the stock
native PG17 singleton on loopback port 5432, socket `/run/postgresql`, and
`/var/lib/postgresql/17`, under `postgres`. Both retain database/role `app`,
but each cluster has a distinct password, OS user, socket, port and directory.
Patch security updates are permitted; a major migration is not.

Restore Immich's observed cube 1.5, earthdistance 1.2, pg_trgm 1.6, unaccent
1.1, uuid-ossp 1.1, vector 0.8.0 and vchord 0.4.3. VectorChord is loaded by
PG16 only. Confirm `pg_extension` versions after restore and exercise a real
VectorChord index and application migrations before acceptance. Mealie retains
PG17/pg_trgm 1.6. Reject a restore that changes these contracts without proof.

The Immich upload library is an NFS4.1 hard mount from
`10.15.4.101:/mnt/spinners-1/kube-store/immich` to `/mnt/bulk/immich`.
An unavailable startup mount blocks the server; stopping the mount stops only
Immich. A server/network outage on an existing hard mount can block I/O, not
fall back to local writes. Restore/recovery must never remount local storage
over that path. Protect library bytes using NAS snapshots, retaining snapshot
IDs and sampled asset checks. Leave the old `postgres` export subtree intact
until a separately approved source-retirement procedure.

Dragonfly uses local loopback port 6380; it is not a second remote dependency.
ML's `/var/cache/immich-ml` is explicitly disposable and excluded from backups.
Immich persistent settings, including OIDC, travel in `immich-db`; do not
invent a new client secret or an independent `immich-state` job.

Mealie retains `https://mealie.tailbc181.ts.net`, Pocket ID discovery
`https://id.minastas.xyz/.well-known/openid-configuration`, public client ID
`9bff51ba-d97c-4838-9bae-ac3d3ff2ae8c`, groups `core_users`/`admin`, signup,
redirect and remember-me enabled, and password login disabled.
Tuwunel's runtime TOML must preserve server `matrix.minastas.social`, local
database path `/var/lib/tuwunel`, port 8008, registration token, federation,
password-login policy, and Pocket ID provider (`brand = "pocket-id"`, name
`PocketID`, public client ID `9c05911b-c58f-449f-9792-40e87bb25b12`, issuer
`https://id.minastas.xyz`, default true, userid claim `preferred_username`,
callback `https://matrix.minastas.social/_matrix/client/unstable/login/sso/callback/9c05911b-c58f-449f-9792-40e87bb25b12`).
Its address is `0.0.0.0` **inside its isolated container**; only host loopback
8008 is published. Remove all retired Hookshot appservice configuration,
registration, credentials and `/webhook` route. Do not migrate its cryptostore.

## Backups, isolated rehearsal and cutover

Four jobs protect real local state: hourly `immich-db` and `mealie-db` logical
dumps, daily quiesced `mealie-state` (`/var/lib/mealie`) and `tuwunel-state`
(`/var/lib/tuwunel`). Capture source-consistent logical dumps and quiesced state
with IDs, checksums and timestamps; production backup evidence remains separate
from the synthetic fixture check.

On an authorized isolated destination, initialize matching native clusters and
runtime credentials first. Run `fleet-restore <job> --rehearsal` before any
mutation. Stop the relevant application, then restore the selected explicit
snapshot using `fleet-restore <job> --snapshot <id>`. Database clusters are
necessarily nonempty: after reviewing the destination and pre-restore backup,
use `--force` for the database job only on the approved isolated destination.
Never remove an active PostgreSQL data directory. Database restore drops only
that cluster's `app` database, then creates it with owner `app` and imports the
logical dump. State restore requires an empty stopped target unless an explicit
`--force` approval accepts its protective pre-restore backup.

Verify exact asymmetric records, application settings/OIDC, asset counts and
sampled original/thumbnail rendering, Mealie recipe files/DB ownership, and
Tuwunel account/device/message/media continuity. Probe real endpoints:
`/api/server/ping` (2283), `/api/app/about` (9000), and
`/_matrix/client/versions` (8008). Check local Caddy tailnet routes for Immich
and Mealie and public `matrix.minastas.social` through origin 8080. Follow
`route-cutover.md` only after separate approval and all restore gates.

Record journals, Immich 8081/8082 telemetry and all four fleet backup/restore
metrics without secret values. A failed post-mutation restore leaves the
application stopped: investigate, select the explicit protective snapshot and
repeat the approved isolated recovery. The other application's database must
remain unchanged. Rollback keeps source workloads, NAS snapshots, original
logical dumps and the prior signed Nix generation intact. Source retirement,
runner enrollment, public route cutover and production writes are separate
authorization gates.
