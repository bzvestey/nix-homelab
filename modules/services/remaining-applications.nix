{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.remainingApplications;
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
  names = [
    "forgejo"
    "foundry"
    "tangled-knot"
    "tranquil-pds"
  ];
  env = name: "/run/secrets/${name}.env";
  state = name: "/var/lib/${name}";
  health =
    name:
    "${pkgs.curl}/bin/curl --fail --max-time 10 http://127.0.0.1:${
      toString
        {
          forgejo = 3000;
          foundry = 30000;
          tangled-knot = 5555;
          tranquil-pds = 8000;
        }
        .${name}
    }${
      if name == "forgejo" then
        "/api/healthz"
      else if name == "foundry" then
        "/"
      else
        "/xrpc/_health"
    }";
  database = name: port: {
    package = pkgs.postgresql_18;
    inherit port;
    environmentFile = env name;
    initializeSQL = ''
      SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
      \getenv password POSTGRES_PASSWORD
      ALTER ROLE app PASSWORD :'password';
      SELECT 'CREATE DATABASE app OWNER app TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
    '';
  };
  dbBackup =
    name: port:
    let
      job = backups.database {
        inherit name port;
        package = pkgs.postgresql_18;
        user = "postgres-${name}";
        socket = "/run/postgres-${name}";
        dataPath = "/var/lib/postgres-${name}";
        healthCheckCommand = health name;
      };
    in
    job
    // {
      # The source Forgejo database/owner are forgejo; the shared helper and
      # localPostgres HBA intentionally use app. Remap ownership at restore.
      restoreCommand =
        lib.replaceStrings
          [ "--exit-on-error -d app" ]
          [ "--exit-on-error --no-owner --no-acl --role=app -d app" ]
          job.restoreCommand;
    };
  route = hostname: port: exposure: {
    inherit hostname exposure;
    upstream = "http://127.0.0.1:${toString port}";
  };
