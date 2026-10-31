# Immich, Mealie and Vikunja: PostgreSQL 18 migration

Status: signed upgrade commit `55f2ffe52a7e6eccde451795dad2c1e2dcc2a198`
published to main on 2026-10-31. Pi recovery is complete. **All three applications
are running on PostgreSQL 18.6**, with VectorChord 1.1.1 and pgvector 0.8.7 for
Immich. Database/API checks and post-upgrade backups passed. The user accepted
all three applications. Comin is resumed on nodes02/03 and has deployed the
signed target on both hosts. All three original active database backup timers
are running. Original clusters and verified pre-cutover backups remain retained.

## Scope and targets

| Application | Host | Source PostgreSQL | Target | Live data directory |
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
   Retain a verified copy with an additional migration-specific tag before
   creating another same-hour backup: the normal hourly retention policy may
   otherwise expire this exact snapshot. `--group-by tags` separates that copy
   from normal rolling backups. Preserve its original capture time in the log.
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
   gate using a temporary unit drop-in with a `ConditionPathExists` pointing
   at an absent maintenance permit file. Check `systemctl cat` and the effective
   condition before stopping writers. **Do not rely on `mask --runtime`: the
   NixOS units in `/etc/systemd/system` outrank masks in `/run/systemd/system`.**
   Remove only this maintenance drop-in after database validation, daemon-reload
   and explicitly start the application.
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

## Production execution — node02, 2026-10-31

- Pi00 recovery copied all three matching kernel outputs from Pi01; Pi00 then
  built and activated the signed target without recompiling the kernel. Both
  temporary Comin overrides were removed after activation. Both Pis' readiness
  endpoints passed; Loki's initial readiness delay recovered without changes.
- Refreshed preflight confirmed expected source versions, only `app`/`postgres`
  databases and healthy applications. Suspended idle Comin on nodes02/03 before
  pushing the signed upgrade. Copied both target host closures before downtime.
- Stopped node02 writers at **14:41 UTC**, with both app database session counts
  zero. Captured and retrieved exact fresh backups at 14:41:59/14:42:04 UTC.
  Restored them into private Unix-only PG18 clusters under their production OS
  owners. Immich's 72 tables / 405,687 rows and Mealie's 69 tables / 6,998 rows
  matched source content fingerprints and ownership. Immich index definitions
  and six indexed/exact vector search probes matched.
- Validation detected a genuine identity-sequence representation difference:
  `naturalearth_countries_tmp_id_seq1` was `bigint` with maximum 2147483647 on
  PG16, but its dump's `ADD GENERATED ... AS IDENTITY` omits the sequence type,
  so PG18 selected `integer` from the column. On the **staged target only**,
  used `ALTER SEQUENCE public.naturalearth_countries_tmp_id_seq1 AS bigint
  MAXVALUE 2147483647`. Full source/target validation then passed, including all
  sequence fields/values. No source database was modified by that adjustment.
  A separate tuple-versus-JSON-array comparison issue was normalized in the
  scratch harness; no data or assertion fields were discarded.
- Stopped original and staged clusters, retained the original Immich cluster at
  `/var/lib/postgres-immich-pg16-preserved-20261031`, left Mealie's original
  `/var/lib/postgresql/17` intact, and moved the validated PG18 clusters into
  their service paths. Activated the target closure successfully.
- **Ordering deviation:** temporary runtime masks did not block the higher
  priority `/etc` units. Activation started Mealie at **14:46:29 UTC** and
  Immich at **14:46:30 UTC**, before the intended post-activation stopped-writer
  check. Both restored clusters had already passed the full comparison before
  activation. No rollback was attempted after writers resumed. The procedure
  above now requires an explicit absent-file startup condition for Vikunja.
- Live checks confirmed PG18.6, expected extension versions, original ownership
  and index definitions, valid indexes and exact/indexed vector agreement.
  Mealie's content fingerprints still matched completely; Immich's only changed
  table fingerprint was `system_metadata` after app startup. This is an
  observation, not a claim that live writes were compared to a frozen snapshot.
  Immich API, worker and ML startup and Mealie API passed; no service restarts
  or failed systemd units were observed. Approximate API interruption: 5½ minutes.
