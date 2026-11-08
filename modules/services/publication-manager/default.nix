{
  config,
  lib,
  pkgs,
  ...
}:
let
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  options.services.fleet.publication-manager.enable = lib.mkEnableOption "publication-manager";
  config = lib.mkIf config.services.fleet.publication-manager.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.publication-manager = {
        # LCP v0.3.2, based on publication-manager v0.19.3.
        image = "git.tailbc181.ts.net/publication-feed-handler/lcp-decryption-plugin@sha256:9437c66df809501c6b7b702be033b0b3430366f14f88a8c9d8c336044d4cae2d";
        environmentFiles = [ "/run/secrets/publication-manager.env" ];
        environment = {
          PM_LOG_LEVEL = "info";
          PM_SERVER_CONFIG = "/etc/pm/server.toml";
          PM_SECRET_KEY_FILE = "/etc/pm/master-key";
        };
        volumes = [
          "/var/lib/media-automation/publication-manager:/data"
          "/mnt/bulk/publications:/storage"
          "/run/secrets/publication-manager/server.toml:/etc/pm/server.toml:ro"
          "/run/secrets/publication-manager/master-key:/etc/pm/master-key:ro"
        ];
        ports = [ "127.0.0.1:8090:8080" ];
        extraOptions = [
          "--user=1000:1000"
          "--tmpfs=/tmp:rw,mode=1777"
          "--authfile=/run/secrets/publication-manager-registry.json"
        ];
        cmd = [
          "serve"
          "--pipelines-dir=/data/pipelines"
          "--server-db=/data/server.db"
          "--runs-dir=/data/runs"
          "--plugin-dir=/plugins"
          "--listen=0.0.0.0:8080"
        ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/publication-manager 0700 1000 1000 -" ];
    systemd.services.podman-publication-manager.unitConfig.ConditionPathIsReadable = lib.mkForce [
      "/run/secrets/publication-manager.env"
      "/run/secrets/publication-manager/server.toml"
      "/run/secrets/publication-manager/master-key"
      "/run/secrets/publication-manager-registry.json"
    ];
    fleet = {
      storage.nfsMounts.publications = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/Computer";
        target = "/mnt/bulk/publications";
        dependentUnits = [ "podman-publication-manager" ];
      };
      ingress.routes = [
        {
          hostname = "publications.tailbc181.ts.net";
          upstream = "http://127.0.0.1:8090";
          exposure = "tailnet";
        }
      ];
      backup.jobs.publication-manager-state =
        (backups.state {
          name = "publication-manager";
          path = "/var/lib/media-automation/publication-manager";
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8090/readyz";
        })
        // {
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
        };
    };
  };
}
