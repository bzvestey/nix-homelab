{
  config,
  lib,
  utils,
  ...
}:
let
  backupUnits = map (job: "fleet-backup-${job}") (
    builtins.attrNames config.fleet.backup.jobs ++ [ "check" ]
  );
in
{
  # Installer/bootstrap policy remains safe before an approved restore.
  fleet.storage.nfsMounts = lib.mkForce { };
  fleet.comin.enableMirror = false;
  systemd.services =
    lib.genAttrs
      (
        [
          "podman-immich"
          "podman-immich-ml"
          "podman-mealie"
          "podman-tuwunel"
          "postgres-immich"
          "postgresql"
          "postgresql-setup"
          "dragonflydb"
          "forgejo-runner-${utils.escapeSystemdPath config.services.fleet.forgejo-runner.name}"
          "caddy"
        ]
        ++ backupUnits
      )
      (_: {
        enable = lib.mkForce false;
      });
  systemd.timers = lib.genAttrs backupUnits (_: {
    enable = lib.mkForce false;
  });
}
