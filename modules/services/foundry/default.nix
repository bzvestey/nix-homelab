{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.foundry;
  auth = config.services.fleet.remainingApplications.registryAuthFile;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  imports = [ ../remaining-options.nix ];
  options.services.fleet.foundry.enable = lib.mkEnableOption "restored Foundry";
  config = lib.mkIf cfg.enable {
    fleet.backup.jobs.foundry-state =
      (backups.state {
        name = "foundry";
        path = "/var/lib/foundry";
        owner = "1000";
        group = "1000";
        healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 http://127.0.0.1:30000/";
      })
      // {
        frequency = "hourly";
        backupClass = "database";
        # Modules contain spaces and relative symlinks; retain a bounded tar payload.
        maxPayloadBytes = 16 * 1024 * 1024 * 1024;
        requiredPaths = [ "state.tar" ];
        createCommand = ''
          active=0
          if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-foundry.service; then active=1; fi
          ${pkgs.systemd}/bin/systemctl stop podman-foundry.service
          trap 'if [ "$active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-foundry.service; fi' EXIT
          ${pkgs.gnutar}/bin/tar -C /var/lib/foundry -cpf "$FLEET_BACKUP_STAGING_DIR/state.tar" .
        '';
        restoreCommand = ''
          ${pkgs.coreutils}/bin/mkdir -p /var/lib/foundry
          ${pkgs.findutils}/bin/find /var/lib/foundry -mindepth 1 -maxdepth 1 -exec ${pkgs.coreutils}/bin/rm -rf -- {} +
          ${pkgs.gnutar}/bin/tar -C /var/lib/foundry -xpf "$FLEET_RESTORE_SOURCE_DIR/state.tar"
        '';
        rehearsalCommand = ''
          ${pkgs.gnutar}/bin/tar -tf "$FLEET_RESTORE_SOURCE_DIR/state.tar" >/dev/null
        '';
      };
    fleet.ingress.routes = [
      {
        hostname = "foundry.minastas.xyz";
        upstream = "http://127.0.0.1:30000";
        exposure = "public";
      }
    ];
    virtualisation.oci-containers = {
      backend = "podman";
      containers.foundry = {
        # Foundry 14.369 requires Node >=24.13.1 and <25; restore licensed app separately.
        image = "docker.io/library/node@sha256:51b1100cc2a83d370c6a60952e3f2989c8a43159d0e38586e090f3b3326efefd";
        user = "1000:1000";
        cmd = [
          "node"
          "/home/foundry/app/resources/app/main.js"
          "--headless"
          "--dataPath=/home/foundry/data"
        ];
        extraOptions = [ "--workdir=/home/foundry" ];
        environmentFiles = [ "/run/secrets/foundry.env" ];
        ports = [ "127.0.0.1:30000:30000" ];
        volumes = [
          "/var/lib/foundry/app:/home/foundry/app"
          "/var/lib/foundry/data:/home/foundry/data"
        ];
      };
    };
    systemd.services.podman-foundry = {
      unitConfig.ConditionPathExists = [
        "/run/secrets/foundry.env"
        "/var/lib/foundry/.restored"
        auth
      ];
      serviceConfig.Environment = [ "REGISTRY_AUTH_FILE=${auth}" ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/foundry 0700 root root -" ];
  };
}
