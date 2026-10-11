{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.mediaAutomation;
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
  apps = {
    deluge = {
      image = "docker.io/linuxserver/deluge@sha256:9505c64720afa9e5f0ac1576e660dd6d1e9d4a6733b791f4821e8f496f19f41f";
      port = 8112;
    };
    prowlarr = {
      image = "ghcr.io/linuxserver/prowlarr@sha256:f2b26429893d4c4cb71941b7ee50b1bdecd9d5f9f9e02d5410615e9f4f7c8d95";
      port = 9696;
    };
    radarr = {
      image = "ghcr.io/linuxserver/radarr@sha256:adb6c09d6b729ea5e642c99cea35af72702ef476bf4763f153299ac5db9f0b4f";
      port = 7878;
    };
    sonarr = {
      image = "ghcr.io/linuxserver/sonarr@sha256:f247545d23ba8b233d6604575347e48a623fe6ad75dda02348bf81917f3b5c06";
      port = 8989;
    };
    whisparr = {
      image = "ghcr.io/hotio/whisparr@sha256:c60aabe2ab85417e8f23dfc56285a33be413c5336ebe47b8f26eca9e7145540c";
      port = 6969;
    };
    sabnzbd = {
      image = "ghcr.io/linuxserver/sabnzbd@sha256:4f7ee6c53834bc336365bd0a7c35f4fc870156a72d33a334753010258aa077a4";
      port = 8180;
    };
    publication-manager = {
      image = "git.tailbc181.ts.net/publication-feed-handler/lcp-decryption-plugin@sha256:861c73bacbe2c632e3f467fb78130bcbbc6fb8e053fb01a816632c347cdf0ad6";
      port = 8090;
    };
  };
  names = lib.attrNames apps;
  videoApps = [
    "deluge"
    "radarr"
    "sonarr"
    "whisparr"
    "sabnzbd"
  ];
  statePath = name: "/var/lib/media-automation/${name}";
  envFile = name: "/run/secrets/${name}.env";
  health =
    name:
    "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:${toString apps.${name}.port}/${
      lib.optionalString (name == "publication-manager") "readyz"
    }";