in
{
  imports = [ ../fleet/local-postgres.nix ];
  options.services.fleet.remainingApplications = {
    enable = lib.mkEnableOption "restored node-02 prerequisites (never enabled automatically)";
    registryAuthFile = lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/remaining-applications-registry.json";
      description = "Runtime Podman auth JSON for ghcr.io and atcr.io; never copied into the store.";
    };
  };
  config = lib.mkIf cfg.enable {
    fleet = {
      localPostgres = {
        forgejo = database "forgejo" 5434;
        tranquil-pds = database "tranquil-pds" 5435;
      };
      backup.jobs =
        lib.listToAttrs (
          map (
            name:
            lib.nameValuePair "${name}-state" (
              backups.state {
                inherit name;
                path = state name;
                owner = if name == "tranquil-pds" then "65532" else "1000";
                group = if name == "tranquil-pds" then "65532" else "1000";
                healthCheckCommand = health name;
              }
              //
                lib.optionalAttrs
                  (builtins.elem name [
                    "foundry"
                    "tangled-knot"
                  ])
                  {
                    frequency = "hourly";
                    backupClass = "database";
                  }
              // lib.optionalAttrs (name == "foundry") {
                # Installed modules contain spaces and relative symlinks. Keep
                # the full 4.5 GB installation inside one bounded tar payload.
                maxPayloadBytes = 16 * 1024 * 1024 * 1024;
                requiredPaths = [ "state.tar" ];
                createCommand = ''
                  active=0
                  if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-foundry.service; then active=1; fi
                  ${pkgs.systemd}/bin/systemctl stop podman-foundry.service
                  trap 'if [ "$active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-foundry.service; fi' EXIT
                  ${pkgs.gnutar}/bin/tar -C /var/lib/foundry -cpf "$FLEET_BACKUP_STAGING_DIR/state.tar" .
                '';
                restoreCommand = ''
                  ${pkgs.coreutils}/bin/mkdir -p /var/lib/foundry
                  ${pkgs.findutils}/bin/find /var/lib/foundry -mindepth 1 -maxdepth 1 -exec ${pkgs.coreutils}/bin/rm -rf -- {} +
                  ${pkgs.gnutar}/bin/tar -C /var/lib/foundry -xpf "$FLEET_RESTORE_SOURCE_DIR/state.tar"
                '';
                rehearsalCommand = ''
                  ${pkgs.gnutar}/bin/tar -tf "$FLEET_RESTORE_SOURCE_DIR/state.tar" >/dev/null
                '';
              }
            )
          ) names
        )
        // {
          forgejo-db = dbBackup "forgejo" 5434;
          tranquil-pds-db = dbBackup "tranquil-pds" 5435;
        };
      ingress.routes = [
        (route "git.tailbc181.ts.net" 3000 "tailnet")
        (route "foundry.minastas.xyz" 30000 "public")
        (route "knot.minastas.xyz" 5555 "public")
        (route "minastas.social" 8000 "public")
        (route "pds.minastas.social" 8000 "public")
        (route "*.minastas.social" 8000 "public")
      ];
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers = {
        forgejo = {
          image = "codeberg.org/forgejo/forgejo@sha256:5effb7305584aca479b29fde6f9631a6dbe86ae798ae02eeea33a3666f0c0bf8";
          environmentFiles = [ (env "forgejo") ];
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
        foundry = {
          image = "ghcr.io/bzvestey/foundry@sha256:5d59c2eabaa4a495171cfa5ca73148aaf76056bd2052e84d978935f80ea32709";
          environmentFiles = [ (env "foundry") ];
          ports = [ "127.0.0.1:30000:30000" ];
          volumes = [
            "/var/lib/foundry/app:/home/foundry/app"
            "/var/lib/foundry/data:/home/foundry/data"
          ];
        };
        tangled-knot = {
          image = "atcr.io/tangled.org/knot@sha256:6a9246da7b49a8bbe6f84122fd6fc09aac3ae93589b193956873daf33f88faa6";
          cmd = [ "/etc/knot/config.toml" ];
          environmentFiles = [ (env "tangled-knot") ];
          environment = {
            KNOT_SCAN_PATH = "/data/repos";
            KNOT_SEALED_KEY_FILE = "/data/sealed-keys";
            KNOT_SSH_HOST_KEY_FILE = "/data/ssh_host_key";
            KNOT_MASTER_KEY_ENV = "KNOT_MASTER_KEY";
          };
          volumes = [
            "/var/lib/tangled-knot/data:/data"
            "/var/lib/tangled-knot/config.toml:/etc/knot/config.toml:ro"
          ];
          ports = [
            "127.0.0.1:5555:5555"
            "127.0.0.1:2223:2222"
          ];
          user = "1000:1000";
        };
        tranquil-pds = {
          image = "atcr.io/tranquil.farm/tranquil-pds@sha256:bfbcb3b574bd836e9719012c98b172a8ebea2046acb6a87cb989eeb4f4dba9a4";
          environmentFiles = [ (env "tranquil-pds") ];
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
    };
    systemd.services = lib.listToAttrs (
      map (
        name:
        lib.nameValuePair "podman-${name}" {
          unitConfig.ConditionPathExists = [
            (env name)
            "${state name}/.restored"
          ]
          ++ lib.optional (name != "forgejo") cfg.registryAuthFile;
          serviceConfig.Environment = lib.optional (
            name != "forgejo"
          ) "REGISTRY_AUTH_FILE=${cfg.registryAuthFile}";
          preStart =
            lib.optionalString
              (builtins.elem name [
                "forgejo"
                "tangled-knot"
              ])
              ''
                ${pkgs.findutils}/bin/find ${state name} -type f \( -name 'ssh_host_*' -o -name 'ssh_host_key' \) ! -name '*.pub' -exec ${pkgs.coreutils}/bin/chmod 0600 {} +
              '';
          requires = lib.optional (builtins.elem name [
            "forgejo"
            "tranquil-pds"
          ]) "postgres-${name}.service";
          after = lib.optional (builtins.elem name [
            "forgejo"
            "tranquil-pds"
          ]) "postgres-${name}.service";
        }
      ) names
    );
    systemd.tmpfiles.rules = map (name: "d ${state name} 0700 root root -") names;
  };
}
