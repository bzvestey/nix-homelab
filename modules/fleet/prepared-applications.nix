{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.preparedApplications;
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
  tailnetRoutes = lib.filter (
    route: route.exposure == "tailnet" && !(builtins.elem route.hostname cfg.existingIdentityHostnames)
  ) config.fleet.ingress.routes;
  containers = builtins.attrValues config.virtualisation.oci-containers.containers;
  volumePaths = lib.concatMap (
    container: map (volume: builtins.head (lib.splitString ":" volume)) container.volumes
  ) containers;
  paths = lib.unique (
    lib.filter
      (path: lib.hasPrefix "/run/secrets/" path && !(builtins.elem path cfg.existingSecretPaths))
      (
        lib.concatMap (container: container.environmentFiles) containers
        ++ volumePaths
        ++ cfg.extraSecretPaths
        ++ lib.optional (
          config.services.fleet ? forgejo-runner && config.services.fleet.forgejo-runner.enable
        ) config.services.fleet.forgejo-runner.tokenFile
        ++ [
          "/run/secrets/tailscale-auth-key"
          "/run/secrets/restic-repository"
          "/run/secrets/restic-password"
          "/run/secrets/restic-s3-credentials"
        ]
        ++ map (proxy: proxy.seedStateFile) (builtins.attrValues config.fleet.tailscaleServiceProxy.proxies)
      )
  );
  secretName =
    path: lib.replaceStrings [ "/" "." ] [ "-" "-" ] (lib.removePrefix "/run/secrets/" path);
in
{
  options.fleet.preparedApplications = {
    enable = lib.mkEnableOption "prepared runtime secret and migrated HTTP identity contracts";
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Encrypted SOPS YAML enrolled for this host; null keeps enrollment deferred.";
    };
    extraSecretPaths = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "^/run/secrets/.+");
      default = [ ];
    };
    existingIdentityHostnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Already enrolled HTTP identities owned by another module.";
    };
    existingSecretPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Runtime paths already enrolled by another module.";
    };
    manageIdentityBackups = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create online identity backups unless another module owns these jobs.";
    };
    secretPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "SOPS key to runtime path mapping for enrollment, without any secret values.";
    };
  };
  config = lib.mkIf cfg.enable {
    sops.secrets = lib.mkIf (cfg.secretsFile != null) (
      lib.mapAttrs (_: path: {
        sopsFile = cfg.secretsFile;
        inherit path;
        mode = "0400";
        uid =
          if lib.hasPrefix "/run/secrets/publication-manager/" path then
            1000
          else if path == "/run/secrets/mailrise.conf" then
            999
          else
            0;
        restartUnits = [ ];
      }) cfg.secretPaths
    );
    fleet = {
      preparedApplications.secretPaths = lib.listToAttrs (
        map (path: lib.nameValuePair (secretName path) path) paths
      );
      tailscaleServiceProxy.proxies = lib.listToAttrs (
        lib.imap0 (
          index: route:
          lib.nameValuePair (builtins.head (lib.splitString "." route.hostname)) {
            inherit (route) hostname upstream;
            seedStateFile = "/run/secrets/tailscale-${builtins.head (lib.splitString "." route.hostname)}-state.json";
            port = 42000 + index;
          }
        ) tailnetRoutes
      );
      backup = {
        s3CredentialsFile = "/run/secrets/restic-s3-credentials";
        jobs = lib.mkIf cfg.manageIdentityBackups (
          lib.mapAttrs' (
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
          ) config.fleet.tailscaleServiceProxy.proxies
        );
      };
    };
  };
}
