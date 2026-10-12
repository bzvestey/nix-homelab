{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.tranquil-pds;
  auth = config.services.fleet.remainingApplications.registryAuthFile;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
  dbBackups = import ../remaining-backups.nix { inherit pkgs lib; };
  health = "${pkgs.curl}/bin/curl --fail --max-time 10 http://127.0.0.1:8000/xrpc/_health";
in
{
  imports = [
    ../../fleet/local-postgres.nix
    ../remaining-options.nix
  ];
  options.services.fleet.tranquil-pds.enable = lib.mkEnableOption "Tranquil PDS with local PG18";
  config = lib.mkIf cfg.enable {
    fleet = {
      localPostgres.tranquil-pds = {
        package = pkgs.postgresql_18;
        port = 5435;
        environmentFile = "/run/secrets/tranquil-pds.env";
        initializeSQL = ''
          SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
          \getenv password POSTGRES_PASSWORD
          ALTER ROLE app PASSWORD :'password';
          SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
        '';
      };
      backup.jobs = {
        tranquil-pds-db = dbBackups.database "tranquil-pds" 5435 health;
        tranquil-pds-state = backups.state {
          name = "tranquil-pds";
          path = "/var/lib/tranquil-pds";
          owner = "65532";
          group = "65532";
          healthCheckCommand = health;
        };
      };
      ingress.routes =
        map
          (hostname: {
            inherit hostname;
            upstream = "http://127.0.0.1:8000";
            exposure = "public";
          })
          [
            "minastas.social"
            "pds.minastas.social"
            "*.minastas.social"
          ];
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.tranquil-pds = {
        image = "atcr.io/tranquil.farm/tranquil-pds@sha256:bfbcb3b574bd836e9719012c98b172a8ebea2046acb6a87cb989eeb4f4dba9a4";
        environmentFiles = [ "/run/secrets/tranquil-pds.env" ];
        environment = {
          PDS_HOSTNAME = "minastas.social";
          SERVER_HOST = "127.0.0.1";
          SERVER_PORT = "8000";
          INVITE_CODE_REQUIRED = "true";
          SSO_OIDC_ENABLED = "true";
          SSO_OIDC_ISSUER = "https://id.minastas.xyz";
          SSO_OIDC_DISPLAY_NAME = "Pocket ID";
          ENABLE_CADDY_ON_DEMAND_TLS = "false";
          MAIL_FROM_ADDRESS = "tranquil-pds@minastas.social";
          MAIL_SMARTHOST_PORT = "25";
          MAIL_SMARTHOST_TLS = "none";
        };
        volumes = [ "/var/lib/tranquil-pds/blobs:/var/lib/tranquil-pds/blobs" ];
        extraOptions = [ "--network=host" ];
        user = "65532:65532";
      };
    };
    systemd.services.podman-tranquil-pds = {
      unitConfig.ConditionPathExists = [
        "/run/secrets/tranquil-pds.env"
        "/var/lib/tranquil-pds/.restored"
        auth
      ];
      serviceConfig.Environment = [ "REGISTRY_AUTH_FILE=${auth}" ];
      requires = [ "postgres-tranquil-pds.service" ];
      after = [ "postgres-tranquil-pds.service" ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/tranquil-pds 0700 root root -" ];
  };
}
