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
  options.services.fleet.radarr.enable = lib.mkEnableOption "Radarr";
  config = lib.mkIf config.services.fleet.radarr.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.radarr = {
        image = "ghcr.io/linuxserver/radarr@sha256:adb6c09d6b729ea5e642c99cea35af72702ef476bf4763f153299ac5db9f0b4f";
        environmentFiles = [ "/run/secrets/radarr.env" ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
        };
        volumes = [
          "/var/lib/media-automation/radarr:/config"
          "/mnt/bulk/videos:/videos"
        ];
        ports = [ "127.0.0.1:7878:7878" ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/radarr 0700 1000 1000 -" ];
    systemd.services.podman-radarr.unitConfig.ConditionPathIsReadable = "/run/secrets/radarr.env";
    fleet = {
      storage.nfsMounts.videos = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
        dependentUnits = [ "podman-radarr" ];
      };
      ingress.routes = [
        {
          hostname = "radarr.tailbc181.ts.net";
          upstream = "http://127.0.0.1:7878";
          exposure = "tailnet";
        }
      ];
      backup.jobs.radarr-state =
        (backups.state {
          name = "radarr";
          path = "/var/lib/media-automation/radarr";
          sqliteDatabases = [
            "radarr.db"
            "logs.db"
          ];
          exclude = [
            "/Backups/"
            "/logs/"
          ];
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:7878/";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
        };
    };
  };
}
