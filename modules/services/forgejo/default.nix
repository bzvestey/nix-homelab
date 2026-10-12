{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.forgejo;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
  dbBackups = import ../remaining-backups.nix { inherit pkgs lib; };
  health = "${pkgs.curl}/bin/curl --fail --max-time 10 http://127.0.0.1:3000/api/healthz";
in
{
  imports = [ ../../fleet/local-postgres.nix ];
  options.services.fleet.forgejo.enable = lib.mkEnableOption "Forgejo with local PG18";
  config = lib.mkIf cfg.enable {
    fleet = {
      localPostgres.forgejo = {
        package = pkgs.postgresql_18;
        port = 5434;
        environmentFile = "/run/secrets/forgejo.env";
        initializeSQL = ''
          SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
          \getenv password POSTGRES_PASSWORD
          ALTER ROLE app PASSWORD :'password';
          SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
        '';
      };
      backup.jobs = {
        forgejo-db = dbBackups.database "forgejo" 5434 health;
        forgejo-state = backups.state {
          name = "forgejo";
          path = "/var/lib/forgejo";
          owner = "1000";
          group = "1000";
          healthCheckCommand = health;
        };
      };
      ingress.routes = [
        {
          hostname = "git.tailbc181.ts.net";
          upstream = "http://127.0.0.1:3000";
          exposure = "tailnet";
        }
      ];
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.forgejo = {
        image = "codeberg.org/forgejo/forgejo@sha256:5effb7305584aca479b29fde6f9631a6dbe86ae798ae02eeea33a3666f0c0bf8";
        environmentFiles = [ "/run/secrets/forgejo.env" ];
        environment = {
          USER_UID = "1000";
          USER_GID = "1000";
          FORGEJO__server__HTTP_ADDR = "127.0.0.1";
          FORGEJO__server__HTTP_PORT = "3000";
          FORGEJO__server__ROOT_URL = "https://git.tailbc181.ts.net/";
          FORGEJO__server__DOMAIN = "git.tailbc181.ts.net";
          FORGEJO__server__PROTOCOL = "http";
          FORGEJO__server__SSH_DOMAIN = "git-ssh.tailbc181.ts.net";
          FORGEJO__server__SSH_PORT = "22";
          FORGEJO__server__SSH_LISTEN_HOST = "127.0.0.1";
          FORGEJO__server__SSH_LISTEN_PORT = "2222";
          FORGEJO__server__START_SSH_SERVER = "true";
          FORGEJO__database__DB_TYPE = "postgres";
          FORGEJO__database__HOST = "127.0.0.1:5434";
          FORGEJO__database__NAME = "app";
          FORGEJO__database__USER = "app";
          FORGEJO__storage__STORAGE_TYPE = "minio";
          FORGEJO__storage__MINIO_ENDPOINT = "10.15.4.101:30188";
          FORGEJO__storage__MINIO_BUCKET = "forgejo";
          FORGEJO__storage__MINIO_BUCKET_LOOKUP = "path";
          FORGEJO__storage__MINIO_LOCATION = "garage";
          FORGEJO__storage__MINIO_USE_SSL = "false";
          FORGEJO__storage__MINIO_CHECKSUM_ALGORITHM = "default";
          FORGEJO__server__LFS_START_SERVER = "true";
          FORGEJO__server__OFFLINE_MODE = "true";
          FORGEJO__security__INSTALL_LOCK = "true";
          FORGEJO__security__REVERSE_PROXY_LIMIT = "1";
          FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES = "127.0.0.1";
          FORGEJO__service__DISABLE_REGISTRATION = "true";
          FORGEJO__service__ENABLE_INTERNAL_SIGNIN = "false";
          FORGEJO__service__ENABLE_BASIC_AUTHENTICATION = "false";
          FORGEJO__actions__ENABLED = "true";
          FORGEJO__actions__DEFAULT_ACTIONS_URL = "https://data.forgejo.org";
          FORGEJO__migrations__ALLOWED_DOMAINS = "git.tailbc181.ts.net";
          FORGEJO__mailer__ENABLED = "true";
          FORGEJO__mailer__FROM = "forgejo@minastas.ninja";
          FORGEJO__mailer__PROTOCOL = "smtp";
          FORGEJO__mailer__SMTP_PORT = "25";
        };
        volumes = [
          "/var/lib/forgejo/data:/var/lib/gitea"
          "/var/lib/forgejo/config:/etc/gitea"
        ];
        extraOptions = [ "--network=host" ];
      };
    };
    systemd.services.podman-forgejo = {
      unitConfig.ConditionPathExists = [
        "/run/secrets/forgejo.env"
        "/var/lib/forgejo/.restored"
      ];
      serviceConfig.Environment = [ ];
      preStart = ''
        ${pkgs.findutils}/bin/find /var/lib/forgejo -type f \( -name 'ssh_host_*' -o -name 'ssh_host_key' \) ! -name '*.pub' -exec ${pkgs.coreutils}/bin/chmod 0600 {} +
      '';
      requires = [ "postgres-forgejo.service" ];
      after = [ "postgres-forgejo.service" ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/forgejo 0700 root root -" ];
  };
}
