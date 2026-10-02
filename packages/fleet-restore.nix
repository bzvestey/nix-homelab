{
  coreutils,
  findutils,
  gnugrep,
  jq,
  lib,
  symlinkJoin,
  restic,
  systemd,
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
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    jq
    restic
    systemd
  ];
  common = ''
    state_root=${lib.escapeShellArg stateDirectory}
    metrics_root=${lib.escapeShellArg metricsDirectory}
    repository_file=${lib.escapeShellArg repositoryFile}
    password_file=${lib.escapeShellArg passwordFile}
    load_credentials() {
      [ -r "$repository_file" ] && [ -r "$password_file" ] || {
        echo "fleet backup: credential files are not readable" >&2; return 1;
      }
      export RESTIC_REPOSITORY
      RESTIC_REPOSITORY=$(cat "$repository_file")
      export RESTIC_PASSWORD_FILE="$password_file"
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
  '';
  selectJob =
    body:
    lib.concatMapStringsSep "\n" (name: ''
      ${lib.escapeShellArg name})
        ${body name jobs.${name}}
        ;;
    '') names;
  backup = writeShellApplication {
    name = "fleet-backup-run";
    inherit runtimeInputs;
    excludeShellChecks = [ "SC2016" ];
    text = ''
      ${common}
      job="''${1:-}"
      case "$job" in
      ${selectJob (
        _: job: ''
          create_command=${lib.escapeShellArg job.createCommand}
          staging_bound=${toString job.failedStagingGenerations}
        ''
      )}
        *) echo "fleet-backup-run: unknown job: $job" >&2; exit 2 ;;
      esac
      start=$(date +%s)
      job_state="$state_root/$job"
      failed="$job_state/failed"
      mkdir -p "$failed"
      staging=$(mktemp -d "$job_state/staging.XXXXXX")
      failed_path="$failed/$(date +%s)-$$"
      success=0
      finish() {
        rc=$?
        duration=$(( $(date +%s) - start ))
        if [ "$success" -eq 1 ]; then
          metric_write "fleet_backup_$job" \
            "fleet_backup_result{job=\"$job\"} 1" \
            "fleet_backup_last_success_timestamp_seconds{job=\"$job\"} $(date +%s)" \
            "fleet_backup_duration_seconds{job=\"$job\"} $duration" \
            "fleet_backup_bytes{job=\"$job\"} $bytes" \
            "fleet_backup_snapshot_id_present{job=\"$job\"} 1"
        else
          old=$(grep 'fleet_backup_last_success_timestamp_seconds' "$metrics_root/fleet_backup_$job.prom" 2>/dev/null || true)
          metric_write "fleet_backup_$job" \
            "fleet_backup_result{job=\"$job\"} 0" \
            "fleet_backup_duration_seconds{job=\"$job\"} $duration" \
            "fleet_backup_snapshot_id_present{job=\"$job\"} 0" \
            "$old"
          if [ -d "$staging" ]; then mv "$staging" "$failed_path"; fi
          find "$failed" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | tail -n +$((staging_bound + 1)) | cut -d' ' -f2- | xargs -r rm -rf --
          echo "fleet-backup-run: $job failed; staging retained at $failed_path" >&2
        fi
        exit "$rc"
      }
      trap finish EXIT
      load_credentials
      export FLEET_BACKUP_STAGING_DIR="$staging"
      bash -euo pipefail -c "$create_command"
      find "$staging" -mindepth 1 -print -quit | grep -q . || { echo "empty backup payload" >&2; exit 1; }
      bytes=$(du -sb "$staging" | cut -f1)
      before=$(restic snapshots --json)
      output=$(restic backup --json "$staging")
      snapshot=$(printf '%s\n' "$output" | jq -er 'select(.message_type == "summary") | .snapshot_id | select(type == "string" and length > 0)' | tail -1)
      printf '%s' "$before" | jq -e --arg id "$snapshot" 'all(.[]; .id != $id)' >/dev/null
      restic snapshots --json "$snapshot" | jq -e --arg id "$snapshot" 'any(.[]; .id == $id)' >/dev/null
      restic forget --keep-hourly 24 --keep-daily 30 --keep-monthly 12 --prune
      rm -rf "$job_state/last-good.new"
      mv "$staging" "$job_state/last-good.new"
      rm -rf "$job_state/last-good"
      mv "$job_state/last-good.new" "$job_state/last-good"
      success=1
    '';
  };
  restore = writeShellApplication {
    name = "fleet-restore";
    runtimeInputs = runtimeInputs ++ [ backup ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      ${common}
      usage() { echo 'usage: fleet-restore <job> [--snapshot latest|ID] [--force]' >&2; exit 2; }
      [ "$#" -ge 1 ] || usage
      job=$1; shift; snapshot=latest; force=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --snapshot) [ "$#" -ge 2 ] || usage; snapshot=$2; shift 2 ;;
          --force) force=1; shift ;;
          *) usage ;;
        esac
      done
      case "$job" in
      ${selectJob (
        _: job: ''
            restore_command=${lib.escapeShellArg job.restoreCommand}
            preflight_command=${lib.escapeShellArg job.preflightCommand}
            health_command=${lib.escapeShellArg job.healthCheckCommand}
            paths=(${lib.concatMapStringsSep " " lib.escapeShellArg job.paths})
            units=(${lib.concatMapStringsSep " " lib.escapeShellArg job.serviceUnits})
            owner=${lib.escapeShellArg job.owner}
            group=${lib.escapeShellArg job.group}
            mode=${lib.escapeShellArg job.mode}
          directory_mode=${lib.escapeShellArg job.directoryMode}
        ''
      )}
        *) echo "fleet-restore: unknown job: $job" >&2; exit 2 ;;
      esac
      result=0; selected=unknown; stopped=(); services_started=0
      record_result() {
        rc=''${1:-$?}
        if [ "$result" -ne 1 ] && [ "$services_started" -ne 1 ]; then
          for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}" || true; done
        fi
        if [ "$result" -ne 1 ]; then
          old=$(grep 'fleet_restore_last_success_timestamp_seconds' "$metrics_root/fleet_restore_$job.prom" 2>/dev/null || true)
          metric_write "fleet_restore_$job" \
            "fleet_restore_result{job=\"$job\",snapshot=\"$selected\"} 0" "$old"
        fi
        exit "$rc"
      }
      trap 'record_result $?' EXIT
      load_credentials
      bash -euo pipefail -c "$preflight_command"
      snapshots=$(restic snapshots --json "$snapshot")
      if [ "$snapshot" = latest ]; then selected=$(printf '%s' "$snapshots" | jq -er 'sort_by(.time) | last | .id');
      else selected=$(printf '%s' "$snapshots" | jq -er --arg id "$snapshot" 'map(select(.id == $id)) | if length == 1 then .[0].id else empty end'); fi
      [ -n "$selected" ] || { echo "fleet-restore: snapshot unavailable" >&2; exit 1; }
      active=0; for unit in "''${units[@]}"; do systemctl is-active --quiet "$unit" && active=1 || true; done
      nonempty=0
      for path in "''${paths[@]}"; do
        [ -d "$path" ] || { echo "fleet-restore: destination inaccessible: $path" >&2; exit 1; }
        [ -r "$path" ] && [ -w "$path" ] && [ -x "$path" ] || { echo "fleet-restore: destination inaccessible: $path" >&2; exit 1; }
        find "$path" -mindepth 1 -print -quit | grep -q . && nonempty=1 || true
      done
      if [ "$active" -eq 1 ] && [ "$force" -ne 1 ]; then echo 'fleet-restore: service is active' >&2; exit 1; fi
      if [ "$nonempty" -eq 1 ] && [ "$force" -ne 1 ]; then echo 'fleet-restore: destination is non-empty; use --force' >&2; exit 1; fi
      if [ "$force" -eq 1 ] && { [ "$active" -eq 1 ] || [ "$nonempty" -eq 1 ]; }; then
        fleet-backup-run "$job"
      fi
      for unit in "''${units[@]}"; do systemctl stop "$unit"; stopped+=("$unit"); done
      source_dir=$(mktemp -d "$state_root/$job/restore.XXXXXX")
      cleanup() { rm -rf "$source_dir"; }
      trap 'rc=$?; cleanup; record_result "$rc"' EXIT
      restic restore "$selected" --target "$source_dir"
      export FLEET_RESTORE_SOURCE_DIR="$source_dir"
      bash -euo pipefail -c "$restore_command"
      for path in "''${paths[@]}"; do
        ${chownCommand} -R "$owner:$group" "$path"
        find "$path" -type d -exec chmod "$directory_mode" {} +
        find "$path" -type f -exec chmod "$mode" {} +
      done
      for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}"; done
      services_started=1
      bash -euo pipefail -c "$health_command"
      metric_write "fleet_restore_$job" "fleet_restore_result{job=\"$job\",snapshot=\"$selected\"} 1" "fleet_restore_last_success_timestamp_seconds{job=\"$job\"} $(date +%s)"
      result=1
    '';
  };
in
symlinkJoin {
  name = "fleet-backup-tools";
  paths = [
    backup
    restore
  ];
}
