{ nixpkgs, pkgs }:
let
  root = "/build/fixture";
  fakeRestic = pkgs.writeShellApplication {
    name = "restic";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "restic:$*" >> ${root}/log
      case "$1" in
        backup)
          [ ! -e ${root}/fail-repository ] || exit 12
          cat >${root}/archive
          printf '%s\n' '{"message_type":"summary","snapshot_id":"snapshot-good"}'
          ;;
        snapshots)
          [ ! -e ${root}/fail-snapshots ] || exit 13
          if printf '%s\n' "$*" | grep -Eq 'snapshot-good|--latest'; then
            printf '%s\n' '[{"id":"snapshot-good","time":"2026-10-02T00:00:00Z","tags":["fleet-job=files","fleet-job=postgres"]}]'
          else
            printf '%s\n' '[]'
          fi
          ;;
        forget) ;;
        dump)
          if [ -e ${root}/oversized-dump ]; then
            dd if=/dev/zero bs=65536 count=2
          elif [ -e ${root}/sparse-archive ]; then
            mkdir -p ${root}/evil-build
            truncate -s 131072 ${root}/evil-build/data
            tar --sparse -C ${root}/evil-build -cf - ./data
          elif [ -e ${root}/traversal ]; then
            mkdir -p ${root}/evil-build
            printf evil >${root}/evil-build/file
            tar -C ${root}/evil-build --transform='s|file|../escape|' -cf - file
          else
            cat ${root}/archive
          fi
          ;;
        check) [ ! -e ${root}/fail-repository ] ;;
        *) exit 2 ;;
      esac
    '';
  };
  fakeSystemd = pkgs.runCommand "fake-systemd" { } ''
    mkdir -p $out/bin
    cat >$out/bin/systemctl <<'EOF'
    #!${pkgs.bash}/bin/bash
    echo "systemctl:$*" >> ${root}/log
    if [ "$1" = is-active ]; then
      [ ! -e ${root}/systemctl-error ] || exit 4
      [ -e ${root}/active ] && exit 0 || exit 3
    elif [ "$1" = start ] && [ -e ${root}/fail-start ] && [ "$2" = second.service ]; then exit 5
    else exit 0; fi
    EOF
    chmod +x $out/bin/systemctl
  '';
  jobs = {
    files = {
      frequency = "hourly";
      paths = [ "${root}/target" ];
      createCommand = ''
        [ ! -e ${root}/hold-create ] || { touch ${root}/create-entered; sleep 30; }
        [ ! -e ${root}/term-resistant-export ] || {
          awk '{ print $5 }' "/proc/$BASHPID/stat" >${root}/writer-pgid
          trap "" TERM
          n=0
          while :; do dd if=/dev/zero of="$FLEET_BACKUP_STAGING_DIR/growing-$n" bs=8192 count=1 status=none; n=$(( n + 1 )); sleep 0.05; done
        }
        [ ! -e ${root}/background-export ] || {
          awk '{ print $5 }' "/proc/$BASHPID/stat" >${root}/writer-pgid
          (
            trap "" TERM
            printf '%s\n' "$BASHPID" >${root}/writer-pid
            n=0
            while :; do dd if=/dev/zero of="$FLEET_BACKUP_STAGING_DIR/growing-$n" bs=8192 count=1 status=none; n=$(( n + 1 )); sleep 0.05; done
          ) &
          exit 0
        }
        [ ! -e ${root}/growing-export ] || { while :; do dd if=/dev/zero bs=8192 count=1 >>"$FLEET_BACKUP_STAGING_DIR/growing"; sleep 0.05; done; }
        [ ! -e ${root}/missing-required ] || { printf unrelated >"$FLEET_BACKUP_STAGING_DIR/unrelated"; exit 0; }
        [ ! -e ${root}/oversized ] || { dd if=/dev/zero of="$FLEET_BACKUP_STAGING_DIR/large" bs=2048 count=1; exit 9; }
        cp -a ${root}/source "$FLEET_BACKUP_STAGING_DIR/payload"
        [ ! -e ${root}/fail-create ] || { echo partial >"$FLEET_BACKUP_STAGING_DIR/partial"; exit 9; }
      '';
      restoreCommand = "cp -a $FLEET_RESTORE_SOURCE_DIR/payload/. ${root}/target/; test ! -e ${root}/fail-restore";
      requiredPaths = [ "payload/data" ];
      serviceUnits = [
        "first.service"
        "second.service"
      ];
      healthCheckCommand = "test ! -e ${root}/fail-health && test $(cat ${root}/target/data) = original";
      preflightCommand = "test ! -e ${root}/fail-preflight";
      owner = "0";
      group = "0";
      mode = "0640";
      directoryMode = "0750";
      backupClass = "state";
      failedStagingGenerations = 2;
      failedStagingBytes = 1024;
      maxPayloadBytes = 65536;
      rehearsalCommand = "test ! -e ${root}/fail-rehearsal && test $(cat $FLEET_RESTORE_SOURCE_DIR/payload/data) = original";
    };
    postgres = {
      frequency = "hourly";
      paths = [ "${root}/database" ];
      createCommand = "printf PGDMP >$FLEET_BACKUP_STAGING_DIR/database.dump";
      restoreCommand = "grep -q PGDMP $FLEET_RESTORE_SOURCE_DIR/database.dump";
      requiredPaths = [ "database.dump" ];
      serviceUnits = [ "postgresql.service" ];
      healthCheckCommand = "true";
      preflightCommand = "true";
      owner = "0";
      group = "0";
      mode = "0700";
      directoryMode = "0700";
      backupClass = "database";
      failedStagingGenerations = 2;
      failedStagingBytes = 1024;
      maxPayloadBytes = 65536;
      rehearsalCommand = "grep -q PGDMP $FLEET_RESTORE_SOURCE_DIR/database.dump";
    };
  };
  tools = pkgs.callPackage ../packages/fleet-restore.nix {
    inherit jobs;
    restic = fakeRestic;
    systemd = fakeSystemd;
    repositoryFile = "${root}/repository";
    passwordFile = "${root}/password";
    stateDirectory = "${root}/state";
    metricsDirectory = "${root}/metrics";
    chownCommand = toString (
      pkgs.writeShellScript "fixture-chown" ''
        echo "chown:$*" >>${root}/log
        [ ! -e ${root}/fail-chown ]
      ''
    );
  };
  evaluated = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/fleet/backup.nix
      {
        networking.hostName = "backup-test";
        system.stateVersion = "26.05";
        fleet.backup = {
          repositoryFile = "/run/credentials/repository";
          passwordFile = "/run/credentials/password";
          inherit jobs;
        };
      }
    ];
  };
  realJobs = {
    alpha = jobs.files // {
      paths = [ "${root}/real-target-alpha" ];
      createCommand = "cp -a ${root}/real-source-alpha/. $FLEET_BACKUP_STAGING_DIR/";
      restoreCommand = "false";
      serviceUnits = [ ];
      requiredPaths = [ "payload/data" ];
      rehearsalCommand = "cp -a $FLEET_RESTORE_SOURCE_DIR/. ${root}/observed-alpha/";
    };
    beta = jobs.files // {
      paths = [ "${root}/real-target-beta" ];
      createCommand = "cp -a ${root}/real-source-beta/. $FLEET_BACKUP_STAGING_DIR/";
      restoreCommand = "false";
      serviceUnits = [ ];
      requiredPaths = [ "payload/data" ];
      rehearsalCommand = "cp -a $FLEET_RESTORE_SOURCE_DIR/. ${root}/observed-beta/";
    };
  };
  realTools = pkgs.callPackage ../packages/fleet-restore.nix {
    jobs = realJobs;
    repositoryFile = "${root}/real-repository";
    passwordFile = "${root}/real-password";
    stateDirectory = "${root}/real-state";
    metricsDirectory = "${root}/real-metrics";
  };
