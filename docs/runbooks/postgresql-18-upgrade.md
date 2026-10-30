# Immich, Mealie and Vikunja: PostgreSQL 18 migration

Status: configuration and isolated database restore rehearsals prepared locally.
The user approved continuation on 2026-10-31. Refreshed read-only preflight at
03:38 UTC confirmed all three applications healthy, no invalid indexes or
additional non-template databases beyond `app` and `postgres`, successful last
database backups, and idle Comin on nodes02/03. Publication and cutover are
deferred until the active Pi builds finish; **no production major-version
migration or push has occurred**.

## Scope and targets

| Application | Host | Current PostgreSQL | Target | Live data directory |
| --- | --- | --- | --- | --- |
| Immich | hl-node-02, 10.15.4.5 | 16.15 | 18.6 | `/var/lib/postgres-immich` |
| Mealie | hl-node-02, 10.15.4.5 | 17.11 | 18.6 | `/var/lib/postgresql/17` → `/var/lib/postgresql/18` |
| Vikunja | hl-node-03, 10.15.4.7 | 17.11 | 18.6 | `/var/lib/postgres-vikunja` |

Immich additionally moves VectorChord 0.4.3 → **1.1.1**, retaining pgvector
**0.8.7**. Use the pinned nixpkgs PostgreSQL 18 extensions rather than the old
PG16-specific prebuilt library. PostgreSQL 19rc1 is not a stable target.
Forgejo and Tranquil PDS already use PG18 and are outside this migration.

Keep existing database/role `app`, runtime secret files, peer authentication,
loopback ports (Immich 5433, Mealie 5432, Vikunja 5434), application containers,
media/files and OIDC settings unchanged. Do not combine application releases,
reboots or unrelated infrastructure changes with this work.

Sources checked on 2026-10-31:

