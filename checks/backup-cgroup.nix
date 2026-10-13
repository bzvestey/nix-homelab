{ pkgs }:
let
  fakeRestic = pkgs.writeShellApplication {
    name = "restic";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      test "''${AWS_SHARED_CREDENTIALS_FILE:-}" = /run/fleet-test/s3-credentials
      test "''${AWS_PROFILE:-}" = default
      test "$(cat "$AWS_SHARED_CREDENTIALS_FILE")" = fixture-credentials
      case "$1" in
        snapshots)
          if printf '%s\n' "$*" | grep -Eq -- '--latest|snapshot-good' || [ -e /run/fleet-test/backed-up ]; then
            printf '%s\n' '[{"id":"snapshot-good","tags":["fleet-job=files","fleet-job=kavita-state"]}]'
          else
            printf '%s\n' '[]'
          fi
          ;;
        backup)
          cat >/run/fleet-test/archive
          touch /run/fleet-test/backed-up
          printf '%s\n' '{"message_type":"summary","snapshot_id":"snapshot-good"}'
          ;;
        dump) cat /run/fleet-test/archive ;;
        forget) ;;
        *) exit 2 ;;
      esac
    '';
  };
  testPkgs = pkgs.extend (_: _: { restic = fakeRestic; });
in
testPkgs.testers.runNixOSTest {
  name = "backup-cgroup-supervision";

  nodes.machine = { lib, ... }: {
    imports = [
      ../modules/fleet/backup.nix
      ../modules/fleet/storage.nix
      ../modules/fleet/ingress.nix
      ../modules/services/kavita
    ];
    system.stateVersion = "26.05";
    environment.systemPackages = [
      pkgs.util-linux
      pkgs.sqlite
      pkgs.curl
    ];
    services.fleet.kavita.enable = true;
    systemd.services = {
      podman-kavita = lib.mkForce {
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "kavita-writer.py" ''
          import sqlite3
          import time
          from http.server import HTTPServer, BaseHTTPRequestHandler
          from threading import Thread

          def write():
              db = sqlite3.connect('/var/lib/kavita/kavita.db')
              db.execute('PRAGMA journal_mode=WAL')
              db.execute('PRAGMA wal_autocheckpoint=0')
              db.execute('CREATE TABLE IF NOT EXISTS reading (id INTEGER PRIMARY KEY, value TEXT)')
              db.execute('CREATE TABLE IF NOT EXISTS progress (id INTEGER PRIMARY KEY)')
              while True:
                  with db:
                      row = db.execute("INSERT INTO reading(value) VALUES ('preserved')").lastrowid
                      db.execute('INSERT INTO progress VALUES (?)', (row,))
                  time.sleep(0.01)

          class Handler(BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b'healthy')

          Thread(target=write, daemon=True).start()
          HTTPServer(('127.0.0.1', 5000), Handler).serve_forever()
        ''}";
      };
      fleet-backup-files = {
        path = [ pkgs.bash ];
        environment.RESTIC_PASSWORD = "ambient-must-not-cross";
      };
    };
    fleet = {
      storage.nfsMounts = lib.mkForce { };
      ingress.routes = lib.mkForce [ ];
      backup = {
        repositoryFile = "/run/fleet-test/repository";
        passwordFile = "/run/fleet-test/password";
        s3CredentialsFile = "/run/fleet-test/s3-credentials";
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
            if [ -e /run/fleet-test/renaming ]; then
              ${pkgs.python3}/bin/python3 ${pkgs.writeText "renaming-assets.py" ''
                import os
                import time
                from pathlib import Path
                root = Path(os.environ['FLEET_BACKUP_STAGING_DIR']) / 'churn'
                root.mkdir()
                for i in range(200):
                    (root / f'{i}.tmp').write_bytes(b'asset')
                end = time.monotonic() + 4
                while time.monotonic() < end:
                    for i in range(200):
                        os.rename(root / f'{i}.tmp', root / f'{i}.new')
                        os.rename(root / f'{i}.new', root / f'{i}.tmp')
              ''}
            fi
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
          rehearsalCommand = ''test "$(cat "$FLEET_RESTORE_SOURCE_DIR/payload/data")" = valid'';
          requiredPaths = [ "payload/data" ];
          serviceUnits = [ ];
          healthCheckCommand = "true";
          failedStagingBytes = 1024;
          maxPayloadBytes = 4194304;
        };
      };
    };
  };

  testScript = ''
    start_all()
    machine.succeed("mkdir -p /run/fleet-test /var/lib/fleet-target")
    machine.succeed("printf repository >/run/fleet-test/repository; printf password >/run/fleet-test/password")
    machine.succeed("printf fixture-credentials >/run/fleet-test/s3-credentials")
    # A backup must retain committed WAL data without interrupting the writer.
    machine.succeed("mkdir -p /var/lib/kavita/{covers,backups,temp,cache,cache-long,templates}")
    machine.succeed("printf configured >/var/lib/kavita/appsettings.json; printf restored >/var/lib/kavita/.fleet-restored")
    machine.succeed("printf cover >/var/lib/kavita/covers/custom.webp; printf custom >/var/lib/kavita/templates/custom.html")
    machine.succeed("printf omitted >/var/lib/kavita/backups/old.zip; printf omitted >/var/lib/kavita/temp/partial; printf omitted >/var/lib/kavita/cache.db")
    machine.succeed("systemctl start podman-kavita.service")
    machine.wait_until_succeeds("sqlite3 /var/lib/kavita/kavita.db 'SELECT count(*) FROM reading' | grep -Eq '^[1-9][0-9]+$'")
    invocation = machine.succeed("systemctl show podman-kavita.service -P InvocationID").strip()
    machine.succeed("systemctl start fleet-backup-kavita-state.service")
    machine.succeed("curl --fail http://127.0.0.1:5000/")
    machine.succeed(f"test $(systemctl show podman-kavita.service -P InvocationID) = {invocation}")
    snapshot = "/var/lib/fleet-backup/kavita-state/last-good/state"
    machine.succeed(f"test $(sqlite3 {snapshot}/kavita.db 'PRAGMA integrity_check') = ok")
    machine.succeed(f"sqlite3 {snapshot}/kavita.db \"SELECT count(*) > 0 AND count(*) = (SELECT count(*) FROM progress) AND min(value) = 'preserved' FROM reading\" | grep -qx 1")
    machine.succeed(f"test $(cat {snapshot}/appsettings.json) = configured; test $(cat {snapshot}/covers/custom.webp) = cover; test $(cat {snapshot}/templates/custom.html) = custom")
    machine.succeed(f"test ! -e {snapshot}/kavita.db-wal; test ! -e {snapshot}/cache.db; test ! -e {snapshot}/backups; test ! -e {snapshot}/temp; test ! -e {snapshot}/cache; test ! -e {snapshot}/cache-long")
    machine.succeed("fleet-restore kavita-state --rehearsal")
    # Invalid database export must fail without stopping the running service.
    machine.succeed("mv /var/lib/kavita /var/lib/kavita.saved; mkdir /var/lib/kavita; printf corrupt >/var/lib/kavita/kavita.db; rm /run/fleet-test/backed-up")
    machine.fail("systemctl start fleet-backup-kavita-state.service")
    machine.succeed(f"test $(systemctl show podman-kavita.service -P InvocationID) = {invocation}; curl --fail http://127.0.0.1:5000/")
    machine.succeed("rm -r /var/lib/kavita; mv /var/lib/kavita.saved /var/lib/kavita")
    machine.succeed("fleet-restore kavita-state --snapshot snapshot-good --force")
    machine.succeed("curl --fail http://127.0.0.1:5000/; sqlite3 /var/lib/kavita/kavita.db \"SELECT count(*) > 0 FROM reading\" | grep -qx 1")
    machine.succeed("rm -f /run/fleet-test/backed-up")
    machine.succeed("touch /run/fleet-test/delayed-success")
    machine.succeed("timeout 8 systemctl start fleet-backup-files.service")
    machine.succeed("test -e /run/fleet-test/backed-up")
    machine.succeed("fleet-restore files --rehearsal; grep -F 'fleet_restore_rehearsal_result{job=\"files\",snapshot=\"snapshot-good\"} 1' /var/lib/node_exporter/textfile_collector/fleet_restore_rehearsal_files.prom")
    machine.fail("systemctl list-units --all 'fleet-bounded-*' --no-legend | grep -q .")
    machine.succeed("rm /run/fleet-test/delayed-success /run/fleet-test/backed-up")
    # Renames during traversal are not payload-bound violations.
    machine.succeed("touch /run/fleet-test/renaming")
    machine.succeed("timeout 60 systemctl start fleet-backup-files.service")
    machine.succeed("test $(find /var/lib/fleet-backup/files/last-good/churn -type f | wc -l) -eq 200")
    machine.succeed("rm /run/fleet-test/renaming /run/fleet-test/backed-up")
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
