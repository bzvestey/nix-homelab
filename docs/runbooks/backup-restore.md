# Backup and restore runbook

Each host uses an isolated encrypted restic repository. Configure the repository URL and password as runtime files with `fleet.backup.repositoryFile` and `fleet.backup.passwordFile`; never put credentials in Nix strings, environment declarations, or arguments.

Jobs under `fleet.backup.jobs.<name>` declare their schedule, destination `paths`, export/import commands, ordered service units, and health check. Export receives `FLEET_BACKUP_STAGING_DIR`; import receives `FLEET_RESTORE_SOURCE_DIR`. Optional narrowly scoped fields are `preflightCommand`, `owner`, `group`, file `mode`, `directoryMode`, `backupClass`, and `failedStagingGenerations`.

The default staging bound is **two failed generations per job**. Failures preserve those diagnostics and the last-good staging generation, while deleting older failed generations deterministically. A successful backup must return and expose a verifiable new snapshot ID before retention runs. Retention is 24 hourly, 30 daily, and 12 monthly snapshots. A weekly timer rotates `restic check --read-data-subset` over sevenths of repository data.

## Restore

1. Verify repository reachability, credentials, free space, and application-specific prerequisites encoded by `preflightCommand`.
2. Normally stop the application first; the dispatcher rejects active units and non-empty destinations.
3. Run `sudo fleet-restore <job> [--snapshot latest|ID]`.
4. To overwrite existing state or operate while declared units are active, use `--force`. The dispatcher must complete a fresh verified backup before stopping any unit or changing data.
5. Confirm the command's health check and `fleet_restore_result` metric. Units stop in declared order and start in reverse order.

Unknown jobs, unreadable destinations, unavailable snapshots, and failed preflight or health checks fail closed. Restore sources are temporary and removed after use. Ownership and separate file/directory modes are applied before services start.

## Metrics and alerts

Metrics are atomically renamed into `/var/lib/node_exporter/textfile_collector`. Current result is separate from last-success time; failures preserve the prior success timestamp. Alert when database-class backups exceed **90 minutes**, state-class backups exceed **26 hours**, or check/restore result is zero. Also alert on repository locks and repeated bounded-staging failures.
