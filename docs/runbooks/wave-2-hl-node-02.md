# Wave 2: hl-node-02 photo and personal services

This is an approval-gated migration procedure, not authorization to install,
enroll, write to Kubernetes, change public routes, or delete source data.
Keep source Kubernetes configuration read-only. Never put passwords, client
secrets, registration tokens, or decrypted TOML in command arguments or logs.

Task 14 preparation is documented in the approval-gated
[source export and offline real-data rehearsal procedure](wave-2-source-rehearsal.md).
It does not authorize source maintenance or certify a production restore.

## Approved handoff scope and source evacuation gate

The offline real-data rehearsal has passed. That evidence does not authorize
evacuation, installation, enrollment or production changes. External Pocket ID
OIDC, Matrix client/federation, existing-session continuity and route gates,
plus fresh final source captures, remain outstanding. Retain private rehearsal
evidence and immutable captures; do not treat them as fresh cutover backups.

Install **bootstrap-only**, not a shadow workload host. The default host imports
`hosts/hl-node-02/bootstrap.nix`: workload/database/runner/Caddy and backup units
are masked, production NFS is removed, and SSH, telemetry, enrollment tools and
signed comin remain. Follow [Framework installation](install-framework.md) for
hardware capture, downloadable ISO/checksum/revision provenance, escrow and TPM
safety. Before boot, publish the signed, CI-cleared bootstrap policy on comin's
switch branch; `fleet.comin.enableMirror = false` selects GitHub only until safe
mirror publication. A production-enabled `main` or unsafe fallback must never
replace bootstrap. Any fallback must be equally safe or disabled.

The existing source worker is **`minastas-home-cluster-w1` at `10.15.4.5`**,
the same address planned for hl-node-02. Before disk destruction or address
takeover, separately approve and evidence evacuation of **all five**
single-instance CNPG primaries: Forgejo, Immich, Mealie, Tranquil PDS and Vikunja.
Each current PDB blocks disruption; a generic drain cannot be assumed safe.
Record fresh read-only pod/node, Cluster, PDB, PVC/PV/storage attachment,
capacity, backup and application-health evidence for every primary and all
other worker workloads. Confirm storage can move to surviving workers; retain
PVCs and source data. No force deletion, PVC recreation or disk wipe is implied.

CNPG **1.28.1** supports temporary `spec.enablePDB = false` and graceful
eviction reusing the existing PVC. Only under a separate reviewed maintenance
plan, with backups, destination capacity and rollback owner/deadline established,
temporarily disable the relevant policy and gracefully relocate one primary at
a time. Preserve PVC identity; verify attachment/detachment, primary health,
application health and **single-writer** status before restoring its original
PDB policy and moving on. Failure is STOP/recovery, not permission to bypass
eviction safety. Capture original policy and restored PDB state for each cluster.

Forgejo and Tranquil PDS have observed Argo `selfHeal`/`prune`; temporary changes
will be reconciled unless their owners are explicitly coordinated. Verify
actual ownership/reconciliation for Immich, Mealie, Vikunja and other workloads
before changes, rather than assuming they are unmanaged. Any reconciliation
suspension/restoration needs explicit approval and evidence. Final evacuation
acceptance requires no remaining source writers/attachments on this worker,
all relocated applications healthy, original protection restored, and a reviewed
rollback/address-release plan. No evacuation commands are authorized here.

## Preflight gates

1. Review and pin the signed local revision; run the focused real-application
   check `nix build .#checks.x86_64-linux.hl-node-02-services`, then the complete
   serialized `nix flake check --show-trace --option max-jobs 1`, formatting,
   Statix and Deadnix. Local fixtures are not evidence of a production restore.
2. Independently verify Framework disk/NIC/GPU identities and installation
   readiness. Use `docs/runbooks/install-framework.md` only after separate
   installer/destructive approval. No reboot or installer is part of Task 13.
   For an empty bootstrap-only installation, first run
   `nix run .#bootstrap-readiness-hl-node-02` and complete the separate live
   evacuation/backup, physical-media/network, escrow and approval gates in
   that runbook. Its success does not clear production restore or activation.
3. Measure the source Immich database independently from its library, the
   Mealie database/state, and Tuwunel RocksDB. Record current destination
   `df -B1`/`findmnt` evidence and 25% headroom after bootstrap has created the
   installed destination filesystems. The old combined Immich byte total is
   invalid for new local sizing. `nix run .#inventory-readiness` must pass
   before production data restore or workload activation; existing capacity,
   backup/restore and database typed blockers remain gates. ISO tmpfs and disk
   capacity are not measured destination free space.
4. Enroll the genuine host recipient only with separate authorization, while
   retaining bootstrap masks and the production-NFS exclusion. Supply
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

### Secret enrollment mapping (separate approval)

Capture the physical host's real `/etc/ssh/ssh_host_ed25519_key.pub` and
fingerprint after boot and prove persistence across reboot. Never fabricate a
public key/age recipient or copy a private host key. Follow `enroll-host.md`:
authorized `fleet-enroll` derives the recipient from that public key; add the
`hl-node-02` anchor and administrator-plus-host rule for
`secrets/hosts/hl-node-02/.*\.yaml` in `.sops.yaml`. Add this Framework host to
`framework-runners` only when separately approved; not `pi-connectors` and not
a universal fleet group. Rewrap only affected ciphertext, inspect metadata-only
diffs and publish signed enrollment changes that **retain bootstrap policy**.

