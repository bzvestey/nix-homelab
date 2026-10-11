{
  pkgs,
  bootstrapConfigurations,
  nixosConfigurations,
  preparedConfigurations,
}:
let
  inherit (pkgs) lib;
  quarantined =
    configuration:
    let
      c = configuration.config;
      units =
        map (name: "podman-${name}") (builtins.attrNames c.virtualisation.oci-containers.containers)
        ++ map (name: "tailscale-${name}") (builtins.attrNames c.fleet.tailscaleServiceProxy.proxies)
        ++ map (name: "postgres-${name}") (builtins.attrNames (c.fleet.localPostgres or { }));
    in
    !c.systemd.services.comin.enable
    && !c.systemd.services.caddy.enable
    && !c.systemd.services.cloudflared-fleet.enable
    && lib.all (name: !c.systemd.services.${name}.enable) units
    && lib.all (timer: !timer.enable) (
      builtins.attrValues (lib.filterAttrs (name: _: lib.hasPrefix "fleet-backup-" name) c.systemd.timers)
    )
    && c.fleet.storage.nfsMounts == { };
  c01 = nixosConfigurations.hl-node-01.config;
  c04 = nixosConfigurations.hl-node-04.config;
  c02 = preparedConfigurations.hl-node-02-remaining.config;
  c03 = preparedConfigurations.hl-node-03-staging.config;
in
assert lib.all quarantined (builtins.attrValues bootstrapConfigurations);
assert builtins.hasAttr "pocket-id" c03.virtualisation.oci-containers.containers;
assert builtins.hasAttr "mailrise" c03.virtualisation.oci-containers.containers;
assert !(builtins.hasAttr "homarr" c03.virtualisation.oci-containers.containers);
assert !(builtins.hasAttr "homarr-state" c03.fleet.backup.jobs);
assert !(builtins.hasAttr "tailscale-homarr-state-json" c03.fleet.preparedApplications.secretPaths);
assert c03.sops.secrets.mailrise-conf.uid == 999;
assert c03.sops.secrets.mailrise-conf.mode == "0400";
assert c01.fleet.tailscaleServiceProxy.proxies.mailrise.tcpForwards."25" == "127.0.0.1:8025";
assert
  c04.fleet.tailscaleServiceProxy.proxies.deluge-direct.tcpForwards."58846" == "127.0.0.1:58846";
assert c02.fleet.tailscaleServiceProxy.proxies.git-ssh.tcpForwards."22" == "127.0.0.1:2222";
assert c02.fleet.tailscaleServiceProxy.proxies.knot-ssh.tcpForwards."22" == "127.0.0.1:2223";
assert
  c02.fleet.tailscaleServiceProxy.proxies.immich
  == nixosConfigurations.hl-node-02.config.fleet.tailscaleServiceProxy.proxies.immich;
assert
  c02.virtualisation.oci-containers.containers.mealie
  == nixosConfigurations.hl-node-02.config.virtualisation.oci-containers.containers.mealie;
assert
  c01.fleet.preparedApplications.secretPaths.donetick-selfhosted-yaml
  == "/run/secrets/donetick-selfhosted.yaml";
assert
  c04.fleet.preparedApplications.secretPaths.publication-manager-master-key
  == "/run/secrets/publication-manager/master-key";
pkgs.runCommand "remaining-batch-contract" { } "touch $out"
