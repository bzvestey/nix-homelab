{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.immich;
  postgres = import ../../../packages/immich-postgresql.nix { inherit pkgs; };
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
  health = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:2283/api/server/ping";
in
{
  imports = [ ../../fleet/local-postgres.nix ];
  options.services.fleet.immich = {
    enable = lib.mkEnableOption "pinned Immich with local PG16 and NAS library";
    environmentFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.*";
      default = "/run/secrets/immich.env";
      description = "Runtime environment containing DB_PASSWORD; shared with PG role initialization.";
    };
    librarySource = lib.mkOption {
      type = lib.types.str;
      default = "10.15.4.101:/mnt/spinners-1/kube-store/immich";
    };
  };
  config = lib.mkIf cfg.enable {
    nixpkgs.config = lib.mkDefault {
      allowUnfreePredicate = package: lib.getName package == "dragonflydb";
    };
    fleet = {
      localPostgres.immich = {
        package = postgres;
        port = 5433;
        inherit (cfg) environmentFile;
        preloadLibraries = [ "vchord" ];
        initializeSQL = ''
          SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
          \getenv password DB_PASSWORD
          ALTER ROLE app PASSWORD :'password';
          SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
          \connect app
          CREATE EXTENSION IF NOT EXISTS cube;
          CREATE EXTENSION IF NOT EXISTS earthdistance;
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS unaccent;
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
          CREATE EXTENSION IF NOT EXISTS vector VERSION '0.8.0';
          CREATE EXTENSION IF NOT EXISTS vchord VERSION '0.4.3';
        '';
      };
      storage.nfsMounts.immich-library = {
        source = cfg.librarySource;
        target = "/mnt/bulk/immich";
        dependentUnits = [ "podman-immich" ];
      };
      backup.jobs.immich-db = backups.database {
        name = "immich";
        package = postgres;
        user = "postgres-immich";
        socket = "/run/postgres-immich";
        port = 5433;
        dataPath = "/var/lib/postgres-immich";
        healthCheckCommand = health;
      };
      ingress.routes = [
        {
          hostname = "immich.tailbc181.ts.net";
          upstream = "http://127.0.0.1:2283";
          exposure = "tailnet";
        }
      ];
      telemetry.localPrometheusTargets = {
        immich-api = "127.0.0.1:8081";
        immich-microservices = "127.0.0.1:8082";
      };
    };
    services.dragonflydb = {
      enable = true;
      bind = "127.0.0.1";
      port = 6380;
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers = {
        immich = {
          image = "ghcr.io/immich-app/immich-server@sha256:db996e352359771c6a3db121a0ed8761516b22f727fc092a0f46dcfef82c1bc1";
          environmentFiles = [ cfg.environmentFile ];
          environment = {
            DB_HOSTNAME = "127.0.0.1";
            DB_PORT = "5433";
            DB_USERNAME = "app";
            DB_DATABASE_NAME = "app";
            REDIS_HOSTNAME = "127.0.0.1";
            REDIS_PORT = "6380";
            IMMICH_MACHINE_LEARNING_URL = "http://127.0.0.1:3003";
            IMMICH_TELEMETRY_INCLUDE = "all";
            IMMICH_HOST = "127.0.0.1";
          };
          volumes = [ "/mnt/bulk/immich:/usr/src/app/upload" ];
          extraOptions = [ "--network=host" ];
        };
        immich-ml = {
          image = "ghcr.io/immich-app/immich-machine-learning@sha256:513c831cfb010ad319341a0c86b42c575a0d5b688d3e8cae346ee624074a58ed";
          environment = {
            IMMICH_HOST = "127.0.0.1";
            TRANSFORMERS_CACHE = "/cache";
          };
          volumes = [ "/var/cache/immich-ml:/cache" ];
          extraOptions = [ "--network=host" ];
        };
      };
    };
    systemd = {
      services = {
        podman-immich = {
          requires = [
            "postgres-immich.service"
            "dragonflydb.service"
          ];
          after = [
            "postgres-immich.service"
            "dragonflydb.service"
          ];
          unitConfig.ConditionPathExists = cfg.environmentFile;
        };
        podman-immich-ml.unitConfig.ConditionPathExists = cfg.environmentFile;
      };
      tmpfiles.rules = [ "d /var/cache/immich-ml 0750 root root -" ];
    };
  };
}
