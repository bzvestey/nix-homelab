{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.tuwunel;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  options.services.fleet.tuwunel = {
    enable = lib.mkEnableOption "pinned Tuwunel with local RocksDB";
    configFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.*";
      default = "/run/secrets/tuwunel.toml";
      description = "Runtime complete TOML retaining Pocket ID settings; no retired Hookshot appservice.";
    };
  };
  config = lib.mkIf cfg.enable {
    systemd = {
      tmpfiles.rules = [ "d /var/lib/tuwunel 0750 root root -" ];
      services.podman-tuwunel.unitConfig.ConditionPathExists = cfg.configFile;
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.tuwunel = {
        image = "docker.io/jevolk/tuwunel@sha256:0e86c6164d6c9f5b60291938eb61ad8395021c37fe58d47a963ea7edddbedaec";
        environment = {
          TUWUNEL_CONFIG = "/etc/tuwunel.toml";
          TUWUNEL_PORT = "8008";
        };
        volumes = [
          "/var/lib/tuwunel:/var/lib/tuwunel"
          "${cfg.configFile}:/etc/tuwunel.toml:ro"
        ];
        ports = [ "127.0.0.1:8008:8008" ];
      };
    };
    fleet = {
      backup.jobs.tuwunel-state =
        (backups.state {
          name = "tuwunel";
          path = "/var/lib/tuwunel";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8008/_matrix/client/versions";
        })
        // {
          # RocksDB needs database RPO/alerts despite its directory-copy capture.
          frequency = "hourly";
          backupClass = "database";
        };
      ingress.routes = [
        {
          hostname = "matrix.minastas.social";
          upstream = "http://127.0.0.1:8008";
          exposure = "public";
        }
      ];
    };
  };
}
