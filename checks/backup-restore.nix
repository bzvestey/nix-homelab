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
          printf '%s\n' '{"message_type":"summary","snapshot_id":"snapshot-good"}'
          ;;
        snapshots)
          [ ! -e ${root}/fail-snapshots ] || exit 13
          if [ "$#" -gt 2 ]; then
            printf '%s\n' '[{"id":"snapshot-good","time":"2026-10-02T00:00:00Z"}]'
          else
            printf '%s\n' '[]'
          fi
          ;;
        forget) ;;
        restore)
          mkdir -p "$4/payload"
          printf restored >"$4/payload/data"
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
    if [ "$1" = is-active ]; then [ -e ${root}/active ]; else exit 0; fi
    EOF
    chmod +x $out/bin/systemctl
  '';
  jobs = {
    files = {
      frequency = "hourly";
      paths = [ "${root}/target" ];
      createCommand = ''
        cp -a ${root}/source "$FLEET_BACKUP_STAGING_DIR/payload"
        [ ! -e ${root}/fail-create ] || { echo partial >"$FLEET_BACKUP_STAGING_DIR/partial"; exit 9; }
      '';
      restoreCommand = "cp -a $FLEET_RESTORE_SOURCE_DIR/payload/. ${root}/target/";
      serviceUnits = [
        "first.service"
        "second.service"
      ];
      healthCheckCommand = "test ! -e ${root}/fail-health && test $(cat ${root}/target/data) = restored";
      preflightCommand = "test ! -e ${root}/fail-preflight";
      owner = "0";
      group = "0";
      mode = "0640";
      directoryMode = "0750";
      backupClass = "state";
      failedStagingGenerations = 2;
    };
    postgres = {
      frequency = "hourly";
      paths = [ "${root}/database" ];
      createCommand = "printf PGDMP >$FLEET_BACKUP_STAGING_DIR/database.dump";
      restoreCommand = "grep -q PGDMP $FLEET_RESTORE_SOURCE_DIR/database.dump";
      serviceUnits = [ "postgresql.service" ];
      healthCheckCommand = "true";
      preflightCommand = "true";
      owner = "0";
      group = "0";
      mode = "0700";
      directoryMode = "0700";
      backupClass = "database";
      failedStagingGenerations = 2;
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
    grep -F 'restic:forget --keep-hourly 24 --keep-daily 30 --keep-monthly 12 --prune' ${root}/log
    grep -F 'fleet_backup_result{job="files"} 1' ${root}/metrics/fleet_backup_files.prom
    test "$(cat ${root}/state/files/last-good/payload/data)" = original

    # Partial export and repository failures preserve last-good, never prune,
    # retain diagnostics, and enforce the configured generation bound.
    : >${root}/log; touch ${root}/fail-create
    for attempt in 1 2 3; do ${tools}/bin/fleet-backup-run files && exit 1 || true; done
    test "$(find ${root}/state/files/failed -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2
    test "$(cat ${root}/state/files/last-good/payload/data)" = original
    ! grep -F 'restic:forget' ${root}/log
    grep -F 'fleet_backup_result{job="files"} 0' ${root}/metrics/fleet_backup_files.prom
    rm ${root}/fail-create; touch ${root}/fail-repository; : >${root}/log
    ${tools}/bin/fleet-backup-run files && exit 1 || true
    ! grep -F 'restic:forget' ${root}/log
    test "$(cat ${root}/state/files/last-good/payload/data)" = original
    rm ${root}/fail-repository

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
    test "$(cat ${root}/target/data)" = restored
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

    # Generated PostgreSQL commands obey the custom dump contract.
    ${tools}/bin/fleet-backup-run postgres
    test "$(cat ${root}/state/postgres/last-good/database.dump)" = PGDMP

    # Weekly check is rotating and module configuration remains bootstrap-safe.
    check_script=${evaluated.config.systemd.services.fleet-backup-check.serviceConfig.ExecStart}
    grep -F -- '--read-data-subset=' "$check_script"
    test ${evaluated.config.systemd.timers.fleet-backup-files.timerConfig.RandomizedDelaySec} = 20m
    touch $out
  ''
