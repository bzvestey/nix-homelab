{
  config,
  lib,
  utils,
  ...
}:
let
  backupUnits = map (name: "fleet-backup-${name}") (
    builtins.attrNames config.fleet.backup.jobs ++ [ "check" ]
  );
  workloadUnits =
    map (name: "podman-${name}") (builtins.attrNames config.virtualisation.oci-containers.containers)
    ++ map (name: "postgres-${name}") (builtins.attrNames (config.fleet.localPostgres or { }))
    ++ map (name: "tailscale-${name}") (builtins.attrNames config.fleet.tailscaleServiceProxy.proxies)
    ++ lib.optional (
      config.services.fleet ? forgejo-runner
    ) "forgejo-runner-${utils.escapeSystemdPath config.services.fleet.forgejo-runner.name}"
    ++ [
      "postgresql"
      "postgresql-setup"
      "caddy"
      "dragonflydb"
      "cloudflared-fleet"
      "comin"
    ];
in
{
  fleet.storage.nfsMounts = lib.mkForce { };
  fleet.comin.enableMirror = lib.mkForce false;
  systemd.services = lib.genAttrs (workloadUnits ++ backupUnits) (_: {
    enable = lib.mkForce false;
  });
  systemd.timers = lib.genAttrs backupUnits (_: {
    enable = lib.mkForce false;
  });
}