in
pkgs.runCommand "backup-restore-tests"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.findutils
    ];
  }
  ''
        mkdir -p ${root}/{source,target,database,state,metrics}
        printf original >${root}/source/data
        printf repository >${root}/repository
        printf password >${root}/password
        group_has_live_member() {
          target_pgid=$1
          for stat_file in /proc/[0-9]*/stat; do
            [ -r "$stat_file" ] || continue
            stat_line=$(cat "$stat_file" 2>/dev/null) || continue
            stat_fields=''${stat_line##*) }
            read -r state _ process_pgid _ <<<"$stat_fields"
            [ "$process_pgid" = "$target_pgid" ] || continue
            [ "$state" = Z ] || [ "$state" = X ] || return 0
          done
          return 1
        }
        process_is_live() {
          stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
          stat_fields=''${stat_line##*) }
          read -r state _ <<<"$stat_fields"
          [ "$state" != Z ] && [ "$state" != X ]
        }

        # The module executes this same generated production program.
        grep -F '/bin/fleet-backup-run files' ${pkgs.writeText "exec" evaluated.config.systemd.services.fleet-backup-files.serviceConfig.ExecStart}
        ${tools}/bin/fleet-backup-run files
        grep -F 'restic:forget --tag fleet-job=files --group-by tags --keep-hourly 24 --keep-daily 30 --keep-monthly 12 --prune' ${root}/log
        grep -F 'fleet_backup_result{job="files",class="state"} 1' ${root}/metrics/fleet_backup_files.prom
        test "$(cat ${root}/state/files/last-good/payload/data)" = original

        # Partial export and repository failures preserve last-good, never prune,
        # retain diagnostics, and enforce the configured generation bound.
        : >${root}/log; touch ${root}/fail-create
        for attempt in 1 2 3; do ${tools}/bin/fleet-backup-run files && exit 1 || true; done
        test "$(find ${root}/state/files/failed -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2
        test "$(cat ${root}/state/files/last-good/payload/data)" = original
        ! grep -F 'restic:forget' ${root}/log
        grep -F 'fleet_backup_result{job="files",class="state"} 0' ${root}/metrics/fleet_backup_files.prom
        grep -F 'fleet_backup_bytes{job="files"}' ${root}/metrics/fleet_backup_files.prom
        rm ${root}/fail-create; touch ${root}/fail-repository; : >${root}/log
        ${tools}/bin/fleet-backup-run files && exit 1 || true
        ! grep -F 'restic:forget' ${root}/log
        test "$(cat ${root}/state/files/last-good/payload/data)" = original
        rm ${root}/fail-repository

        # Required paths, total retained bytes, and host-wide lock overlap.
        touch ${root}/missing-required
        ${tools}/bin/fleet-backup-run files && exit 1 || true
        rm ${root}/missing-required
        touch ${root}/oversized
        ${tools}/bin/fleet-backup-run files && exit 1 || true
        test "$(du -sb ${root}/state/files/failed | cut -f1)" -le 1024
        find ${root}/state/files/failed -name OVERSIZED -print -quit | grep -q .
        rm ${root}/oversized
        touch ${root}/growing-export
        timeout 5 ${tools}/bin/fleet-backup-run files && exit 1 || true
        rm ${root}/growing-export
        test "$(find ${root}/state/files/failed -type f -printf '%s\n' | sort -nr | head -1)" -le 65536

        # A TERM-resistant producer and an exited leader with a surviving writer
        # are killed as complete process groups without retaining locks or data.
        for hostile in term-resistant-export background-export; do
          rm -f ${root}/writer-pid ${root}/writer-pgid
          touch ${root}/$hostile
          timeout -k 1 5 ${tools}/bin/fleet-backup-run files && exit 1 || true
          pgid=$(cat ${root}/writer-pgid)
          if group_has_live_member "$pgid"; then
            kill -KILL -- "-$pgid" 2>/dev/null || true
            echo "$hostile left a surviving process group" >&2
            exit 1
          fi
          if [ -e ${root}/writer-pid ]; then
            ! process_is_live "$(cat ${root}/writer-pid)"
          fi
          test "$(du -sb ${root}/state/files/failed | cut -f1)" -le 1024
          test "$(find ${root}/state/files/failed -type f -printf '%s\n' | sort -nr | head -1)" -le 65536
          rm ${root}/$hostile
          timeout 5 ${tools}/bin/fleet-backup-run files
        done

        touch ${root}/hold-create; : >${root}/log
        ${tools}/bin/fleet-backup-run files & lock_pid=$!
        while [ ! -e ${root}/create-entered ]; do sleep 0.1; done
        ${tools}/bin/fleet-backup-run postgres & second_pid=$!
        sleep 0.2
        ! grep -F 'fleet-job=postgres' ${root}/log
        wait "$lock_pid" "$second_pid"
        rm ${root}/hold-create ${root}/create-entered
        ${tools}/bin/fleet-backup-run files

        # Fail closed before any destructive action.
        ${tools}/bin/fleet-restore unknown && exit 1 || true
        touch ${root}/fail-preflight; : >${root}/log
        ${tools}/bin/fleet-restore files && exit 1 || true
        ! grep -F 'systemctl:stop' ${root}/log
        rm ${root}/fail-preflight
        touch ${root}/fail-snapshots; : >${root}/log
        ${tools}/bin/fleet-restore files && exit 1 || true
        ! grep -F 'systemctl:stop' ${root}/log
        rm ${root}/fail-snapshots
        ${tools}/bin/fleet-restore files --snapshot absent && exit 1 || true
        printf existing >${root}/target/existing
        ${tools}/bin/fleet-restore files && exit 1 || true
        touch ${root}/active ${root}/fail-create; : >${root}/log
        ${tools}/bin/fleet-restore files --force && exit 1 || true
        test "$(cat ${root}/target/existing)" = existing
        ! grep -F 'systemctl:stop' ${root}/log
        rm ${root}/fail-create

        # Force first creates a fresh verified snapshot, then deterministic
        # stop/restore/mode/start/health succeeds and records the selected ID.
        : >${root}/log
        ${tools}/bin/fleet-restore files --snapshot snapshot-good --force
        test "$(cat ${root}/target/data)" = original
        test "$(stat -c %a ${root}/target/data)" = 640
        grep -F 'chown:-R 0:0 /build/fixture/target' ${root}/log
        grep -F 'fleet_restore_result{job="files",snapshot="snapshot-good"} 1' ${root}/metrics/fleet_restore_files.prom
        test "$(grep -nE 'systemctl:(stop first|stop second|start second|start first)' ${root}/log | cut -d: -f2- | tr '\n' '|')" = 'systemctl:stop first.service|systemctl:stop second.service|systemctl:start second.service|systemctl:start first.service|'

        # A failed health check is a current failure and cannot overwrite the
        # previous successful restore timestamp or claim success.
        previous=$(grep fleet_restore_last_success_timestamp_seconds ${root}/metrics/fleet_restore_files.prom)
        touch ${root}/fail-health; : >${root}/log
        ${tools}/bin/fleet-restore files --force && exit 1 || true
        grep -F 'fleet_restore_result{job="files",snapshot="snapshot-good"} 0' ${root}/metrics/fleet_restore_files.prom
        ! grep -F 'fleet_restore_result{job="files",snapshot="snapshot-good"} 1' ${root}/metrics/fleet_restore_files.prom
        grep -Fx "$previous" ${root}/metrics/fleet_restore_files.prom
        rm ${root}/fail-health

        # Once import starts, every failure leaves all declared services stopped.
        for failure in fail-restore fail-chown fail-start fail-health; do
          touch ${root}/$failure; : >${root}/log
          ${tools}/bin/fleet-restore files --force && exit 1 || true
          grep -F 'fleet_restore_result{job="files",snapshot="snapshot-good"} 0' ${root}/metrics/fleet_restore_files.prom
          last_stop=$(grep -n 'systemctl:stop' ${root}/log | tail -1 | cut -d: -f1)
          first_start=$(grep -n 'systemctl:start' ${root}/log | head -1 | cut -d: -f1 || true)
          test -z "$first_start" || test "$last_stop" -gt "$first_start"
          test "$(grep -c 'systemctl:stop first.service' ${root}/log)" -ge 1
          test "$(grep -c 'systemctl:stop second.service' ${root}/log)" -ge 1
          rm ${root}/$failure
        done

        # Unknown systemctl statuses and hostile archives fail before stop/mutation.
        touch ${root}/systemctl-error; : >${root}/log
        ${tools}/bin/fleet-restore files --force && exit 1 || true
        ! grep -F 'systemctl:stop' ${root}/log
        rm ${root}/systemctl-error
        touch ${root}/traversal; : >${root}/log
        ${tools}/bin/fleet-restore files --force && exit 1 || true
        test ! -e ${root}/state/files/escape
        ! grep -F 'systemctl:stop' ${root}/log
        rm ${root}/traversal
        for hostile in oversized-dump sparse-archive; do
          touch ${root}/$hostile; : >${root}/log
          ${tools}/bin/fleet-restore files --force && exit 1 || true
          ! grep -F 'systemctl:stop' ${root}/log
          rm ${root}/$hostile
        done

        # Rehearsal extracts and validates without service or destination mutation.
        : >${root}/log
        ${tools}/bin/fleet-restore files --rehearsal
        grep -F 'fleet_restore_rehearsal_result{job="files",snapshot="snapshot-good"} 1' ${root}/metrics/fleet_restore_rehearsal_files.prom
        ! grep -F 'systemctl:stop' ${root}/log
        rehearsal_previous=$(grep fleet_restore_rehearsal_last_success_timestamp_seconds ${root}/metrics/fleet_restore_rehearsal_files.prom)
        touch ${root}/fail-rehearsal
        ${tools}/bin/fleet-restore files --rehearsal && exit 1 || true
        grep -F 'fleet_restore_rehearsal_result{job="files",snapshot="snapshot-good"} 0' ${root}/metrics/fleet_restore_rehearsal_files.prom
        grep -Fx "$rehearsal_previous" ${root}/metrics/fleet_restore_rehearsal_files.prom
        rm ${root}/fail-rehearsal

        # Generated PostgreSQL commands obey the custom dump contract.
        ${tools}/bin/fleet-backup-run postgres
        test "$(cat ${root}/state/postgres/last-good/database.dump)" = PGDMP

        # A real local restic repository proves the generated scripts' archive
        # layout, mode/content fidelity, exact job selection, and tag grouping.
        mkdir -p ${root}/real-{repo,state,metrics,target-alpha,target-beta}
        mkdir -p ${root}/real-source-{alpha,beta}/payload
        printf alpha >${root}/real-source-alpha/payload/data
        printf beta >${root}/real-source-beta/payload/data
        chmod 0641 ${root}/real-source-alpha/payload/data
        printf %s ${root}/real-repo >${root}/real-repository
        printf secret >${root}/real-password
        mkdir -p ${root}/external-cache
        export RESTIC_REPOSITORY=${root}/real-repo RESTIC_PASSWORD_FILE=${root}/real-password RESTIC_CACHE_DIR=${root}/external-cache
        ${pkgs.restic}/bin/restic init
        ${realTools}/bin/fleet-backup-run alpha
        alpha_id=$(${pkgs.restic}/bin/restic snapshots --json --tag fleet-job=alpha | ${pkgs.jq}/bin/jq -r '.[0].id')
        ${realTools}/bin/fleet-backup-run beta
        beta_id=$(${pkgs.restic}/bin/restic snapshots --json --tag fleet-job=beta | ${pkgs.jq}/bin/jq -r '.[0].id')
        ${realTools}/bin/fleet-restore alpha --rehearsal
        test "$(cat ${root}/observed-alpha/payload/data)" = alpha
        test "$(stat -c %a ${root}/observed-alpha/payload/data)" = 641
        ${realTools}/bin/fleet-restore beta --rehearsal
        test "$(cat ${root}/observed-beta/payload/data)" = beta
        ${realTools}/bin/fleet-restore alpha --snapshot "$beta_id" --rehearsal && exit 1 || true
        ${realTools}/bin/fleet-restore alpha --snapshot "$alpha_id" --rehearsal
        test "$(${pkgs.restic}/bin/restic snapshots --json --tag fleet-job=alpha | ${pkgs.jq}/bin/jq length)" -eq 1
        test "$(${pkgs.restic}/bin/restic snapshots --json --tag fleet-job=beta | ${pkgs.jq}/bin/jq length)" -eq 1

        # Staging accepts exactly the entry types restore accepts.
        for kind in symlink hardlink fifo newline; do
          rm -rf ${root}/real-source-alpha; mkdir -p ${root}/real-source-alpha/payload
          printf valid >${root}/real-source-alpha/payload/data
          case "$kind" in
            symlink) ln -s data ${root}/real-source-alpha/payload/link;;
            hardlink) ln ${root}/real-source-alpha/payload/data ${root}/real-source-alpha/payload/link;;
            fifo) mkfifo ${root}/real-source-alpha/payload/pipe;;
            newline) printf bad >"${root}/real-source-alpha/payload/bad
    name";;
          esac
          ${realTools}/bin/fleet-backup-run alpha && exit 1 || true
        done

        # The production check script works on first run and atomically publishes
        # world-readable metrics while preserving the last success on failure.
        check_script=${evaluated.config.systemd.services.fleet-backup-check.serviceConfig.ExecStart}
        test ${evaluated.config.systemd.services.fleet-backup-check.serviceConfig.StateDirectory} = fleet-backup
        rm -rf ${root}/state ${root}/metrics; mkdir -p ${root}/state
        ${tools}/bin/fleet-backup-check
        test "$(stat -c %a ${root}/metrics/fleet_backup_check.prom)" = 644
        grep -Fx 'fleet_backup_check_result 1' ${root}/metrics/fleet_backup_check.prom
        check_success=$(grep fleet_backup_check_last_success_timestamp_seconds ${root}/metrics/fleet_backup_check.prom)
        touch ${root}/fail-repository
        ${tools}/bin/fleet-backup-check && exit 1 || true
        grep -Fx 'fleet_backup_check_result 0' ${root}/metrics/fleet_backup_check.prom
        grep -Fx "$check_success" ${root}/metrics/fleet_backup_check.prom
        rm ${root}/fail-repository
        test ${evaluated.config.systemd.timers.fleet-backup-files.timerConfig.RandomizedDelaySec} = 20m
        touch $out
  ''
