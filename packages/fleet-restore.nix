{
  bash,
  coreutils,
  findutils,
  gawk,
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
  cgroupRoot ? "/sys/fs/cgroup",
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
    bash
    coreutils
    findutils
    gawk
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
        case "$rel" in *$'\n'*) echo "unsafe payload path contains newline" >&2; return 1;; esac
        case "$rel" in ""|/*|*//*|.|..|*/./*|*/../*|./*|../*|*/.|*/..) echo "unsafe payload path: $rel" >&2; return 1;; esac
        printf '%s' "$rel" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || { echo "unsafe payload path: $rel" >&2; return 1; }
        [ ! -L "$entry" ] || { echo "unsupported payload symlink: $rel" >&2; return 1; }
        if [ -f "$entry" ]; then
          [ "$(stat -c %h "$entry")" -eq 1 ] || { echo "unsupported multiply-linked payload file: $rel" >&2; return 1; }
          [ "$(stat -c %s "$entry")" -le "$max_payload_bytes" ] || { echo "payload file exceeds byte bound: $rel" >&2; return 1; }
        elif [ ! -d "$entry" ]; then echo "unsupported payload entry: $rel" >&2; return 1; fi
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
      [ "$(stat -c %s "$archive")" -le "$max_payload_bytes" ] || { echo "archive exceeds byte bound" >&2; return 1; }
      while IFS= read -r member; do
        case "$member" in ./) continue;; ./?*) rel=''${member#./};; *) echo "unsafe archive member: $member" >&2; return 1;; esac
        case "$rel" in /*|*//*|.|..|*/./*|*/../*|../*|*/.|*/..) echo "unsafe archive member: $member" >&2; return 1;; esac
        printf '%s' "$rel" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || { echo "unsafe archive member: $member" >&2; return 1; }
      done < <(tar -tf "$archive")
      tar --numeric-owner -tvf "$archive" | awk -v max="$max_payload_bytes" '
        BEGIN { total=0; count=0 }
        $1 ~ /^-/ { count++; if ($3 > max || total > max - $3) exit 1; total += $3; next }
        $1 ~ /^d/ { count++; next }
        { exit 1 }
        END { if (count > 100000) exit 1 }
      ' || { echo "archive entries exceed type, count, or declared-size bound" >&2; return 1; }
    }
    tree_bytes() {
      find "$1" -type f -printf '%s\n' | awk '{ count++; if (count > 100000 || $1 > max || total > max - $1) exit 1; total += $1 } END { print total + 0 }' max="$max_payload_bytes"
    }
    unit_state() {
      systemctl show "$1" --property=LoadState --property=ActiveState --property=MainPID --property=ControlGroup --property=ExecMainCode --property=ExecMainStatus
    }
    unit_membership() {
      control_group=$1
      [ -n "$control_group" ] || { printf unavailable; return; }
      group_path=${lib.escapeShellArg cgroupRoot}"$control_group"
      set +e
      populated=$(sed -n 's/^populated //p' "$group_path/cgroup.events" 2>/dev/null)
      membership_rc=$?
      set -e
      if [ "$membership_rc" -ne 0 ]; then
        [ -e "$group_path" ] && printf unavailable || printf removed
        return
      fi
      case "$populated" in 0) printf empty;; 1) printf populated;; *) printf unavailable;; esac
    }
    unit_is_inactive_and_empty_or_removed() {
      target_unit=$1
      known_cgroup=$2
      if state=$(unit_state "$target_unit" 2>/dev/null); then
        active=$(printf '%s\n' "$state" | sed -n 's/^ActiveState=//p')
        cgroup=$(printf '%s\n' "$state" | sed -n 's/^ControlGroup=//p')
        [ -n "$cgroup" ] || cgroup=$known_cgroup
        membership=$(unit_membership "$cgroup")
        { [ "$active" = inactive ] || [ "$active" = failed ]; } && { [ "$membership" = empty ] || [ "$membership" = removed ]; }
        return
      fi
      membership=$(unit_membership "$known_cgroup")
      [ "$membership" = empty ] || [ "$membership" = removed ]
    }
    collect_transient_unit() {
      target_unit=$1
      known_cgroup=''${2:-}
      systemctl stop --no-block "$target_unit" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        if unit_is_inactive_and_empty_or_removed "$target_unit" "$known_cgroup"; then
          systemctl reset-failed "$target_unit" >/dev/null 2>&1 || true
          return 0
        fi
        sleep 0.05
      done
      echo "transient command unit did not become inactive and empty after stop" >&2
      return 1
    }
    terminate_transient_unit() {
      target_unit=$1
      known_cgroup=''${2:-}
      systemctl kill --kill-whom=all --signal=TERM "$target_unit" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        membership=$(unit_membership "$known_cgroup")
        { [ "$membership" = empty ] || [ "$membership" = removed ]; } && break
        sleep 0.05
      done
      membership=$(unit_membership "$known_cgroup")
      if [ "$membership" != empty ] && [ "$membership" != removed ]; then
        systemctl kill --kill-whom=all --signal=KILL "$target_unit" >/dev/null 2>&1 || true
      fi
      collect_transient_unit "$target_unit" "$known_cgroup"
    }
    run_bounded_tree_command() {
      watched=$1; shift
      max_blocks=$(( (max_payload_bytes + 511) / 512 ))
      leader_file=$(mktemp)
      unit_token_file=$(mktemp)
      unit_token=$(basename "$unit_token_file")
      rm -f "$unit_token_file"
      unit="fleet-bounded-$job-$$-$unit_token.service"
      run_environment=(--setenv=PATH --setenv=RESTIC_REPOSITORY --setenv=RESTIC_PASSWORD_FILE --setenv=RESTIC_CACHE_DIR)
      [ -z "''${FLEET_BACKUP_STAGING_DIR:-}" ] || run_environment+=(--setenv=FLEET_BACKUP_STAGING_DIR)
      if ! systemd-run --quiet --service-type=exec --unit="$unit" \
        --property=RemainAfterExit=yes --property=KillMode=control-group --property=TimeoutStopSec=1s \
        --property="LimitFSIZE=$max_payload_bytes" "''${run_environment[@]}" -- \
        bash -c 'printf "%s\n" "$BASHPID" >"$1"; ulimit -f "$2"; shift 2; exec "$@"' _ "$leader_file" "$max_blocks" "$@"; then
        rm -f "$leader_file"
        echo "transient command unit failed to start" >&2
        return 1
      fi
      started=0
      for _ in {1..100}; do
        if state=$(unit_state "$unit" 2>/dev/null); then
          load=$(printf '%s\n' "$state" | sed -n 's/^LoadState=//p')
          cgroup=$(printf '%s\n' "$state" | sed -n 's/^ControlGroup=//p')
          [ "$load" = loaded ] && [ -n "$cgroup" ] && started=1 && break
        fi
        sleep 0.01
      done
      if [ "$started" -eq 0 ]; then
        terminate_transient_unit "$unit" "''${cgroup:-}" || true
        rm -f "$leader_file"
        echo "transient command unit failed to start or could not be controlled" >&2
        return 1
      fi
      violation=
      command_rc=
      exited_ticks=0
      control_failures=0
      while [ -z "$command_rc" ]; do
        if ! tree_bytes "$watched" >/dev/null; then
          violation=bound
          break
        fi
        if ! state=$(unit_state "$unit" 2>/dev/null); then
          membership=$(unit_membership "$cgroup")
          if [ "$membership" = unavailable ]; then
            violation=control
            break
          fi
          control_failures=$(( control_failures + 1 ))
          if [ "$control_failures" -ge 5 ]; then
            violation=control
            break
          fi
          sleep 0.05
          continue
        fi
        control_failures=0
        observed_cgroup=$(printf '%s\n' "$state" | sed -n 's/^ControlGroup=//p')
        [ -z "$observed_cgroup" ] || cgroup=$observed_cgroup
        exec_code=$(printf '%s\n' "$state" | sed -n 's/^ExecMainCode=//p')
        exec_status=$(printf '%s\n' "$state" | sed -n 's/^ExecMainStatus=//p')
        membership=$(unit_membership "$cgroup")
        if [ "$membership" = unavailable ]; then
          violation=control
          break
        fi
        case "$exec_code" in
          ""|0) exited_ticks=0 ;;
          exited|1)
            if [ "$membership" = populated ]; then
              exited_ticks=$(( exited_ticks + 1 ))
              if [ "$exited_ticks" -ge 5 ]; then
                violation=descendant
              fi
            elif [[ "$exec_status" =~ ^[0-9]+$ ]] && [ "$exec_status" -le 255 ]; then
              command_rc=$exec_status
            else
              violation="command"
            fi
            [ -z "$violation" ] || break
            ;;
          *)
            violation="command"
            break
            ;;
        esac
        sleep 0.05
      done
      cleanup_ok=1
      if [ -n "$violation" ]; then
        terminate_transient_unit "$unit" "$cgroup" || cleanup_ok=0
      else
        collect_transient_unit "$unit" "$cgroup" || cleanup_ok=0
      fi
      rm -f "$leader_file"
      if [ "$violation" = bound ]; then
        echo "payload exceeded file, aggregate, or count bound while command was running" >&2
        return 1
      elif [ "$violation" = descendant ]; then
        echo "command leader exited with persistent cgroup descendants" >&2
        return 1
      elif [ "$violation" = control ]; then
        echo "lost control of transient command unit" >&2
        return 1
      elif [ "$violation" = command ]; then
        echo "transient command terminated without an exit status" >&2
        return 1
      elif [ "$cleanup_ok" -eq 0 ]; then
        return 1
      fi
      tree_bytes "$watched" >/dev/null || { echo "payload exceeded file, aggregate, or count bound at command completion" >&2; return 1; }
      return "$command_rc"
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
    max_payload_bytes=${toString job.maxPayloadBytes}
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
      job_state="$state_root/$job"; failed="$job_state/failed"; archive_dir=
      mkdir -p "$failed"
      staging=$(mktemp -d "$job_state/staging.XXXXXX")
      finish() {
        rc=$?; duration=$(( $(date +%s) - start ))
        [ -z "$archive_dir" ] || rm -rf "$archive_dir"
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
      run_bounded_tree_command "$staging" bash -euo pipefail -c "$create_command"
      validate_payload "$staging"
      bytes=$(tree_bytes "$staging")
      before=$(restic snapshots --json --tag "fleet-job=$job")
      archive_dir=$(mktemp -d "$job_state/archive.XXXXXX")
      archive="$archive_dir/fleet-payload.tar"
      run_bounded_tree_command "$archive_dir" bash -c 'exec tar -C "$1" -cf "$2" .' _ "$staging" "$archive"
      [ "$(stat -c %s "$archive")" -le "$max_payload_bytes" ] || { echo "archive exceeds byte bound" >&2; exit 1; }
      output=$(restic backup --stdin --stdin-filename fleet-payload.tar --tag "fleet-job=$job" --json <"$archive")
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
    excludeShellChecks = [
      "SC2016"
      "SC2154"
    ];
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
  check = writeShellApplication {
    name = "fleet-backup-check";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2154"
    ];
    text = ''
      ${common}
      job=check
      load_credentials
      mkdir -p "$state_root"
      exec 9>"$state_root/repository.lock"; flock 9
      subset="$(( $(date +%V) % 7 + 1 ))/7"
      if restic check --read-data-subset="$subset"; then result=1; else result=0; fi
      old=$(grep fleet_backup_check_last_success_timestamp_seconds "$metrics_root/fleet_backup_check.prom" 2>/dev/null || true)
      if [ "$result" -eq 1 ]; then
        metric_write fleet_backup_check "fleet_backup_check_result 1" "fleet_backup_check_last_success_timestamp_seconds $(date +%s)"
      else
        metric_write fleet_backup_check "fleet_backup_check_result 0" "$old"
      fi
      test "$result" -eq 1
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
      result=0; selected=unknown; stopped=(); mutation_started=0; source_dir=
      finish() {
        rc=$?
        [ -z "$source_dir" ] || rm -rf "$source_dir"
        if [ "$result" -ne 1 ]; then
          if [ "$mutation_started" -eq 1 ]; then
            echo "fleet-restore: failure after destination mutation; stopping all declared services" >&2
            for unit in "''${units[@]}"; do systemctl stop "$unit" || true; done
          else
            for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}" || true; done
          fi
        fi
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
      run_bounded_tree_command "$source_dir" bash -c 'restic dump "$1" fleet-payload.tar >"$2"' _ "$selected" "$archive"
      validate_archive "$archive"
      mkdir "$source_dir/payload"
      run_bounded_tree_command "$source_dir/payload" tar -C "$source_dir/payload" -xf "$archive"
      rm "$archive"
      validate_payload "$source_dir/payload"
      tree_bytes "$source_dir/payload" >/dev/null
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
      mutation_started=1
      bash -euo pipefail -c "$restore_command"
      for path in "''${paths[@]}"; do ${chownCommand} -R "$owner:$group" "$path"; find "$path" -type d -exec chmod "$directory_mode" {} +; find "$path" -type f -exec chmod "$mode" {} +; done
      for ((i=''${#stopped[@]}-1; i>=0; i--)); do systemctl start "''${stopped[$i]}"; done
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
    check
    restore
  ];
}
