{
  config,
  lib,
  pkgs,
  ...
}:
let
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  # Keep the stale fallback disabled until the completed policy is mirrored.
  fleet.comin.enableMirror = false;
  sops.secrets =
    lib.genAttrs
      [
        "tailscale-immich-state"
        "tailscale-mealie-state"
        "forgejo-runner-hl-node-02"
      ]
      (_: {
        sopsFile = ../../secrets/hosts/hl-node-02/service-identities.yaml;
        mode = "0600";
        restartUnits = [ ];
      });
  fleet.tailscaleServiceProxy.proxies = {
    immich = {
      upstream = "http://127.0.0.1:2283";
      hostname = "immich.tailbc181.ts.net";
      seedStateFile = config.sops.secrets.tailscale-immich-state.path;
      port = 41642;
    };
    mealie = {
      upstream = "http://127.0.0.1:9000";
      hostname = "mealie.tailbc181.ts.net";
      seedStateFile = config.sops.secrets.tailscale-mealie-state.path;
      port = 41643;
    };
  };
  fleet.backup.jobs = lib.mapAttrs' (
    name: proxy:
    lib.nameValuePair "tailscale-${name}-state" (
      backups.state {
        name = "tailscale-${name}";
        path = "/var/lib/tailscale-${name}";
        serviceUnit = "tailscale-${name}.service";
        healthCheckCommand = ''
          ${lib.getExe pkgs.tailscale} --socket=/run/tailscale-${name}/tailscaled.sock status --json --peers=false |
            ${lib.getExe pkgs.jq} -e --arg hostname ${lib.escapeShellArg proxy.hostname} \
              '.BackendState == "Running" and (.Self.DNSName | rtrimstr(".")) == $hostname' >/dev/null
        '';
      }
    )
  ) config.fleet.tailscaleServiceProxy.proxies;

  # Shared Cloudflare connectors remain on the surviving source worker until
  # their own migration. Matrix traffic goes directly to the native origin.
  networking.firewall.extraInputRules = ''
    iifname "bond0" ip saddr { 10.15.4.9, 10.244.3.0/24 } tcp dport 8080 accept comment "shared Cloudflare connector"
  '';
}
