# Immich pgvector 0.8.0 → 0.8.7

Status: isolated rehearsal and **approved production migration completed** on
2026-10-31. Database checks and service recovery passed; the user subsequently
confirmed Immich is working as expected.
Scope: `hl-node-02`, native `postgres-immich.service`, database `app`, Unix
socket `/run/postgres-immich`, port `5433`. Keep PostgreSQL 16 and VectorChord
0.4.3. Do not combine this operation with a PostgreSQL major upgrade, VectorChord
upgrade, host reboot, or media-library restore.

## Read-only preflight — 2026-10-30, approximately 23:00 UTC

- PostgreSQL 16.15 is running with `shared_preload_libraries = vchord`.
- Installed extension metadata: `public.vector` 0.8.0, `public.vchord` 0.4.3.
  Available default versions: vector 0.8.7 and vchord 0.4.3.
- `pg_available_extension_versions` exposes only vector 0.8.7 as installable
  under the current package. Creating vector 0.8.0 in a fresh database requires
  staging the old extension package first; the installed 0.8.0 catalog is not
  evidence that the current package can freshly install that version.
- PostgreSQL reports a complete update chain:
  `0.8.0--0.8.1--0.8.2--0.8.3--0.8.4--0.8.5--0.8.6--0.8.7`.
  Installed scripts were inspected: intermediate scripts have no migration DDL;
  the final script adds documentation comments. The updated native library is
  already deployed. Catalog version alone does not identify loaded library code.
- `public.face_index` on `public.face_search`: `vchordrq`, valid and ready,
  approximately 13 MB. `public.clip_index` on `public.smart_search`: `vchordrq`,
  valid and ready, approximately 59 MB. No HNSW or IVFFlat indexes found.
- `vchord` depends on `vector`; do not drop either extension or use CASCADE.
- Database approximately 326 MB; `/var/lib` approximately 1.4 TB available.
  Immich media NFS mount is present. No failed systemd units; Immich ping passes.
- Scheduled `fleet-backup-immich-db` succeeded at 22:16:49 UTC, payload
  94,931,020 bytes. Read-only Restic listing confirms snapshot
  `5eee3a2fe71030e4639ea094aa4cd1c36466c6aa29a60741b0e550467d89e6e0`,
  captured at 22:16:46 UTC with tag `fleet-job=immich-db`.
  Snapshot presence is **not** a restore or integrity test.

SQL inspection used `BEGIN READ ONLY` and a 30-second statement timeout. Restic
listing used `--no-cache --no-lock`; no backup, restore, ALTER, REINDEX, service
stop/start, database creation, or repository write was performed for preflight.
Recheck all observations immediately before an approved maintenance window.

Evidence in this thread's workspace: `.amp/in/artifacts/software-update/`
`pgvector-preflight.log`, `pgvector-backup-preflight.log`,
`pgvector-upgrade-scripts-and-snapshot.log` (scripts plus an initial unavailable
CLI error), and `pgvector-snapshot-preflight.json` (successful repository read).
These are local review artifacts, not committed backup data.

## Isolated rehearsal results — 2026-10-31

The exact snapshot above was retrieved read-only with Restic `--no-cache
--no-lock`. Its `database.dump` was restored into a disposable local PostgreSQL
16.15 cluster, restricted to a private Unix socket with TCP listening disabled.
No production service was stopped and no production database write was made.

The complete sequence passed:

1. Restore using pgvector 0.8.0 and VectorChord 0.4.3, preserving `app` ownership.
2. Stop the local cluster and restart with the deployed PostgreSQL/plugin
   package. Verify the vector catalog still reports 0.8.0.
3. Execute the bounded ALTER transaction below. It completed in **0.014 seconds**
   locally and changed vector to 0.8.7, leaving vchord at 0.4.3.
4. Restart the local cluster and repeat validation.
5. Restore the same pre-migration backup into a second empty database under the
   current package, explicitly selecting vector 0.8.7 and vchord 0.4.3. Repeat
   validation. This proves recovery into the current version, not an in-place
   downgrade. The initial restore separately exercised recovery into 0.8.0.

