{ pkgs }:
let
  fakeRestic = pkgs.writeShellApplication {
    name = "restic";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      case "$1" in
        snapshots)
          if printf '%s\n' "$*" | grep -q -- --latest || [ -e /run/fleet-test/backed-up ]; then
            printf '%s\n' '[{"id":"snapshot-good","tags":["fleet-job=files"]}]'
          else
            printf '%s\n' '[]'
          fi
          ;;
        backup)
          cat >/dev/null
          touch /run/fleet-test/backed-up
          printf '%s\n' '{"message_type":"summary","snapshot_id":"snapshot-good"}'
          ;;
        forget) ;;
        *) exit 2 ;;
      esac
    '';
  };
  testPkgs = pkgs.extend (_: _: { restic = fakeRestic; });
in
testPkgs.testers.runNixOSTest {
  name = "backup-cgroup-supervision";

  nodes.machine = {
    imports = [ ../modules/fleet/backup.nix ];
    system.stateVersion = "26.05";
    environment.systemPackages = [ pkgs.util-linux ];
    systemd.services.fleet-backup-files.path = [ pkgs.bash ];
    systemd.services.fleet-backup-files.environment.RESTIC_PASSWORD = "ambient-must-not-cross";
    fleet.backup = {
      repositoryFile = "/run/fleet-test/repository";
      passwordFile = "/run/fleet-test/password";
      jobs.files = {
        frequency = "hourly";
        paths = [ "/var/lib/fleet-target" ];
        createCommand = ''
          [ -z "''${RESTIC_PASSWORD:-}" ]
          [ "$RESTIC_PASSWORD_FILE" = /run/fleet-test/password ]
          [ "$RESTIC_CACHE_DIR" = /var/lib/fleet-backup/cache ]
          mkdir -p "$FLEET_BACKUP_STAGING_DIR/payload"
          printf valid >"$FLEET_BACKUP_STAGING_DIR/payload/data"
          [ ! -e /run/fleet-test/delayed-success ] || sleep 2
          [ ! -e /run/fleet-test/delayed-failure ] || { sleep 2; exit 17; }
          if [ -e /run/fleet-test/hostile ]; then
            setsid bash -c '
              trap "" TERM
              printf "%s\n" "$BASHPID" >/run/fleet-test/writer-pid
              while :; do
                printf x >>"$FLEET_BACKUP_STAGING_DIR/payload/growing"
                sleep 0.02
              done
            ' &
            while [ ! -e /run/fleet-test/writer-pid ]; do sleep 0.01; done
            exit 0
          fi
        '';
        restoreCommand = "true";
        requiredPaths = [ "payload/data" ];
        serviceUnits = [ ];
        healthCheckCommand = "true";
        failedStagingBytes = 1024;
        maxPayloadBytes = 65536;
      };
    };
  };

  testScript = ''
    start_all()
    machine.succeed("mkdir -p /run/fleet-test /var/lib/fleet-target")
    machine.succeed("printf repository >/run/fleet-test/repository; printf password >/run/fleet-test/password")
    machine.succeed("touch /run/fleet-test/delayed-success")
    machine.succeed("timeout 8 systemctl start fleet-backup-files.service")
    machine.succeed("test -e /run/fleet-test/backed-up")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
    machine.succeed("rm /run/fleet-test/delayed-success /run/fleet-test/backed-up")
    machine.succeed("touch /run/fleet-test/delayed-failure")
    machine.succeed("systemctl start --no-block fleet-backup-files.service")
    machine.wait_until_succeeds("systemctl is-failed --quiet fleet-backup-files.service")
    machine.succeed("test \"$(systemctl show fleet-backup-files.service -P ExecMainStatus)\" -eq 17")
    machine.fail("test -e /run/fleet-test/backed-up")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
    machine.succeed("rm /run/fleet-test/delayed-failure; systemctl reset-failed fleet-backup-files.service")
    machine.succeed("touch /run/fleet-test/hostile")
    machine.execute("systemctl start fleet-backup-files.service >/run/fleet-test/start-output 2>&1 & echo $! >/run/fleet-test/start-pid")
    machine.wait_until_succeeds("test -s /run/fleet-test/writer-pid")
    bounded_unit = machine.succeed("systemctl list-units --all 'fleet-bounded-*' --plain --no-legend | grep -o 'fleet-bounded[^ ]*\\.service' | head -1").strip()
    control_group = machine.succeed(f"systemctl show {bounded_unit} -P ControlGroup").strip()
    machine.succeed(f"test $(stat -c %s /sys/fs/cgroup{control_group}/cgroup.procs) -eq 0")
    machine.succeed(f"test -n \"$(cat /sys/fs/cgroup{control_group}/cgroup.procs)\"")
    start_pid = machine.succeed("cat /run/fleet-test/start-pid").strip()
    machine.succeed(f"timeout 8 tail --pid={start_pid} -f /dev/null")
    machine.succeed("systemctl is-failed --quiet fleet-backup-files.service")
    writer_pid = machine.succeed("cat /run/fleet-test/writer-pid").strip()
    machine.fail(f"kill -0 {writer_pid}")
    size_before = machine.succeed("du -sb /var/lib/fleet-backup/files/failed | cut -f1").strip()
    machine.sleep(1)
    machine.succeed(f"test $(du -sb /var/lib/fleet-backup/files/failed | cut -f1) -eq {size_before}")
    machine.succeed("test $(du -sb /var/lib/fleet-backup/files/failed | cut -f1) -le 1024")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
    machine.succeed("rm /run/fleet-test/hostile")
    for _ in range(50):
        machine.succeed("rm -f /run/fleet-test/backed-up")
        machine.succeed("systemctl reset-failed fleet-backup-files.service")
        machine.succeed("timeout 8 systemctl start fleet-backup-files.service")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
  '';
}