- Both PG18 backup jobs subsequently succeeded, and both database timers are
  active. Removed the two maintenance runtime masks. Retained the old system
  closure/packages with GC root
  `/nix/var/nix/gcroots/pg18-preupgrade-node02-20261031`.
- Normal same-hour backup retention expired the initial pre-cutover snapshot
  metadata. The untouched captured payloads were still held privately and were
  re-archived with additional tag `pg18-precutover-20261031`; fetched each archive
  again and verified its SHA-256 against the original captured payload. Retained
  snapshot IDs (these contain the 14:41/14:42 data, not new live captures):
  - Immich: `627f33a15916839bcaf3f1e85265c53f31df5da39f50e3a93adc741fd4c4a5d9`
  - Mealie: `221f12d2e706034a99d5dac28d9ea9c50adf7e80886ef8db659e73bc085baba3`
- The user subsequently confirmed “Immich and Mealie work as expected; continue
  with Vikunja.” Resumed Comin on node02 after that acceptance; live status
  confirmed unsuspended, idle, signed target `55f2ffe5` deployed done.
  No automated signed-in test credentials were available or created.

## Production execution — node03, 2026-10-31

- Refreshed preflight confirmed PostgreSQL 17.11, only `app`/`postgres` databases,
  healthy Vikunja, idle suspended Comin and a successful prior database backup.
  Retained the old system closure/packages with GC root
  `/nix/var/nix/gcroots/pg18-preupgrade-node03-20261031`.
- Installed the maintenance-only drop-in
  `/run/systemd/system/podman-vikunja.service.d/pg18-maintenance.conf`, requiring
  an absent `/run/pg18-vikunja-writers-permitted` file. Checked effective drop-in
  loading, paused the database timer and stopped Vikunja at **15:27:12 UTC**.
  Explicitly attempted app start on the old stack: `ConditionResult=no`,
  `MainPID=0`, proving the condition blocked writers before cutover.
- Confirmed zero application database sessions. Captured a fresh stopped-writer
  snapshot at **15:27:17 UTC**:
  `6a5325a83bb09db8d02c64a8ee33be8fc1c3dc431f9129b992b60daf2aa0411b`.
  Retrieved its exact payload and created a byte-identical retained copy with
  tag `pg18-precutover-20261031`, fetching it again to verify SHA-256:
  `2daca24c24f6810995f1aa6e84e5a47c9b3fbe6b609b6d4516d0173110ba951d`.
  Use that retained ID for recovery, not the rolling snapshot reference.
- Restored into a private Unix-only PG18 cluster under `postgres-vikunja`.
  All **42 tables / 17,241 rows**, table content fingerprints, ownership and
  complete sequence state matched the stopped-writer source; all indexes were
  valid/ready. Stopped old/staged servers, retained the original cluster at
  `/var/lib/postgres-vikunja-pg17-preserved-20261031`, and moved the validated
  PG18 cluster to `/var/lib/postgres-vikunja`.
- Activated the target closure. The maintenance condition survived activation
  and kept app `MainPID=0`, `ConditionResult=no`. With writers still stopped,
  confirmed live PostgreSQL 18.6 and repeated the complete source/target
  data/ownership/sequence/index comparison successfully.
- Removed only the maintenance drop-in, daemon-reloaded and started Vikunja at
  **15:28:18 UTC**. Its API passed at 15:28:19; observed interruption was about
  **67 seconds**. Live table fingerprints still matched completely after
  startup. App/database had zero restarts and no failed units. Logs reported
  the HTTP server listening normally. PG18 database backup subsequently passed,
  and the original active database timer is running.
- The user subsequently confirmed “Vikunja works as expected” and authorized
  resuming node03. Resumed Comin and verified it unsuspended and idle, with
  signed target `55f2ffe5` deployed done. Rechecked PostgreSQL 18.6, healthy
  Vikunja API, active app/database with zero restarts, active database backup
  timer and no failed units. No credentials or temporary accounts were created
  to bypass signed-in acceptance. Temporary local dumps and remote staging
  were removed; the original PG17 cluster, old-system GC root and verified
  migration-tagged pre-cutover snapshot remain retained.

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
