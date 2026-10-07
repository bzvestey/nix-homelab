{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.services.fleet.forgejo-runner;
  unit = "forgejo-runner-${utils.escapeSystemdPath cfg.name}";
in
{
  options.services.fleet.forgejo-runner = {
    enable = lib.mkEnableOption "the fleet's local Forgejo Actions runner";
    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Local instance name; provision the same name on the Forgejo server.";
    };
    uuid = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
      description = "Public, persistent runner identity, provisioned by the administrator.";
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest" ];
      description = "Container job labels; production hosts use the identical default.";
    };
    instanceUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://git.tailbc181.ts.net/";
      description = "Forgejo server URL.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/forgejo-runner-${cfg.name}";
      description = "Runtime file containing only the runner token, supplied later via framework-runners SOPS policy.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/run/" cfg.tokenFile;
        message = "Fleet runner credentials must be runtime files, never Nix store paths.";
      }
      {
        assertion = lib.all (label: lib.hasInfix ":docker://" label) cfg.labels;
        message = "Fleet runners only accept container jobs, not host execution.";
      }
    ];
    services.forgejo-runner.instances.${cfg.name} = {
      enable = true;
      settings = {
        server.connections.default = {
          url = cfg.instanceUrl;
          inherit (cfg) uuid;
          token = null;
        };
        runner = {
          inherit (cfg) labels;
          capacity = 1;
        };
        container = {
          docker_host = "-";
          privileged = false;
          valid_volumes = [ ];
          force_pull = false;
        };
        cache = {
          enabled = false;
          dir = "/var/lib/forgejo-runner/${cfg.name}/cache";
        };
      };
      secrets.server.connections.default.token_url = cfg.tokenFile;
    };
    systemd.services.${unit} = {
      # A missing credential is an unenrolled runner, not a failed bootstrap.
      unitConfig.ConditionPathExists = cfg.tokenFile;
      environment.DOCKER_HOST = "unix:///run/podman/podman.sock";
      serviceConfig = {
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
