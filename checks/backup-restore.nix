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
          if [ -e ${root}/traversal ]; then
            mkdir -p ${root}/evil-build
            printf evil >${root}/evil-build/file
            tar -C ${root}/evil-build --transform='s|file|../escape|' -cf - file
          else
            cat ${root}/archive
          fi
          ;;
        check) ;;
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
    else exit 0; fi
    EOF
    chmod +x $out/bin/systemctl
  '';
  jobs = {
    files = {
      frequency = "hourly";
      paths = [ "${root}/target" ];
      createCommand = ''
        [ ! -e ${root}/hold-create ] || { touch ${root}/create-entered; sleep 2; }
        [ ! -e ${root}/missing-required ] || { printf unrelated >"$FLEET_BACKUP_STAGING_DIR/unrelated"; exit 0; }
        [ ! -e ${root}/oversized ] || { dd if=/dev/zero of="$FLEET_BACKUP_STAGING_DIR/large" bs=2048 count=1; exit 9; }
        cp -a ${root}/source "$FLEET_BACKUP_STAGING_DIR/payload"
        [ ! -e ${root}/fail-create ] || { echo partial >"$FLEET_BACKUP_STAGING_DIR/partial"; exit 9; }
      '';
      restoreCommand = "cp -a $FLEET_RESTORE_SOURCE_DIR/payload/. ${root}/target/";
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

    # Weekly check is rotating and module configuration remains bootstrap-safe.
    check_script=${evaluated.config.systemd.services.fleet-backup-check.serviceConfig.ExecStart}
    grep -F -- '--read-data-subset=' "$check_script"
    grep -F 'fleet_backup_check_last_success_timestamp_seconds' "$check_script"
    test ${evaluated.config.systemd.timers.fleet-backup-files.timerConfig.RandomizedDelaySec} = 20m
    touch $out
  ''
