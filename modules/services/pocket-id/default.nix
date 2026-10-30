{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.pocket-id;
  group = config.services.fleet.lightweightApplications;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.pocket-id.enable = lib.mkEnableOption "Pocket ID";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.pocket-id = {
        image = "ghcr.io/pocket-id/pocket-id@sha256:f085157f0b6ea4b2e8aa5ecfd99eada0d83a4960f3a3dcfd46014097d0ef7ab5";
        environmentFiles = [ group.environmentFiles.pocket-id ];
        environment = {
          TZ = "America/Los_Angeles";
          APP_URL = "https://id.minastas.xyz";
          TRUST_PROXY = "true";
        };
        volumes = [ "/var/lib/pocket-id:/app/data" ];
        ports = [ "127.0.0.1:1411:1411" ];
        extraOptions = [ "--network=fleet-lightweight" ];
      };
    };
    systemd.services.podman-pocket-id = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [ group.environmentFiles.pocket-id ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/pocket-id 0750 1000 1000 -" ];
    fleet.ingress.routes = [
      {
        hostname = "id.minastas.xyz";
        upstream = "http://127.0.0.1:1411";
        exposure = "public";
      }
    ];
    fleet.backup.jobs.pocket-id-state =
      (backups.state {
        name = "pocket-id";
        path = "/var/lib/pocket-id";
        sqliteDatabases = [ "pocket-id.db" ];
        exclude = [
          "/backup/"
          "/data-exports/"
        ];
        owner = "1000";
        group = "1000";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:1411/healthz";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
      };
  };
}