- [PostgreSQL release/version policy](https://www.postgresql.org/support/versioning/):
  stable 18.6; major upgrades require dump/reload or pg_upgrade.
- [VectorChord releases](https://github.com/supervc-stack/VectorChord/releases):
  stable 1.1.1. PG18 binaries first appeared in 0.5.3; use PG18-built extensions.
- Immich v3.3.5 versioned constants allow PostgreSQL `>=14`, VectorChord
  `>=0.3 <2` and pgvector `>=0.5 <1`. A compatible range alone is not validation.

## Safety boundaries

This is a **logical dump/restore into new clusters**, not an in-place ALTER of
the old VectorChord catalog or reuse of a PG16/17 data directory with PG18.
Logical restore builds new indexes using the target extension. Never copy old
index files, DROP EXTENSION CASCADE, or blindly REINDEX the live database.

Immich and Vikunja's existing native cluster startup checks reject a mismatched
PG_VERSION. Mealie now also refuses to initialize an empty PG18 directory while
its old PG17 cluster exists. These guards prevent silent data replacement, but
do not perform a migration. **Do not let Comin activate these changes before the
new clusters are restored and validated.**

Suspend Comin on nodes02/03 before publishing the migration configuration, after
confirming no deployment is running. Do not push unrelated revisions while the
Pi rollout is building: past pushes cancelled those builds. Publishing and
production cutover require the user's explicit delivery authorization.

## Isolated restore rehearsal

Selected existing backups are fetched read-only with Restic `--no-cache
--no-lock`; no production backup job, database write or service restart is needed
for this rehearsal. Store all dumps, restored data and identifying results in
0700 scratch storage, never in Git or review artifacts. Use a private 0700 Unix
socket, disable TCP and host authentication, and preload vchord only for Immich.

For each exact snapshot:

1. Verify its `fleet-job=<application>-db` tag and archive shape: only `./` and
   regular `./database.dump`, within the job's size limit.
2. Restore into the source-major package, with the expected extension versions,
   an `app` role and database ownership preserved. Use matching-major pg_restore.
3. Independently restore the same dump into a fresh PG18 cluster with the target
   extensions. Fail on every restore error; do not suppress unsupported settings
   or omit unknown schema objects to obtain a passing result.
4. Compare every public table's row count and order-independent row-content
   fingerprint, table ownership and sequence definitions/values. For Immich,
   verify both vector indexes' definitions, valid/ready flags and actual index
   plans; compare sampled face/CLIP cosine neighbors against exact sequential
   controls. Use suitable probe settings, distance tolerance and tie handling.
5. Stop all disposable clusters and remove private data. Retain only aggregate
   results and reproduction commands under local review artifacts.

All three database rehearsals passed using real backup payloads. Source and
target content fingerprints, owners and sequences matched:

| Application | Public tables | Rows | Result |
| --- | --- | --- | --- |
| Immich | 72 | 405,681 | PG16.15/vchord 0.4.3 → PG18.6/vchord 1.1.1; six indexed/exact search probes also matched |
| Mealie | 69 | 6,998 | PG17.11 → PG18.6 |
| Vikunja | 42 | 17,241 | PG17.11 → PG18.6 |

Exact snapshot IDs, capture times and aggregate fingerprints are in the local
`pg18-rehearsal-summary.json` review artifact. These are existing backup states,
not necessarily current application state. Fresh stopped-writer backups and
validation are still required for cutover. The existing node02 VM test also
exercises actual Immich/Mealie startup, vector queries, backup/restore and
failure cases under the target versions. Database restore checks alone do not
prove authenticated UI, attachment/media access, OIDC or every query.

## Production cutover — only after delivery authorization

Treat node02 as one maintenance group: stop writers and stage **both** Immich
and Mealie before activating its shared system closure, then validate and start
each independently. Migrate node03/Vikunja separately after accepting node02.
Coordinate both hosts' activation so no unrestored cluster is started by Comin.
Build/copy the verified old and new system closures before beginning downtime;
retain the old closure and exact PostgreSQL/plugin packages for recovery. Apply
the following gates to every application in the host's maintenance group.

1. Record the current system closure, PostgreSQL package/configuration, extension
   versions, database ownership, other databases/roles, index definitions,
   application health, failed units, free space, mounts, backup timer state and
   Comin suspension state. Investigate any extra database: an `app`-only dump is
   insufficient if another database shares the cluster. Stop on material drift.
2. Suspend idle Comin. Pause this application's database backup timer and wait
   for an active backup to finish. Record writer/service state, stop its
   `podman-<application>.service`, and confirm application database sessions have
   drained. Do not terminate unexpected sessions without investigating.
3. With the **old PostgreSQL still running**, execute `fleet-backup-run
   <application>-db`. Require success; record the exact new snapshot ID, not a
   floating `latest`. Restore-validate that exact backup under PG18 and compare
   with the stopped-writer baseline before replacing any live data directory.
4. Stage a fresh target cluster as its production OS owner, using PG18 initdb,
   `--encoding=UTF8 --locale=C`, private socket and no exposed TCP listener.
   Create/restore required roles and `app` ownership, then restore with PG18
   pg_restore `--exit-on-error`. For Immich preload vchord 1.1.1 and confirm
   vector 0.8.7. Restore all application objects/permissions and validate data,
   sequences, indexes and sampled queries. Do not log credentials or embeddings.
5. Stop both old and staged clusters cleanly. Retain the complete old cluster:
   for Immich/Vikunja, move it to a clearly labeled sibling recovery directory
   and move the staged target to the original service data path. For Mealie,
   leave `/var/lib/postgresql/17` intact and put the staged target in
   `/var/lib/postgresql/18`. Preserve the correct postgres OS owner and 0700
   modes. Keep old secret/configuration references available privately.
6. Activate the reviewed target system closure with Comin still suspended.
   Ensure automatic application startup cannot precede the database validation
   gate; use temporary runtime masks for affected writer units if required,
   recording and later removing only masks created by this maintenance.
   The systemd configuration must select the correct new database path/package,
   existing authentication rules and runtime credentials. Confirm the database
   role password via the existing setup mechanism, not by copying a secret into
   the Nix store or shell output.
7. Check server version 18.6, expected extension versions, table fingerprints,
   ownership, sequence state, index readiness and representative read queries
   while writers remain stopped. Stop for any mismatch. Start the application
   only after all checks pass; do not automatically roll back or repair on error.
8. Verify API and worker startup, logs, no restart loop, normal database sessions,
   application data and media/attachments. Require signed-in semantic/face
   search for Immich, recipe/search access for Mealie, and project/task access
   for Vikunja. API ping alone is not acceptance. Obtain a signed-in user check
   if no authorized test credential is available; do not invent credentials or
   create accounts merely to bypass the acceptance gate.
9. Restore each timer to its original state; verify a successful backup using
   the **PG18** tools and correct data path. Restore Comin's original suspension
   state only when all affected services have passed. Remove only temporary
   runtime masks/overrides created by this operation. Record versions, exact
   snapshots, timings and acceptance outcomes. Retain old data until the user
   explicitly approves its eventual removal.

## Recovery

Before writer acceptance, retain the original PG16/17 cluster, its exact old
system closure, configuration and pre-cutover backup. A code-only rollback is
not a PostgreSQL downgrade: **never point the old server at PG18 data**.

If validation fails, leave affected writers stopped and report the exact state.
With explicit recovery approval, stop PG18, preserve its cluster for diagnosis,
restore the original old-major directory/path and old system configuration, and
recheck versions, secrets, ownership and application health before resuming.
Mealie's old cluster must be served by PG17, not PG18, despite both directories
remaining on disk. Do not delete either cluster automatically.

Once production writers have resumed, switching back to the old cluster loses
all subsequent database writes. Recovery then needs a diagnosed forward fix or
an explicit data reconciliation/loss decision. Do not promise that a PG18 dump
can be restored into PG16/17, or that VectorChord has an in-place downgrade path.
The database migration does not restore or modify NFS media, Mealie files or
Vikunja attachments; keep those independent backups and mounts intact.
