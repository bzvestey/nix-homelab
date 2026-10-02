# Backup and restore runbook

Each host uses an isolated encrypted restic repository. Configure the repository URL and password as runtime files with `fleet.backup.repositoryFile` and `fleet.backup.passwordFile`; never put credentials in Nix strings, environment declarations, or arguments.

Jobs under `fleet.backup.jobs.<name>` declare their schedule, destination `paths`, required relative payload paths, export/import commands, ordered service units, and health check. Names and required paths use a conservative alphanumeric grammar (plus `_`/`-` for names and `._/-` for paths; no absolute, empty, `.` or `..` components). Every required file must be non-empty and every required directory non-empty. Export receives `FLEET_BACKUP_STAGING_DIR`; import receives `FLEET_RESTORE_SOURCE_DIR`, whose root contains exactly the staged relative payload. Optional narrowly scoped fields are `preflightCommand`, `rehearsalCommand`, `owner`, `group`, file `mode`, `directoryMode`, `backupClass`, `failedStagingGenerations`, and `failedStagingBytes`.

The default staging bounds are **two failed generations and 1 GiB per job**. Failures preserve diagnostics and the independent last-good generation while deleting oldest failures deterministically. Oversized failures are replaced by bounded diagnostic metadata rather than claiming the full tree was retained. Payloads are streamed as a stable `fleet-payload.tar`; restores reject traversal and non-file/directory archive entries before extraction. Every snapshot is tagged `fleet-job=<exact-job>`. Selection and exact 24-hourly/30-daily/12-monthly retention are filtered and grouped by that tag.

Repository operations take a host-wide lock, then all job-local work takes a per-job lock. A forced pre-backup uses an internal core while already holding both locks. `systemctl is-active` exit 0 means active and documented exit 3 means inactive; all other statuses fail closed.

## Restore

1. Verify repository reachability, credentials, free space, and application-specific prerequisites encoded by `preflightCommand`.
2. Normally stop the application first; the dispatcher rejects active units and non-empty destinations.
3. Run `sudo fleet-restore <job> [--snapshot latest|ID]`.
4. To overwrite existing state or operate while declared units are active, use `--force`. The dispatcher must complete a fresh verified backup before stopping any unit or changing data.
5. Confirm the command's health check and `fleet_restore_result` metric. Units stop in declared order and start in reverse order.
6. For a non-destructive download/extract/payload-validation drill, run `fleet-restore <job> [--snapshot latest|ID] --rehearsal`. This runs only `rehearsalCommand`; it does not stop units or touch destinations.

Unknown jobs, unreadable destinations, unavailable snapshots, and failed preflight or health checks fail closed. Restore sources are temporary and removed after use. Ownership and separate file/directory modes are applied before services start.

## Metrics and alerts

Metrics are atomically renamed into `/var/lib/node_exporter/textfile_collector`. Backup, restore, rehearsal, and repository-check results are separate from last-success time; failures preserve the prior success timestamp. Backup failures report a defined byte count (zero until staging size is known). Backup metrics export their class and threshold. Alert when database-class backups exceed **90 minutes**, state-class backups exceed **26 hours**, or check/restore/rehearsal result is zero. Also alert on repository locks and repeated bounded-staging failures.