in
{
  options.services.fleet.mediaAutomation.enable =
    lib.mkEnableOption "source-pinned media automation with fail-closed Deluge VPN";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers =
        lib.mapAttrs (
          name: app:
          {
            inherit (app) image;
            environmentFiles = [ (envFile name) ];
            environment =
              if name == "publication-manager" then
                {
                  PM_LOG_LEVEL = "info";
                  PM_SERVER_CONFIG = "/etc/pm/server.toml";
                  PM_SECRET_KEY_FILE = "/etc/pm/master-key";
                }
              else
                {
                  PUID = "1000";
                  PGID = "1000";
                  TZ = "America/Los_Angeles";
                }
                // lib.optionalAttrs (name == "deluge") { DELUGE_LOGLEVEL = "error"; };
            volumes = [
              "${statePath name}:${if name == "publication-manager" then "/data" else "/config"}"
            ]
            ++ lib.optional (lib.elem name videoApps) "/mnt/bulk/videos:/videos"
            ++ lib.optional (name == "deluge") "/mnt/bulk/deluge-downloads:/downloads"
            ++ lib.optionals (name == "publication-manager") [
              "/mnt/bulk/publications:/storage"
              "/run/secrets/publication-manager/server.toml:/etc/pm/server.toml:ro"
              "/run/secrets/publication-manager/master-key:/etc/pm/master-key:ro"
            ];
            ports =
              lib.optional (name != "deluge")
                "127.0.0.1:${toString app.port}:${
                  toString (
                    if
                      lib.elem name [
                        "sabnzbd"
                        "publication-manager"
                      ]
                    then
                      8080
                    else
                      app.port
                  )
                }";
            extraOptions =
              lib.optionals (name == "deluge") [ "--network=container:gluetun" ]
              ++ lib.optionals (name == "publication-manager") [
                "--user=1000:1000"
                "--tmpfs=/tmp:rw,mode=1777"
                "--authfile=/run/secrets/publication-manager-registry.json"
              ];
            dependsOn = lib.optional (name == "deluge") "gluetun";
          }
          // lib.optionalAttrs (name == "publication-manager") {
            cmd = [
              "serve"
              "--pipelines-dir=/data/pipelines"
              "--server-db=/data/server.db"
              "--runs-dir=/data/runs"
              "--plugin-dir=/plugins"
              "--listen=0.0.0.0:8080"
            ];
          }
        ) apps
        // {
          gluetun = {
            image = "docker.io/qmcgaw/gluetun@sha256:1a5bf4b4820a879cdf8d93d7ef0d2d963af56670c9ebff8981860b6804ebc8ab";
            environmentFiles = [ (envFile "gluetun") ];
            environment = {
              VPN_SERVICE_PROVIDER = "protonvpn";
              VPN_TYPE = "wireguard";
              SERVER_COUNTRIES = "Switzerland,Netherlands,Norway,Turkey,Iceland,Czech Republic";
              PORT_FORWARD_ONLY = "on";
              VPN_PORT_FORWARDING = "on";
              UPDATER_PERIOD = "24h";
              FIREWALL = "on";
              FIREWALL_INPUT_PORTS = "8112,58846";
            };
            ports = [
              "127.0.0.1:8112:8112"
              "127.0.0.1:58846:58846"
            ];
            volumes = [ "/run/media-automation/gluetun:/tmp/gluetun" ];
            extraOptions = [
              "--cap-add=NET_ADMIN"
              "--device=/dev/net/tun:/dev/net/tun"
            ];
          };
          deluge-port-manager = {
            image = "docker.io/plaexmstr/gluetun-deluge-port-manager@sha256:add2cdcd60d98dc96326fa61a58d331d77266610e73768ad0e0cfe499248a25c";
            environmentFiles = [ (envFile "deluge-port-manager") ];
            environment = {
              DELUGE_SERVER = "localhost";
              DELUGE_PORT = "8112";
              PORT_FORWARDED = "/tmp/gluetun/forwarded_port";
            };
            volumes = [ "/run/media-automation/gluetun:/tmp/gluetun:ro" ];
            extraOptions = [ "--network=container:gluetun" ];
            dependsOn = [
              "gluetun"
              "deluge"
            ];
          };
        };
    };
    systemd.tmpfiles.rules = map (name: "d ${statePath name} 0700 1000 1000 -") names ++ [
      "d /run/media-automation/gluetun 0700 root root -"
    ];
    systemd.services = lib.mkMerge [
      (lib.genAttrs
        (map (name: "podman-${name}") (
          names
          ++ [
            "gluetun"
            "deluge-port-manager"
          ]
        ))
        (unit: {
          unitConfig.ConditionPathIsReadable = envFile (lib.removePrefix "podman-" unit);
        })
      )
      {
        podman-deluge = {
          bindsTo = [ "podman-gluetun.service" ];
          after = [ "podman-gluetun.service" ];
          partOf = [ "podman-gluetun.service" ];
        };
        podman-deluge-port-manager = {
          bindsTo = [
            "podman-gluetun.service"
            "podman-deluge.service"
          ];
          after = [
            "podman-gluetun.service"
            "podman-deluge.service"
          ];
          partOf = [
            "podman-gluetun.service"
            "podman-deluge.service"
          ];
        };
        podman-publication-manager.unitConfig.ConditionPathIsReadable = lib.mkForce [
          (envFile "publication-manager")
          "/run/secrets/publication-manager/server.toml"
          "/run/secrets/publication-manager/master-key"
          "/run/secrets/publication-manager-registry.json"
        ];
      }
    ];
    fleet = {
      storage.nfsMounts = {
        videos = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
          target = "/mnt/bulk/videos";
          dependentUnits = map (name: "podman-${name}") videoApps;
        };
        deluge-downloads = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/deluge/downloads";
          target = "/mnt/bulk/deluge-downloads";
          dependentUnits = [ "podman-deluge" ];
        };
        publications = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/Computer";
          target = "/mnt/bulk/publications";
          dependentUnits = [ "podman-publication-manager" ];
        };
      };
      ingress.routes = map (name: {
        hostname = "${if name == "publication-manager" then "publications" else name}.tailbc181.ts.net";
        upstream = "http://127.0.0.1:${toString apps.${name}.port}";
        exposure = "tailnet";
      }) names;
      backup.jobs = lib.listToAttrs (
        map (
          name:
          lib.nameValuePair "${name}-state" (
            backups.state {
              inherit name;
              path = statePath name;
              owner = "1000";
              group = "1000";
              healthCheckCommand = health name;
            }
            // {
              frequency = "hourly";
              backupClass = "database";
              mode = "0600";
              directoryMode = "0700";
            }
            // lib.optionalAttrs (name == "deluge") {
              serviceUnits = [
                "podman-deluge.service"
                "podman-deluge-port-manager.service"
              ];
              # Stop the forwarding writer first; restart only units previously active.
              createCommand = ''
                deluge_active=0; sidecar_active=0
                if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-deluge; then deluge_active=1; fi
                if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-deluge-port-manager; then sidecar_active=1; fi
                trap 'if [ "$deluge_active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-deluge; fi; if [ "$sidecar_active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-deluge-port-manager; fi' EXIT
                ${pkgs.systemd}/bin/systemctl stop podman-deluge-port-manager podman-deluge
                ${pkgs.coreutils}/bin/cp -a ${statePath name} "$FLEET_BACKUP_STAGING_DIR/state"
              '';
            }
          )
        ) names
      );
    };
  };
}
