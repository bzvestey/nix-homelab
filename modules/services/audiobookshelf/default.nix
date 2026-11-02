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
  options.services.fleet.audiobookshelf.enable = lib.mkEnableOption "Audiobookshelf";
  config = lib.mkIf config.services.fleet.audiobookshelf.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.audiobookshelf = {
        image = "ghcr.io/advplyr/audiobookshelf@sha256:37c2057e150694970442579815c646fe6bdc01c95b9d1547c4c9068be8844ef3";
        user = "1000:1000";
        environment = {
          # Non-root processes need an unprivileged container port.
          PORT = "13378";
          TZ = "America/Los_Angeles";
        };
        ports = [ "127.0.0.1:13378:13378" ];
        volumes = [
          "/var/lib/audiobookshelf/config:/config"
          "/var/lib/audiobookshelf/metadata:/metadata"
          "/mnt/bulk/book-library:/books:ro"
        ];
      };
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/audiobookshelf 0700 1000 1000 -"
      "d /var/lib/audiobookshelf/config 0700 1000 1000 -"
      "d /var/lib/audiobookshelf/metadata 0700 1000 1000 -"
    ];
    fleet = {
      tailscaleServices.services.audiobookshelf = {
        upstream = "http://127.0.0.1:13378";
        serviceUnit = "podman-audiobookshelf.service";
      };
      storage.nfsMounts.book-library = {
        source = "nas.tailbc181.ts.net:/mnt/spinners-1/books";
        target = "/mnt/bulk/book-library";
        dependentUnits = [ "podman-audiobookshelf" ];
      };
      backup.jobs.audiobookshelf-state =
        (backups.state {
          name = "audiobookshelf";
          path = "/var/lib/audiobookshelf";
          owner = "1000";
          group = "1000";
          online = false;
          sqliteDatabases = [ "config/absdatabase.sqlite" ];
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:13378/ping";
        })
        // {
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
          # Initial state is below 1 MiB; metadata and cover images will grow.
          maxPayloadBytes = 4294967296;
        };
    };
  };
}
