{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.kavita;
  group = config.services.fleet.storageApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../storage-shared.nix ];
  options.services.fleet.kavita.enable = lib.mkEnableOption "Kavita";
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /var/lib/kavita 0750 storage-apps storage-apps -" ];
    systemd.services.podman-kavita = {
      unitConfig.ConditionPathExists = group.kavitaEnvironmentFile;
      serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test -s /var/lib/kavita/.fleet-restored";
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.kavita = {
        image = "docker.io/linuxserver/kavita@sha256:2842f1c0882b9d0ce3103420eea0a90b27e4537ff29f87b1471cdd752e936837";
        ports = [ "127.0.0.1:5000:5000" ];
        environmentFiles = [ group.kavitaEnvironmentFile ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          # Match Jellyfin's LSIO device-permission initialization for abc/PUID.
          ATTACHED_DEVICES_PERMS = "/dev/dri -type c";
        };
        volumes = [
          "/var/lib/kavita:/config"
          "/mnt/bulk/books:/data/books:ro"
          "/mnt/bulk/syncthing:/data/syncthing:ro"
        ];
        extraOptions = [ "--device=/dev/dri:/dev/dri" ];
      };
    };
    fleet = {
      storage.nfsMounts = {
        books = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/Computer/books";
          target = "/mnt/bulk/books";
          dependentUnits = [ "podman-kavita" ];
        };
        syncthing = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/apps/syncthing";
          target = "/mnt/bulk/syncthing";
          dependentUnits = [ "podman-kavita" ];
        };
      };
      backup.jobs.kavita-state =
        (backups.state {
          name = "kavita";
          path = "/var/lib/kavita";
          owner = "storage-apps";
          group = "storage-apps";
          # Avoid copying Kavita's own archives while the service is stopped.
          exclude = [ "/backups/" ];
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:5000/";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          maxPayloadBytes = 137438953472;
        };
      ingress.routes = [
        {
          hostname = "kavita.tailbc181.ts.net";
          upstream = "http://127.0.0.1:5000";
          exposure = "tailnet";
        }
      ];
    };
  };
}
