{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.lightweightApplications;
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
  owner =
    name:
    if name == "pocket-id" then
      "1000"
    else if name == "wallos" then
      "82"
    else
      "root";
  apps = {
    pocket-id = {
      image = "ghcr.io/pocket-id/pocket-id@sha256:323e7ef5bfacf7cf32f22f3d10ccdf48e0c97c94d67e7e40b0b996830deb5165";
      port = 1411;
      internalPort = 1411;
      hostname = "id.minastas.xyz";
      healthPath = "/healthz";
      volumes = [ "/var/lib/pocket-id:/app/data" ];
      environment = {
        APP_URL = "https://id.minastas.xyz";
        TRUST_PROXY = "true";
      };
    };
    homarr = {
      image = "ghcr.io/homarr-labs/homarr@sha256:f0fb462299af9749a72f11040fd3f604d1c4976b3d9a137ae5021b7f44d980f5";
      port = 7575;
      internalPort = 3000;
      hostname = "homarr.tailbc181.ts.net";
      healthPath = "/api/health/live";
      volumes = [ "/var/lib/homarr:/appdata" ];
      environment = {
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
    };
    donetick = {
      image = "docker.io/donetick/donetick@sha256:a1cc21dd5a37acb5009009f13e5d2529153049361afb0a1cd94bde312382d36a";
      port = 2021;
      internalPort = 2021;
      hostname = "donetick.tailbc181.ts.net";
      healthPath = "/";
      volumes = [
        "/var/lib/donetick:/donetick_data"
        "${cfg.donetickConfigFile}:/config/selfhosted.yaml:ro"
      ];
      environment = {
        DT_ENV = "selfhosted";
        DT_SQLITE_PATH = "/donetick_data/donetick.db";
      };
    };
    commafeed = {
      image = "docker.io/athou/commafeed@sha256:0e52f2a86c2ae36cb446401292c87ba6ca658fafda64c99bc7e8713ed433d8a3";
      port = 8085;
      internalPort = 8082;
      hostname = "feed.tailbc181.ts.net";
      healthPath = "/";
      volumes = [ "/var/lib/commafeed:/commafeed/data" ];
      environment = { };
    };
    mailrise = {
      image = "docker.io/yoryan/mailrise@sha256:0b8b1ce3447c83b625c9e8896cd9c3db0205590f92ce4d4adaae69729830f52b";
      port = 8025;
      internalPort = 8025;
      volumes = [ "${cfg.mailriseConfigFile}:/etc/mailrise.conf:ro" ];
      environment = { };
    };
    wallos = {
      image = "docker.io/bellamy/wallos@sha256:0f049dbab45b9f8e8d43b84fd1b77ef9e55909bd1a384a0f4fe8597ab68a1d5d";
      port = 8282;
      internalPort = 80;
      hostname = "wallos.tailbc181.ts.net";
      healthPath = "/";
      volumes = [
        "/var/lib/wallos/db:/var/www/html/db"
        "/var/lib/wallos/logos:/var/www/html/images/uploads/logos"
      ];
      environment = {
        WALLOS_SERVER_URL = "https://wallos.tailbc181.ts.net";
      };
    };
  };
  selectedApps = lib.getAttrs cfg.applications apps;
  runtimePath =
    default:
    lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.+";
      inherit default;
      description = "Runtime-only restored application environment/configuration; never a Nix store file.";
    };
  health =
    name: app:
    if name == "mailrise" then
      "${pkgs.netcat-openbsd}/bin/nc -z -w 10 127.0.0.1 8025"
    else
      "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:${toString app.port}${app.healthPath}";
in
{
  options.services.fleet.lightweightApplications = {
    enable = lib.mkEnableOption "source-pinned local lightweight applications";
    applications = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames apps));
      default = lib.attrNames apps;
      description = "Applications hosted here; temporary handoffs can select only the services being moved.";
    };
    environmentFiles = lib.genAttrs (lib.attrNames apps) (name: runtimePath "/run/secrets/${name}.env");
    donetickConfigFile = runtimePath "/run/secrets/donetick-selfhosted.yaml";
    mailriseConfigFile = runtimePath "/run/secrets/mailrise.conf";
  };
  config = lib.mkIf cfg.enable {
    # A custom DNS-enabled Podman network may use podman1 (or later), while
    # NixOS opens resolver access only on the default podman0 interface.
    networking.firewall.extraInputRules = ''
      iifname "podman*" udp dport 53 accept comment "Podman bridge DNS"
      iifname "podman*" tcp dport 53 accept comment "Podman bridge DNS"
    '';
    virtualisation.oci-containers = {
      backend = "podman";
      containers = lib.mapAttrs (
        name: app:
        {
          inherit (app) image volumes;
          environmentFiles = [ cfg.environmentFiles.${name} ];
          environment = {
            TZ = "America/Los_Angeles";
          }
          // app.environment;
          ports = [ "127.0.0.1:${toString app.port}:${toString app.internalPort}" ];
          extraOptions = [ "--network=fleet-lightweight" ];
        }
        // lib.optionalAttrs (name == "mailrise") {
          cmd = [
            "--very-verbose"
            "/etc/mailrise.conf"
          ];
        }
      ) selectedApps;
    };
    systemd.services =
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair "podman-${name}" {
          requires = [ "fleet-lightweight-network.service" ];
          after = [ "fleet-lightweight-network.service" ];
          unitConfig.ConditionPathExists = [
            cfg.environmentFiles.${name}
          ]
          ++ lib.optional (name == "donetick") cfg.donetickConfigFile
          ++ lib.optional (name == "mailrise") cfg.mailriseConfigFile;
        }
      ) selectedApps
      // {
        fleet-lightweight-network = {
          description = "DNS-enabled private bridge for lightweight applications";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.podman}/bin/podman network exists fleet-lightweight || \
              ${pkgs.podman}/bin/podman network create --driver bridge fleet-lightweight
          '';
        };
      };
    systemd.tmpfiles.rules =
      (map (name: "d /var/lib/${name} 0750 ${owner name} ${owner name} -") (
        lib.remove "mailrise" (lib.attrNames selectedApps)
      ))
      ++ lib.optionals (builtins.hasAttr "wallos" selectedApps) [
        "d /var/lib/wallos/db 0750 82 82 -"
        "d /var/lib/wallos/logos 0750 82 82 -"
      ];
    fleet = {
      telemetry.enable = true;
      ingress.routes = lib.mapAttrsToList (name: app: {
        inherit (app) hostname;
        upstream = "http://127.0.0.1:${toString app.port}";
        exposure = if name == "pocket-id" then "public" else "tailnet";
      }) (lib.filterAttrs (name: _: name != "mailrise") selectedApps);
      backup.jobs = lib.mapAttrs' (
        name: app:
        lib.nameValuePair "${name}-state" (
          (backups.state {
            inherit name;
            path = "/var/lib/${name}";
            owner = owner name;
            group = owner name;
            healthCheckCommand = health name app;
          })
          // {
            frequency = "hourly";
            backupClass = "database";
          }
        )
      ) (lib.filterAttrs (name: _: name != "mailrise") selectedApps);
    };
  };
}
