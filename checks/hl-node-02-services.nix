{ pkgs }:
let
  inherit (pkgs) lib;
  testPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = package: lib.getName package == "dragonflydb";
  };
  image =
    imageName: imageDigest: hash:
    pkgs.dockerTools.pullImage {
      inherit imageName imageDigest hash;
      finalImageTag = "fixture";
      arch = "amd64";
    };
  images = {
    immich =
      image "ghcr.io/immich-app/immich-server"
        "sha256:79cc1623323d5894922686d8743b4780181428f98eecbfb58ce12c41ef02d1ea"
        "sha256-ThzH2Ucww1a3EYQ3vf9a0CzT3OtxYRQknQmyJJrxoBg=";
    immich-ml =
      image "ghcr.io/immich-app/immich-machine-learning"
        "sha256:60dfcf266a9ef3b7376f5678e8c980d4fb61db5fc48c078fe8a326ab1535d60d"
        "sha256-xqII+awa+ke8whXhVTDgWMghHgzHkHLq2d1kMXUkQQ0=";
    mealie =
      image "ghcr.io/mealie-recipes/mealie"
        "sha256:8b02290f4d1806f02acac6f25f6d48a3c965612fda1f8e914d5af533276f8688"
        "sha256-vu6yi+A/a6K/E13RzgjvvOqvrk7KsM5TDgRFl7Ps7zA=";
    tuwunel =
      image "docker.io/jevolk/tuwunel"
        "sha256:678b7f5350e06a41614444497c587da9dddf66767e4068a27480402f3c1367d0"
        "sha256-cb/haDoOaM3IuRoQrw++plMc/Vbj/CrunuNeajRXKTQ=";
  };
  pg16 = import ../packages/immich-postgresql.nix { inherit pkgs; };
  tuwunelConfig = pkgs.writeText "tuwunel-fixture.toml" ''
    [global]
    server_name = "matrix.minastas.social"
    database_path = "/var/lib/tuwunel"
    address = ["0.0.0.0"]
    port = 8008
    allow_registration = true
    registration_token = "fixture-registration"
    allow_federation = false
    login_with_password = true

    [[global.identity_provider]]
    brand = "pocket-id"
    name = "PocketID"
    client_id = "9c05911b-c58f-449f-9792-40e87bb25b12"
    client_secret = "fixture-only-oidc"
    issuer_url = "https://id.minastas.xyz"
    callback_url = "https://matrix.minastas.social/_matrix/client/unstable/login/sso/callback/9c05911b-c58f-449f-9792-40e87bb25b12"
    default = true
    userid_claims = ["preferred_username"]
  '';
