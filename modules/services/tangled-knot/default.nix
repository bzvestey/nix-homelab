{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.tangled-knot;
  auth = config.services.fleet.remainingApplications.registryAuthFile;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../remaining-options.nix ];
  options.services.fleet.tangled-knot.enable = lib.mkEnableOption "Tangled Knot";
  config = lib.mkIf cfg.enable {
    fleet.backup.jobs.tangled-knot-state =
      (backups.state {
        name = "tangled-knot";
        path = "/var/lib/tangled-knot";
        owner = "1000";
        group = "1000";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 http://127.0.0.1:5555/xrpc/_health";
      })
      // {
        backupClass = "database";
      };
    fleet.ingress.routes = [
      {
        hostname = "knot.minastas.xyz";
        upstream = "http://127.0.0.1:5555";
        exposure = "public";
      }
    ];
    virtualisation.oci-containers = {
      backend = "podman";
      containers.tangled-knot = {
        image = "atcr.io/tangled.org/knot@sha256:6a9246da7b49a8bbe6f84122fd6fc09aac3ae93589b193956873daf33f88faa6";
        cmd = [ "/etc/knot/config.toml" ];
        environmentFiles = [ "/run/secrets/tangled-knot.env" ];
        environment = {
          KNOT_SCAN_PATH = "/data/repos";
          KNOT_SEALED_KEY_FILE = "/data/sealed-keys";
          KNOT_SSH_HOST_KEY_FILE = "/data/ssh_host_key";
          KNOT_MASTER_KEY_ENV = "KNOT_MASTER_KEY";
        };
        volumes = [
          "/var/lib/tangled-knot/data:/data"
          "/var/lib/tangled-knot/config.toml:/etc/knot/config.toml:ro"
        ];
        ports = [
          "127.0.0.1:5555:5555"
          "127.0.0.1:2223:2222"
        ];
        user = "1000:1000";
      };
    };
    systemd.services.podman-tangled-knot = {
      unitConfig.ConditionPathExists = [
        "/run/secrets/tangled-knot.env"
        "/var/lib/tangled-knot/.restored"
        auth
      ];
      serviceConfig.Environment = [ "REGISTRY_AUTH_FILE=${auth}" ];
      preStart = ''
        ${pkgs.findutils}/bin/find /var/lib/tangled-knot -type f \( -name 'ssh_host_*' -o -name 'ssh_host_key' \) ! -name '*.pub' -exec ${pkgs.coreutils}/bin/chmod 0600 {} +
      '';
    };
    systemd.tmpfiles.rules = [ "d /var/lib/tangled-knot 0700 root root -" ];
  };
}
