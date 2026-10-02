# Backup and restore runbook

Each host uses an isolated encrypted restic repository. Configure the repository URL and password as runtime files with `fleet.backup.repositoryFile` and `fleet.backup.passwordFile`; never put credentials in Nix strings, environment declarations, or arguments.

Jobs under `fleet.backup.jobs.<name>` declare their schedule, destination `paths`, required relative payload paths, export/import commands, ordered service units, health check, and positive `maxPayloadBytes` (default 1 GiB). The limit applies independently to logical staged payload and archive size. Names and required paths use a conservative alphanumeric grammar (plus `_`/`-` for names and `._/-` for paths; no absolute, empty, `.` or `..` components). Every required file must be non-empty and every required directory non-empty. Export receives `FLEET_BACKUP_STAGING_DIR`; import receives `FLEET_RESTORE_SOURCE_DIR`, whose root contains exactly the staged relative payload. Optional narrowly scoped fields are `preflightCommand`, `rehearsalCommand`, `owner`, `group`, file `mode`, `directoryMode`, `backupClass`, `failedStagingGenerations`, and `failedStagingBytes`.

The default failed-staging bounds are **two failed generations and 1 GiB per job**, separate from `maxPayloadBytes` and last-good. Export and dump processes are terminated as groups when growth crosses the payload limit. Payloads reject symlinks, hard links, special files, newline/unsafe names, and oversized files before backup success. Restores bound the dump while written, preflight tar type/count/declared sizes, bound extraction, and validate resulting logical size before services stop or destinations change.

Repository operations take a host-wide lock, then all job-local work takes a per-job lock. A forced pre-backup uses an internal core while already holding both locks. `systemctl is-active` exit 0 means active and documented exit 3 means inactive; all other statuses fail closed.

## Restore

1. Verify repository reachability, credentials, free space, and application-specific prerequisites encoded by `preflightCommand`.
2. Normally stop the application first; the dispatcher rejects active units and non-empty destinations.
3. Run `sudo fleet-restore <job> [--snapshot latest|ID]`.
4. To overwrite existing state or operate while declared units are active, use `--force`. The dispatcher must complete a fresh verified backup before stopping any unit or changing data.
5. Confirm the command's health check and `fleet_restore_result` metric. Units stop in declared order and start in reverse order.
6. For a non-destructive download/extract/payload-validation drill, run `fleet-restore <job> [--snapshot latest|ID] --rehearsal`. This runs only `rehearsalCommand`; it does not stop units or touch destinations.

Unknown jobs, unreadable destinations, unavailable snapshots, and failed preflight or health checks fail closed. Before import begins, failure may restart units stopped by that invocation. From import onward, any import, ownership, mode, startup, or health failure leaves every declared unit stopped (including actively stopping units again after a failed health check). Restore sources are temporary and removed after use.

## Metrics and alerts

Metrics are atomically renamed into `/var/lib/node_exporter/textfile_collector`. Backup, restore, rehearsal, and repository-check results are separate from last-success time; failures preserve the prior success timestamp. Backup failures report a defined byte count (zero until staging size is known). Backup metrics export their class and threshold. Alert when database-class backups exceed **90 minutes**, state-class backups exceed **26 hours**, or check/restore/rehearsal result is zero. Also alert on repository locks and repeated bounded-staging failures.
