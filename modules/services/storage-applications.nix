{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.storageApplications;
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
  health =
    port: path:
    "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:${toString port}${path}";
  state =
    name: path: port: endpoint:
    backups.state {
      inherit name path;
      owner = "storage-apps";
      group = "storage-apps";
      healthCheckCommand = health port endpoint;
    };
  runtimeOption =
    name:
    lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/${name}";
      description = "Enrolled runtime file; never place credentials in the Nix store.";
    };
  lsioEnvironment = {
    PUID = "1000";
    PGID = "1000";
    TZ = "America/Los_Angeles";
  };
in
{
  imports = [ ../fleet/local-postgres.nix ];
  options.services.fleet.storageApplications = {
    enable = lib.mkEnableOption "source-compatible storage applications";
    jellyfinEnvironmentFile = runtimeOption "jellyfin.env";
    kavitaEnvironmentFile = runtimeOption "kavita.env";
    vikunjaEnvironmentFile = runtimeOption "vikunja.env";
    vikunjaConfigFile = runtimeOption "vikunja-config.yml";
  };
  config = lib.mkIf cfg.enable {
    users.groups.storage-apps.gid = 1000;
    users.users.storage-apps = {
      isSystemUser = true;
      uid = 1000;
      group = "storage-apps";
      extraGroups = [
        "video"
        "render"
      ];
    };
    hardware.graphics.enable = true;
    systemd.tmpfiles.rules = [
      "d /var/lib/jellyfin 0750 storage-apps storage-apps -"
      "d /var/lib/kavita 0750 storage-apps storage-apps -"
      "d /var/lib/vikunja 0750 storage-apps storage-apps -"
    ];
    systemd.services = {
      podman-jellyfin = {
        unitConfig.ConditionPathExists = cfg.jellyfinEnvironmentFile;
        serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test -s /var/lib/jellyfin/.fleet-restored";
      };
      podman-kavita = {
        unitConfig.ConditionPathExists = cfg.kavitaEnvironmentFile;
        serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test -s /var/lib/kavita/.fleet-restored";
      };
      podman-vikunja = {
        requires = [ "postgres-vikunja.service" ];
        after = [ "postgres-vikunja.service" ];
        unitConfig.ConditionPathExists = cfg.vikunjaEnvironmentFile;
        serviceConfig.EnvironmentFile = cfg.vikunjaEnvironmentFile;
        serviceConfig.ExecCondition = [
          "${pkgs.coreutils}/bin/test -s ${cfg.vikunjaConfigFile}"
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
      containers = {
        jellyfin = {
          image = "ghcr.io/linuxserver/jellyfin@sha256:1bb4f88d822a0510bb3604b68aacb80d77c1d2a30181e500090c65111b98723b";
          ports = [ "127.0.0.1:8096:8096" ];
          environmentFiles = [ cfg.jellyfinEnvironmentFile ];
          environment = lsioEnvironment // {
            JELLYFIN_PublishedServerUrl = "https://jellyfin.tailbc181.ts.net/";
          };
          volumes = [
            "/var/lib/jellyfin:/config"
            "/mnt/bulk/videos:/data:ro"
          ];
          extraOptions = [ "--device=/dev/dri:/dev/dri" ];
        };
        kavita = {
          image = "docker.io/linuxserver/kavita@sha256:2842f1c0882b9d0ce3103420eea0a90b27e4537ff29f87b1471cdd752e936837";
          ports = [ "127.0.0.1:5000:5000" ];
          environmentFiles = [ cfg.kavitaEnvironmentFile ];
          environment = lsioEnvironment // {
            # Match Jellyfin's LSIO device-permission initialization for abc/PUID.
            ATTACHED_DEVICES_PERMS = "/dev/dri -type c";
          };
          volumes = [
            "/var/lib/kavita:/config"
            "/mnt/bulk/books:/data/books:ro"
            "/mnt/bulk/syncthing:/data/syncthing:ro"
          ];
          extraOptions = [ "--device=/dev/dri:/dev/dri" ];
        };
        vikunja = {
          image = "docker.io/vikunja/vikunja@sha256:e2204a1c1c6a81e833c2b3a5442be182ca2335b54c2e7e37578cc3fe12a27cfc";
          environmentFiles = [ cfg.vikunjaEnvironmentFile ];
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
            "${cfg.vikunjaConfigFile}:/etc/vikunja/config.yml:ro"
          ];
          # Reach the loopback-only native cluster without exposing the HTTP listener.
          extraOptions = [ "--network=host" ];
        };
      };
    };
    fleet = {
      localPostgres.vikunja = {
        package = pkgs.postgresql_17;
        port = 5434;
        environmentFile = cfg.vikunjaEnvironmentFile;
        initializeSQL = ''
          SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
          \getenv password VIKUNJA_DATABASE_PASSWORD
          ALTER ROLE app PASSWORD :'password';
          SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
        '';
      };
      storage.nfsMounts = {
        videos = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
          target = "/mnt/bulk/videos";
          dependentUnits = [ "podman-jellyfin" ];
        };
        books = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/Computer/books";
          target = "/mnt/bulk/books";
          dependentUnits = [ "podman-kavita" ];
        };
        syncthing = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/apps/syncthing";
          target = "/mnt/bulk/syncthing";
          dependentUnits = [ "podman-kavita" ];
        };
      };
      backup.jobs = {
        jellyfin-state = (state "jellyfin" "/var/lib/jellyfin" 8096 "/health") // {
          frequency = "hourly";
          backupClass = "database";
          maxPayloadBytes = 34359738368;
        };
        kavita-state = (state "kavita" "/var/lib/kavita" 5000 "/") // {
          frequency = "hourly";
          backupClass = "database";
          maxPayloadBytes = 137438953472;
        };
        vikunja-files = (state "vikunja" "/var/lib/vikunja" 3456 "/api/v1/info") // {
          maxPayloadBytes = 17179869184;
        };
        vikunja-db = backups.database {
          name = "vikunja";
          package = pkgs.postgresql_17;
          user = "postgres-vikunja";
          socket = "/run/postgres-vikunja";
          port = 5434;
          dataPath = "/var/lib/postgres-vikunja";
          healthCheckCommand = health 3456 "/api/v1/info";
        };
      };
      ingress.routes =
        map
          (app: {
            hostname = "${app.name}.tailbc181.ts.net";
            upstream = "http://127.0.0.1:${toString app.port}";
            exposure = "tailnet";
          })
          [
            {
              name = "jellyfin";
              port = 8096;
            }
            {
              name = "kavita";
              port = 5000;
            }
            {
              name = "vikunja";
              port = 3456;
            }
          ];
    };
  };
}
