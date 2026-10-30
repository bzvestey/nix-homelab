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
  options.services.fleet.sabnzbd.enable = lib.mkEnableOption "SABnzbd";
  config = lib.mkIf config.services.fleet.sabnzbd.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.sabnzbd = {
        image = "ghcr.io/linuxserver/sabnzbd@sha256:a7cfba459929f73b83c98b476a845076dc72524af80b24fcb4200684e6b1b675";
        environmentFiles = [ "/run/secrets/sabnzbd.env" ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
        };
        volumes = [
          "/var/lib/media-automation/sabnzbd:/config"
          "/mnt/bulk/videos:/videos"
        ];
        ports = [ "127.0.0.1:8180:8080" ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/sabnzbd 0700 1000 1000 -" ];
    systemd.services.podman-sabnzbd.unitConfig.ConditionPathIsReadable = "/run/secrets/sabnzbd.env";
    fleet = {
      storage.nfsMounts.videos = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
        target = "/mnt/bulk/videos";
        dependentUnits = [ "podman-sabnzbd" ];
      };
      ingress.routes = [
        {
          hostname = "sabnzbd.tailbc181.ts.net";
          upstream = "http://127.0.0.1:8180";
          exposure = "tailnet";
        }
      ];
      backup.jobs.sabnzbd-state =
        (backups.state {
          name = "sabnzbd";
          path = "/var/lib/media-automation/sabnzbd";
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8180/";
        })
        // {
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
        };
    };
  };
}
