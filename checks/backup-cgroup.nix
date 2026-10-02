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
    fleet.backup = {
      repositoryFile = "/run/fleet-test/repository";
      passwordFile = "/run/fleet-test/password";
      jobs.files = {
        frequency = "hourly";
        paths = [ "/var/lib/fleet-target" ];
        createCommand = ''
          mkdir -p "$FLEET_BACKUP_STAGING_DIR/payload"
          printf valid >"$FLEET_BACKUP_STAGING_DIR/payload/data"
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
    machine.succeed("touch /run/fleet-test/hostile")
    machine.fail("timeout 8 systemctl start fleet-backup-files.service")
    writer_pid = machine.succeed("cat /run/fleet-test/writer-pid").strip()
    machine.fail(f"kill -0 {writer_pid}")
    size_before = machine.succeed("du -sb /var/lib/fleet-backup/files/failed | cut -f1").strip()
    machine.sleep(1)
    machine.succeed(f"test $(du -sb /var/lib/fleet-backup/files/failed | cut -f1) -eq {size_before}")
    machine.succeed("test $(du -sb /var/lib/fleet-backup/files/failed | cut -f1) -le 1024")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
    machine.succeed("rm /run/fleet-test/hostile")
    machine.succeed("timeout 8 systemctl start fleet-backup-files.service")
  '';
}
