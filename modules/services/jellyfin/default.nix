{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.jellyfin;
  group = config.services.fleet.storageApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../storage-shared.nix ];
  options.services.fleet.jellyfin.enable = lib.mkEnableOption "Jellyfin";
  config = lib.mkIf cfg.enable {
    hardware.graphics.enable = true;
    systemd.tmpfiles.rules = [ "d /var/lib/jellyfin 0750 storage-apps storage-apps -" ];
    systemd.services.podman-jellyfin = {
      unitConfig.ConditionPathExists = group.jellyfinEnvironmentFile;
      serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test -s /var/lib/jellyfin/.fleet-restored";
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.jellyfin = {
        image = "ghcr.io/linuxserver/jellyfin@sha256:1bb4f88d822a0510bb3604b68aacb80d77c1d2a30181e500090c65111b98723b";
        ports = [ "127.0.0.1:8096:8096" ];
        environmentFiles = [ group.jellyfinEnvironmentFile ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          JELLYFIN_PublishedServerUrl = "https://jellyfin.tailbc181.ts.net/";
        };
        volumes = [
          "/var/lib/jellyfin:/config"
          "/mnt/bulk/videos:/data:ro"
        ];
        extraOptions = [ "--device=/dev/dri:/dev/dri" ];
      };
    };
    fleet = {
      storage.nfsMounts.videos = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
        dependentUnits = [ "podman-jellyfin" ];
      };
      backup.jobs.jellyfin-state =
        (backups.state {
          name = "jellyfin";
          path = "/var/lib/jellyfin";
          owner = "storage-apps";
          group = "storage-apps";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8096/health";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          maxPayloadBytes = 34359738368;
        };
      ingress.routes = [
        {
          hostname = "jellyfin.tailbc181.ts.net";
          upstream = "http://127.0.0.1:8096";
          exposure = "tailnet";
        }
      ];
    };
  };
}
