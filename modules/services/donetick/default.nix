{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.donetick;
  group = config.services.fleet.lightweightApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.donetick.enable = lib.mkEnableOption "Donetick";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.donetick = {
        image = "docker.io/donetick/donetick@sha256:fe6b04d496f315181c196bdf1fbea93d3525e105642c2d0b7a3e5dd7b53d3674";
        environmentFiles = [ group.environmentFiles.donetick ];
        environment = {
          TZ = "America/Los_Angeles";
          DT_ENV = "selfhosted";
          DT_SQLITE_PATH = "/donetick_data/donetick.db";
        };
        volumes = [
          "/var/lib/donetick:/donetick_data"
          "${group.donetickConfigFile}:/config/selfhosted.yaml:ro"
        ];
        ports = [ "127.0.0.1:2021:2021" ];
        extraOptions = [ "--network=fleet-lightweight" ];
      };
    };
    systemd.services.podman-donetick = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [
        group.environmentFiles.donetick
        group.donetickConfigFile
      ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/donetick 0750 root root -" ];
    fleet.ingress.routes = [
      {
        hostname = "donetick.tailbc181.ts.net";
        upstream = "http://127.0.0.1:2021";
        exposure = "tailnet";
      }
    ];
    fleet.backup.jobs.donetick-state =
      (backups.state {
        name = "donetick";
        path = "/var/lib/donetick";
        sqliteDatabases = [ "donetick.db" ];
        owner = "root";
        group = "root";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:2021/";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
      };
  };
}
