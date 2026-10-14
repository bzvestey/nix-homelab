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
  imports = [ ../../modules/services/remaining-applications.nix ];
  services.fleet.remainingApplications.enable = true;
  # Keep the stale fallback disabled until the completed policy is mirrored.
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
  fleet = {
    comin.enableMirror = false;
    preparedApplications = {
      enable = true;
      secretsFile = ../../secrets/hosts/hl-node-02/remaining-applications.yaml;
      extraSecretPaths = [ "/run/secrets/remaining-applications-registry.json" ];
      existingIdentityHostnames = [
        "immich.tailbc181.ts.net"
        "mealie.tailbc181.ts.net"
      ];
      manageIdentityBackups = false;
      existingSecretPaths = [
        "/run/secrets/immich.env"
        "/run/secrets/mealie.env"
        "/run/secrets/tuwunel.toml"
        "/run/secrets/tailscale-auth-key"
        "/run/secrets/restic-repository"
        "/run/secrets/restic-password"
        "/run/secrets/restic-s3-credentials"
        "/run/secrets/tailscale-immich-state"
        "/run/secrets/tailscale-mealie-state"
        "/run/secrets/forgejo-runner-hl-node-02"
      ];
    };
    tailscaleServiceProxy.proxies = {
      immich = {
        upstream = "http://127.0.0.1:2283";
        hostname = "immich.tailbc181.ts.net";
        seedStateFile = "/run/secrets/tailscale-immich-state";
        port = 41642;
      };
      mealie = {
        upstream = "http://127.0.0.1:9000";
        hostname = "mealie.tailbc181.ts.net";
        seedStateFile = "/run/secrets/tailscale-mealie-state";
        port = 41643;
      };
      git-ssh = {
        hostname = "git-ssh.tailbc181.ts.net";
        tcpForwards."22" = "127.0.0.1:2222";
        seedStateFile = "/run/secrets/tailscale-git-ssh-state.json";
        port = 42101;
      };
      knot-ssh = {
        hostname = "knot-ssh.tailbc181.ts.net";
        tcpForwards."22" = "127.0.0.1:2223";
        seedStateFile = "/run/secrets/tailscale-knot-ssh-state.json";
        port = 42102;
      };
    };
    backup.jobs = lib.mapAttrs' (
      name: proxy:
      lib.nameValuePair "tailscale-${name}-state" (
        backups.tailscaleIdentity {
          inherit name;
          healthCheckCommand = ''
            ${lib.getExe pkgs.tailscale} --socket=/run/tailscale-${name}/tailscaled.sock status --json --peers=false |
              ${lib.getExe pkgs.jq} -e --arg hostname ${lib.escapeShellArg proxy.hostname} \
                '.BackendState == "Running" and (.Self.DNSName | rtrimstr(".")) == $hostname' >/dev/null
          '';
        }
      )
    ) config.fleet.tailscaleServiceProxy.proxies;
  };

  # Shared Cloudflare connectors remain on the surviving source worker until
  # their own migration. Matrix traffic goes directly to the native origin.
  networking.firewall.extraInputRules = ''
    iifname "bond0" ip saddr { 10.15.4.9, 10.244.3.0/24 } tcp dport 8080 accept comment "shared Cloudflare connector"
  '';
}
