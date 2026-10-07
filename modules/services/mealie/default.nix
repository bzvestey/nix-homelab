{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.mealie;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
  health = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:9000/api/app/about";
  sql = pkgs.writeText "mealie-role.sql" ''
    \getenv password POSTGRES_PASSWORD
    ALTER ROLE app PASSWORD :'password';
    \connect app
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
  '';
in
{
  options.services.fleet.mealie = {
    enable = lib.mkEnableOption "pinned Mealie with local PG17";
    environmentFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.*";
      default = "/run/secrets/mealie.env";
      description = "Runtime POSTGRES_PASSWORD and OIDC_CLIENT_SECRET environment file.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      settings.listen_addresses = lib.mkForce "127.0.0.1";
      ensureDatabases = [ "app" ];
      ensureUsers = [
        {
          name = "app";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkForce ''
        local all all peer
        host app app 127.0.0.1/32 scram-sha-256
      '';
    };
    systemd = {
      services = {
        postgresql.unitConfig.ConditionPathExists = cfg.environmentFile;
        postgresql-setup = {
          unitConfig.ConditionPathExists = cfg.environmentFile;
          serviceConfig.EnvironmentFile = cfg.environmentFile;
          postStart = lib.mkAfter ''
            ${pkgs.postgresql_17}/bin/psql -v ON_ERROR_STOP=1 -d postgres -f ${sql}
          '';
        };
        podman-mealie = {
          requires = [ "postgresql.target" ];
          after = [ "postgresql.target" ];
          unitConfig.ConditionPathExists = cfg.environmentFile;
        };
      };
      tmpfiles.rules = [ "d /var/lib/mealie 0750 mealie mealie -" ];
    };
    users = {
      groups.mealie.gid = 1000;
      users.mealie = {
        uid = 1000;
        group = "mealie";
        isSystemUser = true;
      };
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.mealie = {
        image = "ghcr.io/mealie-recipes/mealie@sha256:8b02290f4d1806f02acac6f25f6d48a3c965612fda1f8e914d5af533276f8688";
        environmentFiles = [ cfg.environmentFile ];
        environment = {
          HOST = "127.0.0.1";
          TZ = "America/Los_Angeles";
          PUID = "1000";
          PGID = "1000";
          ALLOW_SIGNUP = "true";
          ALLOW_PASSWORD_LOGIN = "false";
          BASE_URL = "https://mealie.tailbc181.ts.net";
          OIDC_AUTH_ENABLED = "true";
          OIDC_SIGNUP_ENABLED = "true";
          OIDC_CONFIGURATION_URL = "https://id.minastas.xyz/.well-known/openid-configuration";
          OIDC_CLIENT_ID = "9bff51ba-d97c-4838-9bae-ac3d3ff2ae8c";
          OIDC_USER_GROUP = "core_users";
          OIDC_ADMIN_GROUP = "admin";
          OIDC_AUTH_REDIRECT = "true";
          OIDC_PROVIDER_NAME = "PocketID";
          OIDC_REMEMBER_ME = "true";
          DB_ENGINE = "postgres";
          POSTGRES_USER = "app";
          POSTGRES_SERVER = "127.0.0.1";
          POSTGRES_PORT = "5432";
          POSTGRES_DB = "app";
        };
        volumes = [ "/var/lib/mealie:/app/data" ];
        extraOptions = [ "--network=host" ];
      };
    };
    fleet = {
      backup.jobs = {
        mealie-db = backups.database {
          name = "mealie";
          package = pkgs.postgresql_17;
          user = "postgres";
          socket = "/run/postgresql";
          port = 5432;
          dataPath = config.services.postgresql.dataDir;
          healthCheckCommand = health;
        };
        mealie-state = backups.state {
          name = "mealie";
          path = "/var/lib/mealie";
          owner = "mealie";
          group = "mealie";
          healthCheckCommand = health;
        };
      };
      ingress.routes = [
        {
          hostname = "mealie.tailbc181.ts.net";
          upstream = "http://127.0.0.1:9000";
          exposure = "tailnet";
        }
      ];
    };
  };
}