| Consumer | Required root-only runtime mapping |
| --- | --- |
| Immich PG16/server | `/run/secrets/immich.env`: `DB_PASSWORD` |
| Mealie PG17/server | `/run/secrets/mealie.env`: `POSTGRES_PASSWORD`, `OIDC_CLIENT_SECRET` |
| Tuwunel | `/run/secrets/tuwunel.toml`: preserved server identity, registration and OIDC credentials/policy |
| Fleet backups | `/run/secrets/restic-repository`, `/run/secrets/restic-password` (or reviewed configured paths) |
| Tailscale | Credential at the effective configured auth-key runtime path; verify before enrollment |
| Forgejo runner | Separately approved `framework-runners` credential mapping; runner remains masked |

The bootstrap host maps `secrets/hosts/hl-node-02/bootstrap.yaml`'s encrypted
`tailscale-auth-key` to `/run/secrets/tailscale-auth-key`, root-only mode 0400,
and restarts native Tailscale autoconnect on rotation. Deployment must prove
decryption and enrollment without printing the credential. This file does not
provide application, backup or runner credentials or authorize their activation.

This preparation revision imports `hosts/hl-node-02/application-secrets.nix`
in the default host and supplies the required module argument
`_module.args.hlNode02ApplicationSecretsFile = ../../secrets/hosts/hl-node-02/applications.yaml;`
from the host directory. The existing six-entry ciphertext uses the
administrator-plus-genuine-host SOPS rule; administrator and genuine-host
decryption/MAC verification has been recorded without displaying values.
No ciphertext or source identities are replaced by this wiring change.
The module has no fallback file and makes no service enable overrides or
restart requests. All bootstrap masks and the production-NFS exclusion remain.
Publishing this revision, deploying it, installing runtime secrets and activating
consumers each remain separately approval-gated; local wiring is not any of
those actions. Runner enrollment remains separate. Backup destination access
and initialization must follow their separately reviewed approval; do not assume
the observability host's repository or password is suitable.

| Required SOPS key | Runtime destination |
| --- | --- |
| `immich-env` | `/run/secrets/immich.env` |
| `mealie-env` | `/run/secrets/mealie.env` |
| `tuwunel-config` | `/run/secrets/tuwunel.toml` |
| `restic-repository` | `/run/secrets/restic-repository` |
| `restic-password` | `/run/secrets/restic-password` |
| `restic-s3-credentials` | `/run/secrets/restic-s3-credentials` |

All six files are `root:root`, mode `0600`, with empty `restartUnits`.
`fleet.backup.s3CredentialsFile` uses the last runtime path as the AWS shared
credentials file, not credential environment overrides. Supply a valid reviewed
shared-credentials file, not just an access-key value.

The pinned sops-nix policy manages `/run/secrets` as a symlink into
`/run/secrets.d`; the mountpoint and generation directories are `root:keys`,
mode `0751`, not `0700`. Users outside the `keys` group can traverse known
paths but cannot list these directories; non-root users cannot read the
root-owned `0600` files. Do not chmod/chown this
shared directory to make it root-only; that may break other secret consumers.
Verify directory/symlink ownership and target file permissions on the installed
host under separate authorization, without displaying values.

The bootstrap check requires all seven secrets in the actual default host,
including the six application/backup mappings from the correct ciphertext and
the backup shared-credentials path. It also evaluates the complete host's
default imports with a forced disposable synthetic encrypted input, and
separately tests masks with fixture runtime credentials.
SOPS file validation is disabled only in that mapping evaluation to avoid
building fixtures during evaluation; this is **not decryption coverage** or
evidence of enrollment. Prove real decryption without displaying values and
confirm masks remain effective after secret installation. Secret availability
is not permission to start consumers or run backups.

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

The eventual production Immich upload library is an NFS4.1 hard mount from
`nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/immich` to `/mnt/bulk/immich`
over Tailscale. The existing export authorizes hl-node-02's Tailscale address,
`100.72.191.107`; preserve its LAN authorizations and dataset path.
This production mount/automount must be absent throughout bootstrap and isolated
restore; use only an approved snapshot-derived isolated library for rehearsal.
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
dumps, hourly quiesced `tuwunel-state` RocksDB (`/var/lib/tuwunel`), and daily
quiesced `mealie-state` (`/var/lib/mealie`). All three database jobs use the
database alert class (stale at 5,400 seconds); only `mealie-state` uses the
state class (stale at 93,600 seconds). Tuwunel's directory-copy mechanism and
job name do not exempt its database from the RPO of at most one hour.
Capture source-consistent logical dumps and quiesced state
with IDs, checksums and timestamps; production backup evidence remains separate
from the synthetic fixture check.

Bootstrap masks are not an isolated restore environment. A separately reviewed
isolated generation must selectively permit restore/database/application units
while blocking production clients, NFS, tailnet routes, external OIDC/federation,
runner execution, comin replacement and backup timers/production repositories.
Prove isolation before data transfer. Follow `wave-2-source-rehearsal.md` for
Mealie paired-state-first staging, Immich library verification before DB restore,
and Tuwunel state/runtime policy before first startup. Actual restore jobs can
restart apps: review that behavior before allowing any unit through the masks.

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

## Production activation gate

Do not remove bootstrap masks or restore production NFS merely because install,
enrollment or offline restore succeeded. Require fresh final stopped-writer
captures/checksums/snapshot IDs, coherent Mealie DB/state and verified Immich
library, restore/rollback evidence, real external OIDC and Matrix/session
continuity, and separately approved route checks. Approve a signed, CI-cleared
activation revision explicitly, reviewing every unmasked workload/database,
Caddy route, NFS mount and backup destination/timer. Preserve single-writer
ownership throughout cutover; runner activation remains independently gated.
Keep source PVCs, snapshots, prior signed generation and rollback access until
separate retirement approval. No activation or retirement is authorized here.