in
testPkgs.testers.runNixOSTest {
  name = "hl-node-02-services";
  nodes.nas = {
    services.nfs.server = {
      enable = true;
      exports = "/srv/library 192.168.1.0/24(rw,no_subtree_check,no_root_squash,insecure)";
    };
    systemd.tmpfiles.rules = [ "d /srv/library 0777 root root -" ];
    networking.firewall.enable = false;
  };
  nodes.machine = { config, ... }: {
    imports = [
      ../modules/fleet/podman.nix
      ../modules/fleet/storage.nix
      ../modules/fleet/backup.nix
      ../modules/fleet/ingress.nix
      ../modules/fleet/telemetry-agent.nix
      ../modules/services/immich
      ../modules/services/mealie
      ../modules/services/tuwunel
    ];
    virtualisation = {
      memorySize = 8192;
      cores = 4;
      diskSize = 32768;
      oci-containers.containers = lib.mapAttrs (_: img: {
        image = lib.mkForce "${img.imageName}:fixture";
        imageFile = img;
      }) images;
    };
    networking.firewall.enable = false;
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
      pkgs.restic
      pkgs.postgresql_17
      pg16
    ];
    services.fleet = {
      immich.enable = true;
      immich.librarySource = "nas:/srv/library";
      mealie.enable = true;
      tuwunel.enable = true;
    };
    fleet = {
      ingress = {
        enableTailscale = false;
        testUseInternalTls = true;
      };
      backup = {
        repositoryFile = "/run/repository";
        passwordFile = "/run/restic-password";
      };
    };
    environment.etc."fixture-commands.json".text = builtins.toJSON (
      lib.mapAttrs (_: job: {
        inherit (job)
          createCommand
          restoreCommand
          frequency
          backupClass
          ;
      }) config.fleet.backup.jobs
    );
  };
  testScript = ''
    import json
    import shlex
    start_all()
    nas.wait_for_unit("nfs-server")
    machine.wait_for_unit("multi-user.target")
    # Literal policy expectations catch database payloads mislabeled as state.
    backup_policy = {
        "immich-db": ("hourly", "database", 5400),
        "mealie-db": ("hourly", "database", 5400),
        "mealie-state": ("daily", "state", 93600),
        "tuwunel-state": ("hourly", "database", 5400),
    }
    commands = json.loads(machine.succeed("cat /etc/fixture-commands.json"))
    assert set(commands) == set(backup_policy)
    for job, (frequency, backup_class, threshold) in backup_policy.items():
        actual = (commands[job]["frequency"], commands[job]["backupClass"])
        assert actual == (frequency, backup_class), f"{job}: expected {(frequency, backup_class)}, got {actual}"
        timer = machine.succeed(f"systemctl cat fleet-backup-{job}.timer")
        assert f"OnCalendar={frequency}\n" in timer, timer
    for unit in ["postgres-immich", "postgresql", "podman-immich", "podman-immich-ml", "podman-mealie", "podman-tuwunel"]:
        machine.fail(f"systemctl is-active --quiet {unit}")
        assert machine.succeed(f"systemctl show {unit} -P NRestarts").strip() == "0"
    machine.succeed("systemctl cat fleet-backup-immich-db fleet-backup-mealie-db fleet-backup-mealie-state fleet-backup-tuwunel-state")
    machine.succeed("install -d -m 700 /run/secrets; printf 'DB_PASSWORD=immich-fixture\n' >/run/secrets/immich.env; printf 'POSTGRES_PASSWORD=mealie-fixture\nOIDC_CLIENT_SECRET=oidc-fixture\n' >/run/secrets/mealie.env; chmod 600 /run/secrets/*.env")
    machine.succeed("install -m 600 ${tuwunelConfig} /run/secrets/tuwunel.toml")
    machine.succeed("systemctl start postgres-immich postgresql.target")
    machine.succeed("systemctl start podman-immich podman-immich-ml podman-mealie podman-tuwunel")
    for url in ["http://127.0.0.1:2283/api/server/ping", "http://127.0.0.1:3003/ping", "http://127.0.0.1:9000/api/app/about", "http://127.0.0.1:8008/_matrix/client/versions"]:
        machine.wait_until_succeeds(f"curl -fsS {url}", timeout=240)
    def sql(app, query):
        user, socket, port, binary = ("postgres-immich", "/run/postgres-immich", 5433, "${pg16}/bin/psql") if app == "immich" else ("postgres", "/run/postgresql", 5432, "${pkgs.postgresql_17}/bin/psql")
        return machine.succeed(f"runuser -u {user} -- {binary} -h {socket} -p {port} -d app -qAt -v ON_ERROR_STOP=1 -c {shlex.quote(query)}").strip()
    assert sql("immich", "SHOW server_version_num")[:2] == "16"
    assert sql("mealie", "SHOW server_version_num")[:2] == "17"
    assert sql("immich", "SELECT extversion FROM pg_extension WHERE extname='vchord'") == "0.4.3"
    assert sql("immich", "SELECT extversion FROM pg_extension WHERE extname='vector'") == "0.8.0"
    for extension, version in [("cube", "1.5"), ("earthdistance", "1.2"), ("pg_trgm", "1.6"), ("unaccent", "1.1"), ("uuid-ossp", "1.1")]:
        assert sql("immich", f"SELECT extversion FROM pg_extension WHERE extname='{extension}'") == version
    assert sql("mealie", "SELECT extversion FROM pg_extension WHERE extname='pg_trgm'") == "1.6"
    sql("immich", "CREATE TABLE fleet_vectors (id integer PRIMARY KEY, embedding vector(3)); INSERT INTO fleet_vectors VALUES (17,'[1,2,3]'),(31,'[9,8,7]'); CREATE INDEX fleet_vector_index ON fleet_vectors USING vchordrq (embedding vector_l2_ops) WITH (options=$$[build.internal]\nlists=[1]$$)")
    assert sql("immich", "SET vchordrq.probes=1; SELECT id FROM fleet_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1") == "17"
    # Both actual apps have migrated their schemas, not just opened a TCP socket.
    assert int(sql("immich", "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")) > 20
    assert int(sql("mealie", "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")) > 20
    for app, records in [("immich", "(13,'photo-a'),(29,'settings-b')"), ("mealie", "(7,'recipe-x'),(41,'recipe-y'),(53,'recipe-z')")]:
        sql(app, f"CREATE TABLE fleet_fixture (id integer PRIMARY KEY, value text); INSERT INTO fleet_fixture VALUES {records}; ALTER TABLE fleet_fixture OWNER TO app;")
    for app in ["immich", "mealie"]:
        assert sql(app, "SELECT current_setting('shared_preload_libraries')") == ("vchord" if app == "immich" else "")
    machine.fail("runuser -u postgres -- ${pg16}/bin/psql -h /run/postgres-immich -p 5433 app -c 'SELECT 1'")
    machine.fail("runuser -u postgres-immich -- ${pkgs.postgresql_17}/bin/psql -h /run/postgresql app -c 'SELECT 1'")
    for path in ["/var/lib/postgres-immich", "/var/lib/postgresql/17", "/var/lib/mealie", "/var/lib/tuwunel", "/var/cache/immich-ml"]:
        machine.fail(f"findmnt -n -T {path} -o FSTYPE | grep -q '^nfs'")
    for port in [8081, 8082]:
        machine.wait_until_succeeds(f"curl -fsS http://127.0.0.1:{port}/metrics | grep -q '^# HELP'")
    settings = json.dumps({"newVersionCheck": {"enabled": False}, "oauth": {"enabled": False, "clientId": "restore-only-public-fixture"}, "server": {"externalDomain": "https://immich.tailbc181.ts.net"}})
    sql("immich", "INSERT INTO system_metadata (key,value) VALUES ('system-config','" + settings + "') ON CONFLICT (key) DO UPDATE SET value=excluded.value")
    def matrix_post(path, payload):
        return json.loads(machine.succeed("curl -sS -H 'Content-Type: application/json' http://127.0.0.1:8008/_matrix/client/v3/" + path + " -d " + shlex.quote(json.dumps(payload))))
    matrix_users = []
    for username, device in [("restore_alice", "DEVICE17"), ("restore_bob", "DEVICE31")]:
        payload = {"username": username, "password": "fixture-only-matrix", "device_id": device}
        response = matrix_post("register", payload)
        payload["auth"] = {"type": "m.login.registration_token", "token": "fixture-registration", "session": response["session"]}
        response = matrix_post("register", payload)
        assert response["user_id"] == f"@{username}:matrix.minastas.social"
        matrix_users.append((username, device))
    machine.succeed("curl -fsS http://127.0.0.1:8008/_matrix/client/v3/login | jq -e '.flows | any(.type == \"m.login.sso\")'")
    machine.succeed("podman inspect mealie | jq -e '.[0].Config.Env | index(\"OIDC_PROVIDER_NAME=PocketID\") != null and index(\"ALLOW_PASSWORD_LOGIN=false\") != null and index(\"OIDC_CLIENT_SECRET=oidc-fixture\") != null' >/dev/null")
    machine.fail("PGPASSWORD=immich-fixture ${pkgs.postgresql_17}/bin/psql -h 127.0.0.1 -p 5432 -U app app -c 'SELECT 1'")
    machine.fail("PGPASSWORD=mealie-fixture ${pg16}/bin/psql -h 127.0.0.1 -p 5433 -U app app -c 'SELECT 1'")
    machine.succeed("printf /var/lib/test-repository >/run/repository; printf fixture-restic >/run/restic-password; RESTIC_REPOSITORY=/var/lib/test-repository RESTIC_PASSWORD_FILE=/run/restic-password restic init")
    jobs = ["immich-db", "mealie-db", "mealie-state", "tuwunel-state"]
    # Mealie appends its root-level mealie.log during startup. Session/signing
    # keys and profile/recipe files, unlike that volatile journal, must match.
    mealie_manifest_command = "find /var/lib/mealie -type f ! -name '*.log' ! -path '*/logs/*' -exec sha256sum {} + | sort"
    mealie_manifest = machine.succeed(mealie_manifest_command)
    machine.log("Mealie initial state manifest:\n" + mealie_manifest)
    assert mealie_manifest.strip()
    for job in jobs:
        machine.succeed(f"fleet-backup-run {job}", timeout=180)
        frequency, backup_class, threshold = backup_policy[job]
        metrics = machine.succeed(f"cat /var/lib/node_exporter/textfile_collector/fleet_backup_{job}.prom")
        assert f'fleet_backup_result{{job="{job}",class="{backup_class}"}} 1' in metrics, metrics
        assert f'fleet_backup_alert_threshold_seconds{{job="{job}",class="{backup_class}"}} {threshold}' in metrics, metrics
        machine.succeed(f"fleet-restore {job} --rehearsal", timeout=180)
    expected = {app: sql(app, "SELECT id,value FROM fleet_fixture ORDER BY id") for app in ["immich", "mealie"]}
    commands = json.loads(machine.succeed("cat /etc/fixture-commands.json"))
    assert set(commands) == set(jobs)
    # An invalid logical dump must not drop either application's live database.
    machine.succeed("systemctl stop podman-immich")
    machine.succeed("mkdir -p /run/bad-dump; printf invalid >/run/bad-dump/database.dump")
    machine.fail("FLEET_RESTORE_SOURCE_DIR=/run/bad-dump bash -euo pipefail -c " + shlex.quote(commands["immich-db"]["restoreCommand"]))
    assert sql("immich", "SELECT id,value FROM fleet_fixture ORDER BY id") == expected["immich"]
    assert sql("mealie", "SELECT id,value FROM fleet_fixture ORDER BY id") == expected["mealie"]
    for app in ["immich", "mealie"]:
        sql(app, "TRUNCATE fleet_fixture")
        machine.fail(f"fleet-restore {app}-db", timeout=60)
        machine.succeed(f"fleet-restore {app}-db --force", timeout=240)
        assert sql(app, "SELECT id,value FROM fleet_fixture ORDER BY id") == expected[app]
        assert sql(app, "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='app'") == "app"
        assert sql(app, "SELECT tableowner FROM pg_tables WHERE tablename='fleet_fixture'") == "app"
        assert sql(app, "SELECT count(*) FROM pg_database WHERE datname LIKE 'fleet_restore_%'") == "0"
    assert sql("immich", "SET vchordrq.probes=1; SELECT id FROM fleet_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1") == "17"
    assert json.loads(sql("immich", "SELECT value FROM system_metadata WHERE key='system-config'")) == json.loads(settings)
    machine.succeed("curl -fsS http://127.0.0.1:2283/api/server/config | jq -e '.externalDomain == \"https://immich.tailbc181.ts.net\"'")
    for job in ["mealie-state", "tuwunel-state"]:
        app = job.removesuffix("-state")
        machine.succeed(f"systemctl stop podman-{app}; find /var/lib/{app} -mindepth 1 -delete; fleet-restore {job}", timeout=240)
    for username, device in matrix_users:
        response = matrix_post("login", {"type": "m.login.password", "identifier": {"type": "m.id.user", "user": username}, "password": "fixture-only-matrix", "device_id": device})
        assert response["user_id"] == f"@{username}:matrix.minastas.social"
        assert response["device_id"] == device
    machine.succeed("test $(stat -c %U:%G /var/lib/mealie) = mealie:mealie")
    restored_mealie_manifest = machine.succeed(mealie_manifest_command)
    machine.log("Mealie restored state manifest:\n" + restored_mealie_manifest)
    assert restored_mealie_manifest == mealie_manifest
    machine.succeed("curl -fsS -H 'Host: matrix.minastas.social' http://127.0.0.1:8080/_matrix/client/versions")
    machine.succeed("curl -kfsS --resolve immich.tailbc181.ts.net:443:127.0.0.1 https://immich.tailbc181.ts.net/api/server/ping")
    machine.succeed("curl -kfsS --resolve mealie.tailbc181.ts.net:443:127.0.0.1 https://mealie.tailbc181.ts.net/api/app/about")
    machine.succeed("systemctl stop mnt-bulk-immich.mount")
    machine.wait_until_fails("systemctl is-active --quiet podman-immich")
    machine.succeed("systemctl is-active --quiet podman-mealie podman-tuwunel postgres-immich postgresql")
    machine.succeed("systemctl stop mnt-bulk-immich.automount")
    machine.log(machine.succeed("stat -c '%a %U:%G' /mnt/bulk/immich; ls -la /mnt/bulk/immich"))
    machine.succeed("test $(stat -c %a /mnt/bulk/immich) = 555; test -z \"$(ls -A /mnt/bulk/immich)\"")
    nas.succeed("systemctl stop nfs-server")
    machine.succeed("systemctl start mnt-bulk-immich.automount")
    machine.fail("systemctl start podman-immich", timeout=30)
    machine.fail("systemctl is-active --quiet podman-immich")
    machine.succeed("systemctl is-active --quiet podman-mealie podman-tuwunel")
    nas.succeed("systemctl start nfs-server")
    machine.succeed("systemctl reset-failed mnt-bulk-immich.mount podman-immich; systemctl start podman-immich")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:2283/api/server/ping")
    machine.succeed("systemctl stop podman-mealie; mv /run/secrets/mealie.env /run/mealie-withheld; systemctl start podman-mealie")
    machine.fail("systemctl is-active --quiet podman-mealie")
  '';
}
