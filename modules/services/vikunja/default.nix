{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.vikunja;
  group = config.services.fleet.storageApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
  health = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:3456/api/v1/info";
in
{
  imports = [
    ../../fleet/local-postgres.nix
    ../storage-shared.nix
  ];
  options.services.fleet.vikunja.enable = lib.mkEnableOption "Vikunja with local PG17";
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /var/lib/vikunja 0750 storage-apps storage-apps -" ];
    systemd.services = {
      podman-vikunja = {
        requires = [ "postgres-vikunja.service" ];
        after = [ "postgres-vikunja.service" ];
        unitConfig.ConditionPathExists = group.vikunjaEnvironmentFile;
        serviceConfig.EnvironmentFile = group.vikunjaEnvironmentFile;
        serviceConfig.ExecCondition = [
          "${pkgs.coreutils}/bin/test -s ${group.vikunjaConfigFile}"
          "${pkgs.coreutils}/bin/test -s /var/lib/vikunja/.fleet-restored"
          "${pkgs.writeShellScript "vikunja-credentials-present" ''
            test -n "''${VIKUNJA_DATABASE_PASSWORD:-}" &&
            test -n "''${VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_CLIENTSECRET:-}"
          ''}"
        ];
      };
      postgres-vikunja.serviceConfig.ExecCondition = [
        "${pkgs.coreutils}/bin/test -s /var/lib/vikunja/.fleet-restored"
        "${pkgs.writeShellScript "vikunja-database-credentials-present" ''
          test -n "''${VIKUNJA_DATABASE_PASSWORD:-}"
        ''}"
      ];
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.vikunja = {
        image = "docker.io/vikunja/vikunja@sha256:e2204a1c1c6a81e833c2b3a5442be182ca2335b54c2e7e37578cc3fe12a27cfc";
        environmentFiles = [ group.vikunjaEnvironmentFile ];
        environment = {
          VIKUNJA_DATABASE_TYPE = "postgres";
          VIKUNJA_DATABASE_HOST = "127.0.0.1:5434";
          VIKUNJA_DATABASE_DATABASE = "app";
          VIKUNJA_DATABASE_USER = "app";
          VIKUNJA_DATABASE_NAME = "vikunja";
          VIKUNJA_SERVICE_INTERFACE = "127.0.0.1:3456";
          VIKUNJA_SERVICE_PUBLICURL = "https://vikunja.tailbc181.ts.net/";
          VIKUNJA_AUTH_LOCAL_ENABLED = "false";
          VIKUNJA_AUTH_OPENID_ENABLED = "true";
        };
        volumes = [
          "/var/lib/vikunja:/app/vikunja/files"
          "${group.vikunjaConfigFile}:/etc/vikunja/config.yml:ro"
        ];
        # Reach the loopback-only native cluster without exposing the HTTP listener.
        extraOptions = [ "--network=host" ];
      };
    };
    fleet = {
      localPostgres.vikunja = {
        package = pkgs.postgresql_17;
        port = 5434;
        environmentFile = group.vikunjaEnvironmentFile;
        initializeSQL = ''
          SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
          \getenv password VIKUNJA_DATABASE_PASSWORD
          ALTER ROLE app PASSWORD :'password';
          SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
        '';
      };
      backup.jobs = {
        vikunja-files =
          (backups.state {
            name = "vikunja";
            path = "/var/lib/vikunja";
            online = true;
            owner = "storage-apps";
            group = "storage-apps";
            healthCheckCommand = health;
          })
          // {
            maxPayloadBytes = 17179869184;
          };
        vikunja-db = backups.database {
          name = "vikunja";
          package = pkgs.postgresql_17;
          user = "postgres-vikunja";
          socket = "/run/postgres-vikunja";
          port = 5434;
          dataPath = "/var/lib/postgres-vikunja";
          healthCheckCommand = health;
        };
      };
      ingress.routes = [
        {
          hostname = "vikunja.tailbc181.ts.net";
          upstream = "http://127.0.0.1:3456";
          exposure = "tailnet";
        }
      ];
    };
  };
}
