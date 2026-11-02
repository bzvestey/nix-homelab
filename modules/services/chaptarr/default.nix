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
  options.services.fleet.chaptarr.enable = lib.mkEnableOption "Chaptarr with local SQLite state";
  config = lib.mkIf config.services.fleet.chaptarr.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.chaptarr = {
        image = "docker.io/chaptarr/chaptarr@sha256:bb00d67cbe1485d1cd61ef178362a29b42aa08f86b290841aab4b115ad2647a6";
        environment = {
          PUID = "1000";
          PGID = "1000";
          UMASK = "002";
          TZ = "America/Los_Angeles";
        };
        ports = [ "127.0.0.1:8789:8789" ];
        volumes = [
          "/var/lib/media-automation/chaptarr:/config"
          "/mnt/bulk/book-library:/books"
          "/mnt/bulk/videos:/videos"
          "/mnt/bulk/deluge-downloads:/downloads"
        ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/chaptarr 0700 1000 1000 -" ];
    fleet = {
      tailscaleServices.services.chaptarr = {
        upstream = "http://127.0.0.1:8789";
        serviceUnit = "podman-chaptarr.service";
      };
      storage.nfsMounts = {
        book-library = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/books";
          target = "/mnt/bulk/book-library";
          dependentUnits = [ "podman-chaptarr" ];
        };
        videos = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
          target = "/mnt/bulk/videos";
          dependentUnits = [ "podman-chaptarr" ];
        };
        deluge-downloads = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/deluge/downloads";
          target = "/mnt/bulk/deluge-downloads";
          dependentUnits = [ "podman-chaptarr" ];
        };
      };
      backup.jobs.chaptarr-state =
        (backups.state {
          name = "chaptarr";
          path = "/var/lib/media-automation/chaptarr";
          owner = "1000";
          group = "1000";
          online = false;
          sqliteDatabases = [
            "chaptarr.db"
            "logs.db"
            "cache.db"
            "staging.db"
          ];
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8789/ping";
        })
        // {
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
        };
    };
  };
}
