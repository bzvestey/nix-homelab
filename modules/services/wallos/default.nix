{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.wallos;
  group = config.services.fleet.lightweightApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.wallos.enable = lib.mkEnableOption "Wallos";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.wallos = {
        image = "docker.io/bellamy/wallos@sha256:0f049dbab45b9f8e8d43b84fd1b77ef9e55909bd1a384a0f4fe8597ab68a1d5d";
        environmentFiles = [ group.environmentFiles.wallos ];
        environment = {
          TZ = "America/Los_Angeles";
          WALLOS_SERVER_URL = "https://wallos.tailbc181.ts.net";
        };
        volumes = [
          "/var/lib/wallos/db:/var/www/html/db"
          "/var/lib/wallos/logos:/var/www/html/images/uploads/logos"
        ];
        ports = [ "127.0.0.1:8282:80" ];
        extraOptions = [ "--network=fleet-lightweight" ];
      };
    };
    systemd.services.podman-wallos = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [ group.environmentFiles.wallos ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/wallos 0750 82 82 -"
      "d /var/lib/wallos/db 0750 82 82 -"
      "d /var/lib/wallos/logos 0750 82 82 -"
    ];
    fleet.ingress.routes = [
      {
        hostname = "wallos.tailbc181.ts.net";
        upstream = "http://127.0.0.1:8282";
        exposure = "tailnet";
      }
    ];
    fleet.backup.jobs.wallos-state =
      (backups.state {
        name = "wallos";
        path = "/var/lib/wallos";
        owner = "82";
        group = "82";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8282/";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
      };
  };
}
