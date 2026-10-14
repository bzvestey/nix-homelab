{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.homarr;
  group = config.services.fleet.lightweightApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.homarr.enable = lib.mkEnableOption "Homarr";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.homarr = {
        image = "ghcr.io/homarr-labs/homarr@sha256:f0fb462299af9749a72f11040fd3f604d1c4976b3d9a137ae5021b7f44d980f5";
        environmentFiles = [ group.environmentFiles.homarr ];
        environment = {
          TZ = "America/Los_Angeles";
          ENABLE_DOCKER = "false";
          ENABLE_KUBERNETES = "false";
          AUTH_LOGOUT_REDIRECT_URL = "https://id.minastas.xyz/api/oidc/end-session";
          AUTH_OIDC_AUTO_LOGIN = "true";
          AUTH_OIDC_CLIENT_NAME = "Pocket-Id";
          AUTH_OIDC_GROUPS_ATTRIBUTE = "groups";
          AUTH_OIDC_ISSUER = "https://id.minastas.xyz";
          AUTH_OIDC_SCOPE_OVERWRITE = "openid email profile groups";
          AUTH_PROVIDERS = "oidc";
          AUTH_SESSION_EXPIRY_TIME = "30d";
          DB_MIGRATIONS_DISABLED = "false";
          DB_DRIVER = "better-sqlite3";
          DB_DIALECT = "sqlite";
          DB_URL = "/appdata/db.sqlite";
        };
        volumes = [ "/var/lib/homarr:/appdata" ];
        ports = [ "127.0.0.1:7575:3000" ];
        extraOptions = [ "--network=fleet-lightweight" ];
      };
    };
    systemd.services.podman-homarr = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [ group.environmentFiles.homarr ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/homarr 0750 root root -" ];
    fleet.ingress.routes = [
      {
        hostname = "homarr.tailbc181.ts.net";
        upstream = "http://127.0.0.1:7575";
        exposure = "tailnet";
      }
    ];
    fleet.backup.jobs.homarr-state =
      (backups.state {
        name = "homarr";
        path = "/var/lib/homarr";
        sqliteDatabases = [ "db.sqlite" ];
        exclude = [ "/db/" ];
        owner = "root";
        group = "root";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:7575/api/health/live";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
      };
  };
}
