{
  coreutils,
  findutils,
  gnugrep,
  jq,
  lib,
  restic,
  symlinkJoin,
  systemd,
  gnutar,
  util-linux,
  writeShellApplication,
  jobs,
  repositoryFile,
  passwordFile,
  stateDirectory ? "/var/lib/fleet-backup",
  metricsDirectory ? "/var/lib/node_exporter/textfile_collector",
  chownCommand ? "${coreutils}/bin/chown",
}:
let
  names = builtins.attrNames jobs;
  validName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
  validRelative =
    path:
    builtins.match "[A-Za-z0-9][A-Za-z0-9._/-]*" path != null
    && !(lib.hasInfix "//" path)
    && lib.all (part: part != "." && part != "..") (lib.splitString "/" path);
  definitionsValid =
    lib.all validName names
    && lib.all (job: lib.all validRelative job.requiredPaths) (builtins.attrValues jobs);
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    gnutar
    jq
    restic
    systemd
    util-linux
  ];
  common = ''
    state_root=${lib.escapeShellArg stateDirectory}
    metrics_root=${lib.escapeShellArg metricsDirectory}
    repository_file=${lib.escapeShellArg repositoryFile}
    password_file=${lib.escapeShellArg passwordFile}
    load_credentials() {
      [ -r "$repository_file" ] && [ -r "$password_file" ] || { echo "fleet backup: credential files are not readable" >&2; return 1; }
      mkdir -p "$state_root/cache"
      export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE="$password_file" RESTIC_CACHE_DIR="$state_root/cache"
      RESTIC_REPOSITORY=$(cat "$repository_file")
      [ -n "$RESTIC_REPOSITORY" ] || { echo "fleet backup: empty repository" >&2; return 1; }
    }
    metric_write() {
      name=$1; shift
      mkdir -p "$metrics_root"
      tmp=$(mktemp "$metrics_root/.''${name}.XXXXXX")
      printf '%s\n' "$@" >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$metrics_root/$name.prom"
    }
    acquire_locks() {
      mkdir -p "$state_root/$job"
      exec 9>"$state_root/repository.lock"
      flock 9
      exec 8>"$state_root/$job/job.lock"
      flock 8
    }
    validate_payload() {
      root=$1
      while IFS= read -r -d "" entry; do
        rel=''${entry#"$root"/}
        case "$rel" in ""|/*|*//*|.|..|*/./*|*/../*|./*|../*|*/.|*/..) echo "unsafe payload path: $rel" >&2; return 1;; esac
        printf '%s' "$rel" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || { echo "unsafe payload path: $rel" >&2; return 1; }
        [ -f "$entry" ] || [ -d "$entry" ] || { echo "unsupported payload entry: $rel" >&2; return 1; }
      done < <(find "$root" -mindepth 1 -print0)
      for required in "''${required_paths[@]}"; do
        candidate="$root/$required"
        if [ -f "$candidate" ]; then [ -s "$candidate" ] || { echo "required file is empty: $required" >&2; return 1; }
        elif [ -d "$candidate" ]; then find "$candidate" -mindepth 1 -print -quit | grep -q . || { echo "required directory is empty: $required" >&2; return 1; }
        else echo "required payload path missing: $required" >&2; return 1; fi
      done
    }
    validate_archive() {
      archive=$1
      while IFS= read -r member; do
        case "$member" in ./) continue;; ./?*) rel=''${member#./};; *) echo "unsafe archive member: $member" >&2; return 1;; esac
        case "$rel" in /*|*//*|.|..|*/./*|*/../*|../*|*/.|*/..) echo "unsafe archive member: $member" >&2; return 1;; esac
        printf '%s' "$rel" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || { echo "unsafe archive member: $member" >&2; return 1; }
      done < <(tar -tf "$archive")
      tar -tvf "$archive" | while IFS= read -r line; do case "$line" in [-d]*) :;; *) echo "unsupported archive entry" >&2; exit 1;; esac; done
    }
  '';
  selectJob =
    body:
    lib.concatMapStringsSep "\n" (name: ''
      ${lib.escapeShellArg name})
        ${body name jobs.${name}}
        ;;
    '') names;
  jobValues = _: job: ''
    create_command=${lib.escapeShellArg job.createCommand}
    restore_command=${lib.escapeShellArg job.restoreCommand}
    rehearsal_command=${lib.escapeShellArg job.rehearsalCommand}
    preflight_command=${lib.escapeShellArg job.preflightCommand}
    health_command=${lib.escapeShellArg job.healthCheckCommand}
    required_paths=(${lib.concatMapStringsSep " " lib.escapeShellArg job.requiredPaths})
    paths=(${lib.concatMapStringsSep " " lib.escapeShellArg job.paths})
    units=(${lib.concatMapStringsSep " " lib.escapeShellArg job.serviceUnits})
    owner=${lib.escapeShellArg job.owner}
    group=${lib.escapeShellArg job.group}
    mode=${lib.escapeShellArg job.mode}
    directory_mode=${lib.escapeShellArg job.directoryMode}
    backup_class=${lib.escapeShellArg job.backupClass}
    alert_threshold=${if job.backupClass == "database" then "5400" else "93600"}
    staging_generations=${toString job.failedStagingGenerations}
    staging_bytes=${toString job.failedStagingBytes}
  '';
  core = writeShellApplication {
    name = "fleet-backup-core";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
    ];
    text = ''
      ${common}
      job="''${1:-}"
      case "$job" in
      ${selectJob jobValues}
        *) echo "fleet-backup-core: unknown job: $job" >&2; exit 2;;
      esac
      start=$(date +%s); success=0; bytes=0
      job_state="$state_root/$job"; failed="$job_state/failed"
      mkdir -p "$failed"
      staging=$(mktemp -d "$job_state/staging.XXXXXX")
      finish() {
        rc=$?; duration=$(( $(date +%s) - start ))
        old=$(grep 'fleet_backup_last_success_timestamp_seconds' "$metrics_root/fleet_backup_$job.prom" 2>/dev/null || true)
        if [ "$success" -eq 1 ]; then
          metric_write "fleet_backup_$job" "fleet_backup_result{job=\"$job\",class=\"$backup_class\"} 1" "fleet_backup_last_success_timestamp_seconds{job=\"$job\"} $(date +%s)" "fleet_backup_duration_seconds{job=\"$job\"} $duration" "fleet_backup_bytes{job=\"$job\"} $bytes" "fleet_backup_snapshot_id_present{job=\"$job\"} 1" "fleet_backup_alert_threshold_seconds{job=\"$job\",class=\"$backup_class\"} $alert_threshold"
        else
          metric_write "fleet_backup_$job" "fleet_backup_result{job=\"$job\",class=\"$backup_class\"} 0" "fleet_backup_duration_seconds{job=\"$job\"} $duration" "fleet_backup_bytes{job=\"$job\"} $bytes" "fleet_backup_snapshot_id_present{job=\"$job\"} 0" "fleet_backup_alert_threshold_seconds{job=\"$job\",class=\"$backup_class\"} $alert_threshold" "$old"
          if [ -d "$staging" ]; then
            size=$(du -sb "$staging" | cut -f1)
            failed_path="$failed/$(date +%s)-$$"
            if [ "$size" -le "$staging_bytes" ]; then mv "$staging" "$failed_path"; else rm -rf "$staging"; mkdir "$failed_path"; printf 'payload omitted: %s bytes exceeds %s-byte bound\n' "$size" "$staging_bytes" >"$failed_path/OVERSIZED"; fi
          fi
          while :; do
            count=$(find "$failed" -mindepth 1 -maxdepth 1 -type d | wc -l)
            total=$(du -sb "$failed" | cut -f1)
            [ "$count" -le "$staging_generations" ] && [ "$total" -le "$staging_bytes" ] && break
            oldest=$(find "$failed" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
            [ -n "$oldest" ] || break; rm -rf -- "$oldest"
          done
          echo "fleet-backup-run: $job failed; bounded diagnostics retained in $failed" >&2
        fi
        exit "$rc"
      }
      trap finish EXIT
      load_credentials
      export FLEET_BACKUP_STAGING_DIR="$staging"
      bash -euo pipefail -c "$create_command"
      validate_payload "$staging"
      bytes=$(du -sb "$staging" | cut -f1)
      before=$(restic snapshots --json --tag "fleet-job=$job")
      output=$(tar -C "$staging" -cf - . | restic backup --stdin --stdin-filename fleet-payload.tar --tag "fleet-job=$job" --json)
      snapshot=$(printf '%s\n' "$output" | jq -er 'select(.message_type == "summary") | .snapshot_id | select(type == "string" and length > 0)' | tail -1)
      printf '%s' "$before" | jq -e --arg id "$snapshot" 'all(.[]; .id != $id)' >/dev/null
      restic snapshots --json --tag "fleet-job=$job" "$snapshot" | jq -e --arg id "$snapshot" --arg tag "fleet-job=$job" 'any(.[]; .id == $id and (.tags | index($tag) != null))' >/dev/null
      restic forget --tag "fleet-job=$job" --group-by tags --keep-hourly 24 --keep-daily 30 --keep-monthly 12 --prune
      rm -rf "$job_state/last-good.new"; mv "$staging" "$job_state/last-good.new"
      rm -rf "$job_state/last-good"; mv "$job_state/last-good.new" "$job_state/last-good"
      success=1
    '';
  };
  backup = writeShellApplication {
    name = "fleet-backup-run";
    inherit runtimeInputs;
    excludeShellChecks = [ "SC2154" ];
    text = ''
      ${common}
      job="''${1:-}"
      case "$job" in ${
        lib.concatMapStringsSep "|" lib.escapeShellArg names
      }) :;; *) echo "fleet-backup-run: unknown job: $job" >&2; exit 2;; esac
      load_credentials; acquire_locks
      exec ${core}/bin/fleet-backup-core "$job"
    '';
  };
  restore = writeShellApplication {
    name = "fleet-restore";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
    ];
    text = ''
      ${common}
      usage() { echo 'usage: fleet-restore <job> [--snapshot latest|ID] [--force] [--rehearsal]' >&2; exit 2; }
      [ "$#" -ge 1 ] || usage
      job=$1; shift; snapshot=latest; force=0; rehearsal=0
      while [ "$#" -gt 0 ]; do case "$1" in --snapshot) [ "$#" -ge 2 ] || usage; snapshot=$2; shift 2;; --force) force=1; shift;; --rehearsal) rehearsal=1; shift;; *) usage;; esac; done
      [ "$rehearsal" -eq 0 ] || [ "$force" -eq 0 ] || usage
      case "$job" in
      ${selectJob jobValues}
        *) echo "fleet-restore: unknown job: $job" >&2; exit 2;;
      esac
      acquire_locks; load_credentials
      result=0; selected=unknown; stopped=(); services_started=0; source_dir=
      finish() {
        rc=$?
        [ -z "$source_dir" ] || rm -rf "$source_dir"
        if [ "$result" -ne 1 ] && [ "$services_started" -ne 1 ]; then for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}" || true; done; fi
        metric=fleet_restore; [ "$rehearsal" -eq 0 ] || metric=fleet_restore_rehearsal
        old=$(grep "''${metric}_last_success_timestamp_seconds" "$metrics_root/''${metric}_$job.prom" 2>/dev/null || true)
        if [ "$result" -eq 1 ]; then metric_write "''${metric}_$job" "''${metric}_result{job=\"$job\",snapshot=\"$selected\"} 1" "''${metric}_last_success_timestamp_seconds{job=\"$job\"} $(date +%s)"; else metric_write "''${metric}_$job" "''${metric}_result{job=\"$job\",snapshot=\"$selected\"} 0" "$old"; fi
        exit "$rc"
      }
      trap finish EXIT
      bash -euo pipefail -c "$preflight_command"
      if [ "$snapshot" = latest ]; then snapshots=$(restic snapshots --json --latest 1 --tag "fleet-job=$job"); else snapshots=$(restic snapshots --json --tag "fleet-job=$job" "$snapshot"); fi
      selected=$(printf '%s' "$snapshots" | jq -er --arg requested "$snapshot" --arg tag "fleet-job=$job" 'map(select((.tags | index($tag) != null) and ($requested == "latest" or .id == $requested))) | if length == 1 then .[0].id else empty end')
      [ -n "$selected" ] || { echo "fleet-restore: snapshot unavailable for job" >&2; exit 1; }
      source_dir=$(mktemp -d "$state_root/$job/restore.XXXXXX")
      archive="$source_dir/payload.tar"
      restic dump "$selected" fleet-payload.tar >"$archive"
      validate_archive "$archive"
      mkdir "$source_dir/payload"; tar -C "$source_dir/payload" -xf "$archive"; rm "$archive"
      validate_payload "$source_dir/payload"
      export FLEET_RESTORE_SOURCE_DIR="$source_dir/payload"
      if [ "$rehearsal" -eq 1 ]; then bash -euo pipefail -c "$rehearsal_command"; result=1; exit 0; fi
      active=0
      for unit in "''${units[@]}"; do set +e; systemctl is-active --quiet "$unit"; rc=$?; set -e; case "$rc" in 0) active=1;; 3) :;; *) echo "fleet-restore: cannot determine service state: $unit" >&2; exit 1;; esac; done
      nonempty=0
      for path in "''${paths[@]}"; do [ -d "$path" ] && [ -r "$path" ] && [ -w "$path" ] && [ -x "$path" ] || { echo "fleet-restore: destination inaccessible: $path" >&2; exit 1; }; find "$path" -mindepth 1 -print -quit | grep -q . && nonempty=1 || true; done
      [ "$active" -eq 0 ] || [ "$force" -eq 1 ] || { echo 'fleet-restore: service is active' >&2; exit 1; }
      [ "$nonempty" -eq 0 ] || [ "$force" -eq 1 ] || { echo 'fleet-restore: destination is non-empty; use --force' >&2; exit 1; }
      if [ "$force" -eq 1 ] && { [ "$active" -eq 1 ] || [ "$nonempty" -eq 1 ]; }; then ${core}/bin/fleet-backup-core "$job"; fi
      for unit in "''${units[@]}"; do systemctl stop "$unit"; stopped+=("$unit"); done
      bash -euo pipefail -c "$restore_command"
      for path in "''${paths[@]}"; do ${chownCommand} -R "$owner:$group" "$path"; find "$path" -type d -exec chmod "$directory_mode" {} +; find "$path" -type f -exec chmod "$mode" {} +; done
      for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}"; done; services_started=1
      bash -euo pipefail -c "$health_command"
      result=1
    '';
  };
in
assert lib.assertMsg definitionsValid
  "fleet backup job names and requiredPaths must use the conservative safe grammar";
symlinkJoin {
  name = "fleet-backup-tools";
  paths = [
    backup
    restore
  ];
}
