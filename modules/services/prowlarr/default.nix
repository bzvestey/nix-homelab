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
  options.services.fleet.prowlarr.enable = lib.mkEnableOption "Prowlarr";
  config = lib.mkIf config.services.fleet.prowlarr.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.prowlarr = {
        image = "ghcr.io/linuxserver/prowlarr@sha256:f2b26429893d4c4cb71941b7ee50b1bdecd9d5f9f9e02d5410615e9f4f7c8d95";
        environmentFiles = [ "/run/secrets/prowlarr.env" ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
        };
        volumes = [ "/var/lib/media-automation/prowlarr:/config" ];
        ports = [ "127.0.0.1:9696:9696" ];
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/media-automation/prowlarr 0700 1000 1000 -" ];
    systemd.services.podman-prowlarr.unitConfig.ConditionPathIsReadable = "/run/secrets/prowlarr.env";
    fleet.ingress.routes = [
      {
        hostname = "prowlarr.tailbc181.ts.net";
        upstream = "http://127.0.0.1:9696";
        exposure = "tailnet";
      }
    ];
    fleet.backup.jobs.prowlarr-state =
      (backups.state {
        name = "prowlarr";
        path = "/var/lib/media-automation/prowlarr";
        sqliteDatabases = [
          "prowlarr.db"
          "logs.db"
        ];
        exclude = [
          "/Backups/"
          "/logs/"
        ];
        owner = "1000";
        group = "1000";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:9696/";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
        mode = "0600";
        directoryMode = "0700";
      };
  };
}