Across all five states, **72 public tables / 405,681 rows** had identical counts
and order-independent row-content fingerprints. Face and CLIP tables contained
4,635 and 21,021 vectors respectively. Both vector index definitions remained
identical, valid and ready. Three deterministic stored-vector probes per table
tested top-10 cosine neighbors: six probes per state, each through the actual
vector index and an exact sequential-search control. Plans verified both paths;
distance profiles agreed within 0.000001 and sampled neighbor sets were unchanged
across states. Queries used `SET vchordrq.probes=1`, matching the indexes' single
list. No manual REINDEX was performed; a logical restore naturally builds indexes.

Local dump imports took **16.084 seconds** (old version) and **16.846 seconds**
(current-version recovery), excluding validation. These are single local timings,
not production downtime estimates or performance benchmarks. The rehearsal does
not test concurrent writers, production locking, all possible search inputs,
authenticated Immich UI/API behavior, media availability, or OIDC. Full
application acceptance remains required during the approved production operation.

Two preliminary harness runs were discarded: the startup check initially targeted
the not-yet-created `app` database, and vector searches initially omitted the
required probe setting. Both were corrected before the complete passing run.
The local cluster was stopped and private backup/cluster/query-result files were
removed afterwards. Only sanitized aggregate evidence and the reproduction helper
remain in `.amp/in/artifacts/software-update/pgvector-rehearsal*`.

The user subsequently approved the production maintenance procedure; its execution
is recorded below. The rehearsal itself did not authorize production changes.

## Production execution — 2026-10-31, 02:55–03:00 UTC

- Rechecked PostgreSQL 16.15, the deployed plugin package, available upgrade
  chain, both healthy `vchordrq` indexes, free space, media NFS mount and Immich
  ping. Comin was idle on the expected signed revision. Its original suspension
  state was false; the database backup timer and Immich were active.
- Suspended Comin, paused `fleet-backup-immich-db.timer`, confirmed no backup was
  running, and stopped Immich at **02:55:14 UTC**. Confirmed no other sessions in
  `app`. PostgreSQL and ML stayed running.
- Completed a fresh stopped-writer backup at 02:55:53 UTC, captured at
  02:55:50 UTC: snapshot
  `18d212e84c68da843d541a34594e4c045ad88b5af08262879beab3f497d207e0`.
  Payload: 94,931,000 bytes. Downloaded this exact snapshot and restored it into
  the isolated 0.8.0 cluster. All baseline counts, content fingerprints, vector
  index definitions and sampled search results matched. The disposable cluster
  was stopped after validation.
- At **02:58:18 UTC**, executed the bounded transaction once, additionally
  guarding the expected initial extension versions and absence of other database
  sessions. ALTER took **1.952 ms**; COMMIT succeeded. Catalog versions now read
  vector **0.8.7**, vchord **0.4.3**. No REINDEX, extension drop, database restore,
  PostgreSQL restart, media changes or host reboot was performed in production.
- Before restarting writers, all **72 tables / 405,681 rows** retained identical
  counts and content fingerprints. Both index definitions remained unchanged,
  valid and ready. Six top-10 face/CLIP probes retained their results and agreed
  with exact sequential controls within 0.000001; plans verified the index paths.
- Started Immich at 02:58:40 UTC; API ping and both API/microservices startup
  completion passed at **02:58:44 UTC**. Observed API interruption: approximately
  **3 minutes 30 seconds**, mostly backup and validation. Startup logs contained
  no ERROR/FATAL lines. ML ping passed; zero service restarts or failed units.
  The tailnet HTTPS API ping also passed, and application database sessions
  reconnected normally.
- Verified another backup after migration (17 seconds, result success), restored
  the timer to active, and resumed Comin. Next timer deadline was 03:16:16 UTC.
  Final checks at 02:59:56 UTC confirmed healthy services, healthy indexes,
  expected extension versions and unsuspended Comin with deployment done.

