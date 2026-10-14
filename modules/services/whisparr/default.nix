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
  options.services.fleet.whisparr.enable = lib.mkEnableOption "Whisparr";
  config = lib.mkIf config.services.fleet.whisparr.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.whisparr = {
        image = "ghcr.io/hotio/whisparr@sha256:c60aabe2ab85417e8f23dfc56285a33be413c5336ebe47b8f26eca9e7145540c";
        environmentFiles = [ "/run/secrets/whisparr.env" ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
        };
        volumes = [
          "/var/lib/media-automation/whisparr:/config"
          "/mnt/bulk/videos:/videos"
        ];
        ports = [ "127.0.0.1:6969:6969" ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/whisparr 0700 1000 1000 -" ];
    systemd.services.podman-whisparr.unitConfig.ConditionPathIsReadable = "/run/secrets/whisparr.env";
    fleet = {
      storage.nfsMounts.videos = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
        dependentUnits = [ "podman-whisparr" ];
      };
      ingress.routes = [
        {
          hostname = "whisparr.tailbc181.ts.net";
          upstream = "http://127.0.0.1:6969";
          exposure = "tailnet";
        }
      ];
      backup.jobs.whisparr-state =
        (backups.state {
          name = "whisparr";
          path = "/var/lib/media-automation/whisparr";
          sqliteDatabases = [
            "whisparr2.db"
            "logs.db"
          ];
          exclude = [
            "/Backups/"
            "/logs/"
          ];
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:6969/";
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
