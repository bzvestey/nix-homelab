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
  # Keep workload/restore definitions, but credentials alone must not activate
  # them. Remove this import only as part of an approved activation change.
  fleet.storage.nfsMounts = lib.mkForce { };
  # An older mirror must not replace this policy with production-enabled main.
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