Validation notes: an initial restore-comparison assertion compared Python tuples
with JSON arrays; decoded snapshots proved every field matched. Normalized the
comparison and reran the full restore check successfully before ALTER. A first
migration invocation stopped at its service-state guard, before SQL: the planned
Immich stop exited 143 and systemd labeled it failed rather than inactive. Verified
the container had been removed, MainPID was zero and database sessions were zero;
then used those actual stopped-writer conditions for the guard. The subsequent
application start cleared that transient failed state.

**User acceptance:** the user subsequently reported “Immich is working as
expected.” No existing Immich API credential was available for automated
signed-in semantic/face API searches. Database-level searches and API/worker
startup checks passed; no credentials or temporary accounts were created.
The user confirmation does not establish that each authenticated search path
was individually exercised by the automated checks.

Sanitized phase summaries and execution logs are local review artifacts under
`.amp/in/artifacts/software-update/pgvector-production*`. Private dump, local
database, application logs and identifying query results were removed after
verification. This runbook remains a local, uncommitted document until separately
requested for delivery.

## Index maintenance decision

The [versioned pgvector changelog](https://github.com/pgvector/pgvector/blob/v0.8.7/CHANGELOG.md)
lists HNSW vacuum-corruption fixes and HNSW/IVFFlat build fixes in this range.
The inspected update scripts do not rebuild indexes. The observed indexes are
VectorChord `vchordrq`, and VectorChord is not being upgraded. **Do not blindly
REINDEX the production database.** No mandatory rebuild for these two indexes
was identified in the reviewed pgvector notes. This is not proof of absence of
existing corruption: validate copied-data searches and plans in rehearsal.
If index inventory changes or validation fails, stop and review before expanding
the maintenance scope.

## Approval gates and isolated rehearsal

The following steps write data or affect availability and require explicit
approval. Read-only preflight does not authorize them.

1. Obtain approval to retrieve a selected backup into protected scratch storage
   and restore it into an **isolated disposable PostgreSQL 16 cluster**. Prepare
   both pgvector 0.8.0 and the deployed 0.8.7 packages, keeping VectorChord 0.4.3.
   Restrict permissions and network access; do not put private data in review
   artifacts or Git.
2. Use the backup tools described in [backup-restore.md](backup-restore.md).
   `fleet-restore immich-db --snapshot ID --rehearsal` is an existing payload
   validation drill, but it creates a temporary database on the live cluster.
   It is not read-only and is not an isolated application migration rehearsal.
   Do not use `--force` merely to rehearse.
3. Start the disposable cluster with the 0.8.0 extension package and restore the
   selected payload's `database.dump`. Explicitly create `vector VERSION '0.8.0'`
   and `vchord VERSION '0.4.3'` before restoring. Check metadata after restore.
   Stop the disposable cluster, switch to the deployed PostgreSQL 16.15 plus
   pgvector 0.8.7/VectorChord 0.4.3 packages, then restart it. Check that catalog
   version remains 0.8.0 and target 0.8.7 is available, matching production.
   A plain dump/restore into the new package can choose the available default
   0.8.7 and accidentally skip the transition under test.
   Use suitable fixture roles or `pg_restore --no-owner --no-acl --exit-on-error`
   for the isolated validation; production ownership must remain unchanged.
4. Record table counts, index definitions/validity, extension versions, and
   representative nearest-neighbor results before migration. Do not export
   embeddings, identities, tokens or private asset identifiers into the report.
   Exercise both face and CLIP vector queries; inspect plans to ensure an index
   path is tested as well as an exact sequential-search control. Approximate
   results need application-appropriate recall/tie handling, not arbitrary exact
   equality of every approximate neighbor.
5. Run the bounded ALTER transaction below in the isolated database. Confirm
   vector 0.8.7, unchanged vchord 0.4.3, unchanged data counts and healthy search
   indexes. Validate representative searches again. Record duration and errors.
6. Rehearse recovery from the selected backup as well. Decide the recovery
   target explicitly: restoring under current packages normally selects vector
   0.8.7. Recovering the old catalog state requires staging the 0.8.0 extension
   package in an isolated recovery cluster before restoring, then testing the
   package transition as above. Neither is a catalog-only in-place downgrade.
7. Obtain separate production approval after reviewing rehearsal results, the
   recovery procedure, and the expected maintenance duration. Do not promise a
   duration before measuring on copied data.

## Production procedure — only after approval

Run on node02 as root. Use the current PostgreSQL package's `psql`, not a client
from a different cluster. The preflight used `runuser -u postgres-immich -- psql
-X -h /run/postgres-immich -p 5433 -d app` successfully.

1. Repeat version/path/index/readiness/free-space checks. Stop if they differ
   materially from the approved rehearsal. Coordinate Comin/deployment activity
   so no competing activation changes the packages during maintenance.
2. Record whether `fleet-backup-immich-db.timer` is active and pause it for this
   operation; wait for any already-running backup to complete. Record the
   original application service state. Stop `podman-immich.service` (server and
   background workers). Keep PostgreSQL running. ML alone is not a database
   writer and need not be stopped. Confirm app sessions have drained; do not
   terminate unexpected sessions without investigating them.
3. While writers remain stopped, run `fleet-backup-run immich-db` and require
   success. Record the **exact new snapshot ID**, verify it is reachable and
   restore-validated using the approved process. Do not reuse an old `latest`
   reference as the rollback target. The database dump does not back up the NFS
   media library; this operation must not modify media.
4. Run this transaction once. `ON_ERROR_STOP` and connection close roll back
   an uncommitted failure; do not automatically restart the application on error.

   ```sql
   \set ON_ERROR_STOP on
   BEGIN;
   SET LOCAL lock_timeout = '5s';
   SET LOCAL statement_timeout = '60s';
   ALTER EXTENSION vector UPDATE TO '0.8.7';
   SELECT extname, extversion FROM pg_extension
   WHERE extname IN ('vector', 'vchord') ORDER BY extname;
   COMMIT;
   ```

   Require vector 0.8.7 and vchord 0.4.3. If the lock/statement timeout fires,
   investigate blocking sessions or the mismatch with rehearsal; do not simply
   remove the bounds. No DROP EXTENSION, CASCADE, or blanket REINDEX is planned.
5. Check counts, index readiness/validity and representative vector queries
   against the stopped-writer baseline. Retain a failure for investigation rather
   than running unreviewed repair commands.
6. Start Immich only after database checks pass. Verify `/api/server/ping`,
   application logs, authenticated semantic search and face search, and worker
   behavior. A ping alone is insufficient. Confirm no restart loop or failed
   systemd units. Restore the timer's original active/inactive state and confirm
   subsequent backups succeed. Record versions and the migration outcome.

## Failure and recovery

- Before COMMIT: a failed transaction leaves the old catalog version intact.
  Recheck it; keep Immich stopped while deciding whether to retry or abort.
- After COMMIT: do not attempt an unverified `ALTER ... UPDATE TO '0.8.0'`;
  no downgrade path has been established. Keep writers stopped on validation
  failure. Prefer a diagnosed forward fix or the rehearsed restore of the exact
  pre-migration snapshot, with explicit approval for destructive recovery.
- `fleet-restore immich-db --snapshot ID --force` is destructive and first
  creates another backup. Its importer recreates `app`; a normal restore may
  use vector 0.8.7 by default. It is **not** an automatic rollback to 0.8.0 and
  must not be used as one without the rehearsed version/ownership procedure.
- Restoring loses database writes since the chosen snapshot. Keeping writers
  stopped until acceptance minimizes that loss; do not overwrite current data
  silently. Leave the timer paused on unresolved failure and report its state.

No restart of PostgreSQL or host reboot is planned for this catalog update.
If rehearsal establishes a need for either, obtain approval for the expanded
operation before production execution.
