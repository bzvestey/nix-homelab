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
            printf '%s\n' '[{"id":"snapshot-good","tags":["fleet-job=files","fleet-job=kavita-state","fleet-job=wallos-state","fleet-job=tailscale-fixture-state"]}]'
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
      ../modules/services/wallos
    ];
    system.stateVersion = "26.05";
    environment.systemPackages = [
      pkgs.util-linux
      pkgs.sqlite
      pkgs.curl
      pkgs.python3
    ];
    services.fleet.kavita.enable = true;
    services.fleet.wallos.enable = true;
    systemd.services = {
      podman-wallos = lib.mkForce {
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "wallos-writer.py" ''
          import sqlite3, time
          from http.server import HTTPServer, SimpleHTTPRequestHandler
          from threading import Thread
          def write():
              db = sqlite3.connect('/var/lib/wallos/db/wallos.db')
              db.execute('PRAGMA journal_mode=WAL')
              db.execute('PRAGMA wal_autocheckpoint=0')
              db.execute('CREATE TABLE reading (id INTEGER PRIMARY KEY)')
              db.execute('CREATE TABLE progress (id INTEGER PRIMARY KEY)')
              while True:
                  with db:
                      row = db.execute('INSERT INTO reading DEFAULT VALUES').lastrowid
                      db.execute('INSERT INTO progress VALUES (?)', (row,))
                  time.sleep(0.01)
          Thread(target=write, daemon=True).start()
          HTTPServer(('127.0.0.1', 8282), SimpleHTTPRequestHandler).serve_forever()
        ''}";
      };
      tailscale-fixture = {
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8999 --bind 127.0.0.1";
      };
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
        jobs.tailscale-fixture-state =
          (import ../lib/application-backups.nix { inherit pkgs lib; }).tailscaleIdentity
            {
              name = "fixture";
              healthCheckCommand = "${pkgs.curl}/bin/curl --fail --retry 5 --retry-all-errors --retry-delay 1 http://127.0.0.1:8999/";
            };
        jobs.files = {
          frequency = "*-*-* 06:00:00 America/Los_Angeles";
          interruptsService = true;
          backupClass = "database";
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
    machine.succeed("test $(systemctl show fleet-backup-files.timer -P Persistent) = no; test $(systemctl show fleet-backup-files.timer -P RandomizedDelayUSec) = 0")
    machine.succeed("python3 ${pkgs.writeText "identity-fixture.py" ''
      import base64, json
      from pathlib import Path
      def encode(value):
          return base64.b64encode(value.encode()).decode()
      root = Path('/var/lib/tailscale-fixture')
      (root / 'certs').mkdir(parents=True)
      (root / 'certs' / 'fixture.key').write_text('cached, not identity')
      prefs = {'Config': {'PrivateNodeKey': 'privkey:' + '2' * 64, 'NodeID': 'nFixture17'}, 'WantRunning': True, 'LoggedOut': False}
      profiles = {'1234': {'ID': '1234', 'Key': 'profile-1234', 'NodeID': 'nFixture17'}}
      state = {'_machinekey': encode('privkey:' + '1' * 64), '_current-profile': encode('profile-1234'), '_profiles': encode(json.dumps(profiles)), 'profile-1234': encode(json.dumps(prefs)), '_serve/1234': encode('{"TCP":{"443":{"HTTPS":true}}}')}
      (root / 'tailscaled.state').write_text(json.dumps(state))
    ''}")
    machine.succeed("systemctl start tailscale-fixture")
    identity_invocation = machine.succeed("systemctl show tailscale-fixture -P InvocationID").strip()
    machine.succeed("systemctl start fleet-backup-tailscale-fixture-state; fleet-restore tailscale-fixture-state --rehearsal")
    machine.succeed(f"test $(systemctl show tailscale-fixture -P InvocationID) = {identity_invocation}; curl --fail http://127.0.0.1:8999/")
    machine.succeed("cmp /var/lib/tailscale-fixture/tailscaled.state /var/lib/fleet-backup/tailscale-fixture-state/last-good/state/tailscaled.state; test ! -e /var/lib/fleet-backup/tailscale-fixture-state/last-good/state/certs")
    machine.succeed("cp /var/lib/tailscale-fixture/tailscaled.state /run/fleet-test/identity-good")
    # Syntactically valid JSON and base64 are insufficient: current-profile
    # must resolve to the matching persisted identity, not a different profile.
    machine.succeed("python3 -c \"import json,base64; p='/var/lib/tailscale-fixture/tailscaled.state'; s=json.load(open(p)); s['_current-profile']=base64.b64encode(b'profile-5678').decode(); json.dump(s,open(p,'w'))\"")
    machine.fail("systemctl start fleet-backup-tailscale-fixture-state")
    machine.succeed(f"test $(systemctl show tailscale-fixture -P InvocationID) = {identity_invocation}")
    machine.succeed("systemctl stop tailscale-fixture; find /var/lib/tailscale-fixture -mindepth 1 -delete; fleet-restore tailscale-fixture-state; cmp /run/fleet-test/identity-good /var/lib/tailscale-fixture/tailscaled.state; rm -f /run/fleet-test/backed-up")
    # A multi-database SQLite capture must not restart the application, must
    # preserve each database and assets, and must omit live sidecars.
    machine.succeed("mkdir -p /var/lib/wallos/{db,logos}; printf logo >/var/lib/wallos/logos/custom.png")
    machine.succeed("sqlite3 /var/lib/wallos/db/wallos.db \"CREATE TABLE subscriptions(id INTEGER PRIMARY KEY); INSERT INTO subscriptions VALUES(17),(31);\"")
    machine.succeed("sqlite3 /var/lib/wallos/db/setup_token.db \"CREATE TABLE tokens(value TEXT); INSERT INTO tokens VALUES('fixture');\"")
    machine.succeed("systemctl start podman-wallos")
    machine.wait_until_succeeds("sqlite3 /var/lib/wallos/db/wallos.db 'SELECT count(*) FROM reading' | grep -Eq '^[1-9][0-9]+$'")
    wallos_invocation = machine.succeed("systemctl show podman-wallos -P InvocationID").strip()
    machine.succeed("systemctl start fleet-backup-wallos-state")
    machine.succeed(f"test $(systemctl show podman-wallos -P InvocationID) = {wallos_invocation}; curl --fail http://127.0.0.1:8282/")
    wallos_snapshot = "/var/lib/fleet-backup/wallos-state/last-good/state"
    machine.succeed(f"test $(sqlite3 {wallos_snapshot}/db/wallos.db 'SELECT sum(id) FROM subscriptions') = 48; test $(sqlite3 {wallos_snapshot}/db/setup_token.db 'SELECT value FROM tokens') = fixture; test $(cat {wallos_snapshot}/logos/custom.png) = logo")
    machine.succeed(f"sqlite3 {wallos_snapshot}/db/wallos.db 'SELECT count(*) > 0 AND count(*) = (SELECT count(*) FROM progress) FROM reading' | grep -qx 1; test ! -e {wallos_snapshot}/db/wallos.db-wal; test ! -e {wallos_snapshot}/db/wallos.db-shm")
    machine.succeed("fleet-restore wallos-state --rehearsal")
    machine.succeed("mv /var/lib/wallos/db/setup_token.db /var/lib/wallos/db/setup_token.saved; printf corrupt >/var/lib/wallos/db/setup_token.db")
    machine.fail("systemctl start fleet-backup-wallos-state")
    machine.succeed(f"test $(systemctl show podman-wallos -P InvocationID) = {wallos_invocation}")
    machine.succeed("mv /var/lib/wallos/db/setup_token.saved /var/lib/wallos/db/setup_token.db; rm -f /run/fleet-test/backed-up")
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
    machine.succeed("grep -Fx 'fleet_backup_alert_threshold_seconds{job=\"files\",class=\"database\"} 93600' /var/lib/node_exporter/textfile_collector/fleet_backup_files.prom")
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
