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
  options.services.fleet.sonarr.enable = lib.mkEnableOption "Sonarr";
  config = lib.mkIf config.services.fleet.sonarr.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.sonarr = {
        image = "ghcr.io/linuxserver/sonarr@sha256:f247545d23ba8b233d6604575347e48a623fe6ad75dda02348bf81917f3b5c06";
        environmentFiles = [ "/run/secrets/sonarr.env" ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          # Tailscale Serve reaches this container through the host's Podman gateway.
          SONARR__SERVER__TRUSTEDNETWORKS = "10.88.0.1/32";
        };
        volumes = [
          "/var/lib/media-automation/sonarr:/config"
          "/mnt/bulk/videos:/videos"
        ];
        ports = [ "127.0.0.1:8989:8989" ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/sonarr 0700 1000 1000 -" ];
    systemd.services.podman-sonarr.unitConfig.ConditionPathIsReadable = "/run/secrets/sonarr.env";
    fleet = {
      storage.nfsMounts.videos = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
        dependentUnits = [ "podman-sonarr" ];
      };
      ingress.routes = [
        {
          hostname = "sonarr.tailbc181.ts.net";
          upstream = "http://127.0.0.1:8989";
          exposure = "tailnet";
        }
      ];
      backup.jobs.sonarr-state =
        (backups.state {
          name = "sonarr";
          path = "/var/lib/media-automation/sonarr";
          sqliteDatabases = [
            "sonarr.db"
            "logs.db"
          ];
          exclude = [
            "/Backups/"
            "/logs/"
          ];
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8989/";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
          # Existing state is about 1.58 GiB; retain headroom for growth.
          maxPayloadBytes = 4294967296;
        };
    };
  };
}
