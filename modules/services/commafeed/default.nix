{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.commafeed;
  group = config.services.fleet.lightweightApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.commafeed.enable = lib.mkEnableOption "CommaFeed";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.commafeed = {
        image = "docker.io/athou/commafeed@sha256:59b59cf87cc2ab4501dfbd05079db77b0e0a3454bd17974fb733431d866223ee";
        environmentFiles = [ group.environmentFiles.commafeed ];
        environment.TZ = "America/Los_Angeles";
        volumes = [ "/var/lib/commafeed:/commafeed/data" ];
        ports = [ "127.0.0.1:8085:8082" ];
        extraOptions = [ "--network=fleet-lightweight" ];
      };
    };
    systemd.services.podman-commafeed = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [ group.environmentFiles.commafeed ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/commafeed 0750 root root -" ];
    fleet.ingress.routes = [
      {
        hostname = "feed.tailbc181.ts.net";
        upstream = "http://127.0.0.1:8085";
        exposure = "tailnet";
      }
    ];
    fleet.backup.jobs.commafeed-state =
      (backups.state {
        name = "commafeed";
        path = "/var/lib/commafeed";
        owner = "root";
        group = "root";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8085/";
      })
      // {
        backupClass = "database";
      };
  };
}
